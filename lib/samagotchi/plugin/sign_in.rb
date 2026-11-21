# frozen_string_literal: true

require "io/wait"
require "socket"
require "uri"
require_relative "../log"

module Samagotchi
  module Plugin
    # ctx.sign_in's flow (docs/plugins.md, Sign-in): send the session's owner
    # to an address, get back the address the browser was sent to. Core
    # knows nothing of OAuth beyond one check: when the address the bundle
    # built has a `state` query parameter, a callback whose `state` differs
    # is ignored and the wait goes on.
    #
    # The browser comes back to a Listener on 127.0.0.1 (#redirect_uri), or
    # the user pastes the address it ended on with /callback (#offer). The
    # first callback that passes settles it :done; #wait returns its query.
    # It also ends :timed_out (its deadline), :cancelled (#cancel) or
    # :stopped (the worker leaving, #stop): +on_settle+ hears each, once.
    class SignIn
      OUTCOMES = %i[done timed_out cancelled stopped].freeze
      TIMEOUTS = (60..900)
      DEFAULT_TIMEOUT = 300
      DEFAULT_PATH = "/callback"
      # How often a waiting thread or the listener looks at the deadline
      # with nothing else to wake it, in seconds.
      TICK = 1.0

      # The card that replaces a flow's when it ends without a callback.
      ENDED_TITLES = { timed_out: "Sign-in timed out", cancelled: "Sign-in cancelled", stopped: "Sign-in cancelled" }.freeze

      # The card's line for a browser on another device.
      PASTE_LINE = "If the browser ends on a page that doesn't load, copy that page's address and run " \
                   "`/callback <address>`."

      attr_reader :title, :button, :card_id, :redirect_uri, :address, :bundle

      # A flow that asks no one (a one-shot run, a stream hook's handler):
      # already :stopped, no card, no port.
      def self.stopped(bundle:, title:)
        new(bundle: bundle, title: title, button: nil, timeout: DEFAULT_TIMEOUT, listener: nil).tap do |flow|
          flow.instance_variable_set(:@outcome, :stopped)
        end
      end

      # @raise [ArgumentError] a timeout outside TIMEOUTS, a bad path
      def self.check_options!(timeout:, path:)
        unless timeout.is_a?(Numeric) && TIMEOUTS.cover?(timeout)
          raise ArgumentError, "ctx.sign_in's timeout: is #{TIMEOUTS.min}..#{TIMEOUTS.max} seconds"
        end
        return if path.is_a?(String) && path.match?(%r{\A/[A-Za-z0-9._~/-]*\z})

        raise ArgumentError, "ctx.sign_in's path: is an absolute path like /callback"
      end

      # The fields of the card that replaces +flow+'s when it ended as
      # +outcome+ without a callback; nil for :done (the bundle shows its
      # result) or a flow with no card.
      # @return [Hash, nil] Engine#show_card's keywords, the source left out
      def self.ended_card(flow, outcome)
        return nil if outcome == :done || flow.card_id.nil?

        { id: flow.card_id, title: ENDED_TITLES.fetch(outcome), body: "#{flow.title}: run its command again to try again.",
          actions: [] }
      end

      # @param listener [Listener, nil] bound already (the redirect_uri's port)
      # @param redirect_uri [String, nil] without a listener (the test kit's)
      # @param clock [#call] monotonic seconds
      # @param on_settle [#call] (flow, outcome), once, off the lock
      def initialize(bundle:, title:, button:, timeout:, listener:, redirect_uri: nil,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, on_settle: nil)
        @bundle = bundle
        @title = title
        @button = button
        @listener = listener
        @clock = clock
        @deadline = clock.call + timeout
        @on_settle = on_settle
        @redirect_uri = listener&.redirect_uri || redirect_uri
        @mutex = Mutex.new
        @settled = ConditionVariable.new
        @outcome = nil
        @result = nil
      end

      # The flow's address, never its query (an authorize URL can carry a
      # login hint).
      def inspect = "#<#{self.class.name} bundle=#{@bundle} redirect_uri=#{@redirect_uri} outcome=#{outcome.inspect}>"

      def pretty_print(printer) = printer.text(inspect)

      # Set once, before the card shows (Engine#start_sign_in).
      # @param address [String] the address the bundle built
      # @param card_id [String]
      def started(address, card_id)
        @address = address
        @state = state_of(address)
        @card_id = card_id
      end

      # The listener's thread starts: callbacks are taken from now.
      def listen
        @listener&.start(on_request: ->(query) { offer(query) }, on_tick: -> { expire_if_due })
      end

      # @return [Symbol, nil] OUTCOMES, nil while it waits
      def outcome = @mutex.synchronize { @outcome }

      def waiting? = outcome.nil?

      # Blocks until it settles (or +timeout+ seconds, when given, pass).
      # @return [Hash, nil] the callback's query ({"code"=>…, "state"=>…}),
      #   nil for any other outcome
      def wait(timeout = nil)
        until_at = timeout && (@clock.call + timeout)
        loop do
          expire_if_due
          @mutex.synchronize do
            return @result unless @outcome.nil?

            now = @clock.call
            return nil if until_at && now >= until_at

            left = [@deadline, until_at].compact.min - now
            @settled.wait(@mutex, left.clamp(0.001, TICK))
            return @result unless @outcome.nil?
          end
        end
      end

      def cancel = settle(:cancelled)

      # The worker leaves.
      def stop = settle(:stopped)

      # Ends it as +outcome+ (:timed_out, :cancelled, :stopped) now: the
      # bundle test kit's fail_sign_in.
      # @return [Boolean] whether this call ended it
      def end_as(outcome)
        raise ArgumentError, "a sign-in ends :done only through a callback" unless (OUTCOMES - [:done]).include?(outcome)

        settle(outcome)
      end

      # Whether +address+ (a pasted one) is this flow's: its redirect_uri,
      # with a query or none.
      def redirect_of?(address)
        return false unless @redirect_uri

        address == @redirect_uri || address.start_with?("#{@redirect_uri}?")
      end

      # A callback's query (the browser's, or a pasted address's).
      # @param query [String, nil] the part after "?"
      # @return [Boolean] whether it settled the flow :done
      def offer(query)
        params = parse(query)
        return false if params.nil?
        return false if @state && params["state"] != @state

        settle(:done, params)
      end

      # The deadline passed: :timed_out.
      def expire_if_due
        settle(:timed_out) if waiting? && @clock.call >= @deadline
      end

      private

      # @return [Boolean] whether this call settled it
      def settle(outcome, result = nil)
        settled = @mutex.synchronize do
          next false unless @outcome.nil?

          @outcome = outcome
          @result = result
          @settled.broadcast
          true
        end
        return false unless settled

        @listener&.close
        @on_settle&.call(self, outcome)
        true
      end

      def parse(query)
        URI.decode_www_form(query.to_s).each_with_object({}) { |(key, value), params| params[key] ||= value }
      rescue ArgumentError
        nil
      end

      def state_of(address)
        query = URI.parse(address).query
        query && parse(query)&.fetch("state", nil)
      rescue URI::InvalidURIError
        nil
      end

      # The loopback end of the round trip: a TCPServer on 127.0.0.1 only
      # (never 0.0.0.0 or ::), one connection at a time. It answers only
      # `GET <path>?…`: anything else, or a callback the flow refuses (a
      # wrong state), gets a short 404 and the wait goes on. A request's
      # line and headers are capped (MAX_REQUEST) and read with a deadline
      # (READ_TIMEOUT). The accepted callback gets a small static page (no
      # script, nothing of the request echoed); then it stops listening.
      class Listener
        HOST = "127.0.0.1"
        MAX_REQUEST = 8 * 1024
        READ_TIMEOUT = 5.0
        PAGE = <<~HTML
          <!doctype html><html><head><meta charset="utf-8"><title>Signed in</title></head>
          <body style="font-family:system-ui,sans-serif;margin:3em">Signed in. You can close this tab.</body></html>
        HTML
        NOT_FOUND = "That isn't this sign-in's address.\n"

        attr_reader :port

        # @param port [Integer, nil] nil: any free one
        # @raise [ArgumentError] the port is taken
        def initialize(port: nil, path: SignIn::DEFAULT_PATH, read_timeout: READ_TIMEOUT, tick: SignIn::TICK)
          @path = path
          @read_timeout = read_timeout
          @tick = tick
          @server = TCPServer.new(HOST, port || 0)
          @port = @server.addr[1]
          @closed = false
          @thread = nil
        rescue Errno::EADDRINUSE, Errno::EACCES
          raise ArgumentError, "ctx.sign_in's port #{port} is taken"
        end

        def redirect_uri = "http://#{HOST}:#{@port}#{@path}"

        # @param on_request [#call] (query) → whether it settled the flow
        # @param on_tick [#call] called each TICK with nothing to accept
        def start(on_request:, on_tick:)
          @thread = Thread.new do
            Thread.current.name = "chi-sign-in"
            serve(on_request, on_tick)
          end
        end

        def closed? = @closed

        def close
          @closed = true
          @server.close unless @server.closed?
        rescue IOError
          nil
        end

        private

        def serve(on_request, on_tick)
          until @closed
            ready = IO.select([@server], nil, nil, @tick)
            on_tick.call
            next unless ready && !@closed

            client = accept
            next unless client

            begin
              answer(client, on_request)
            ensure
              client.close unless client.closed?
            end
          end
        rescue IOError, SystemCallError
          nil # closed under it
        rescue StandardError => e
          Log.warn(:plugins, "sign_in_listener_failed", error: e.class.name)
        end

        def accept
          @server.accept_nonblock
        rescue IO::WaitReadable, Errno::EINTR, Errno::ECONNABORTED
          nil
        end

        def answer(client, on_request)
          head = read_head(client)
          return unless head

          method, target = head.lines.first.to_s.split(" ", 3)
          path, query = target.to_s.split("?", 2)
          if method == "GET" && path == @path && on_request.call(query)
            respond(client, "200 OK", "text/html; charset=utf-8", PAGE)
            close
          else
            respond(client, "404 Not Found", "text/plain; charset=utf-8", NOT_FOUND)
          end
        end

        # The request's line and headers, or nil when they don't come in time
        # or run past MAX_REQUEST (the connection is dropped).
        def read_head(client)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @read_timeout
          head = +""
          until head.include?("\r\n\r\n") || head.include?("\n\n")
            return nil if head.bytesize > MAX_REQUEST

            left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
            return nil unless left.positive? && client.wait_readable(left)

            chunk = client.read_nonblock(4096, exception: false)
            return nil if chunk.nil?
            next if chunk == :wait_readable

            head << chunk
          end
          head.bytesize > MAX_REQUEST ? nil : head
        end

        def respond(client, status, type, body)
          client.write("HTTP/1.1 #{status}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
                       "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n#{body}")
        rescue IOError, SystemCallError
          nil
        end
      end
    end
  end
end
