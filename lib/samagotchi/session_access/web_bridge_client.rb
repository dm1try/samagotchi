# frozen_string_literal: true

require "json"
require "uri"
require_relative "../session_access"
require_relative "../bridge_client"
require_relative "../delivery"
require_relative "../log"
require_relative "../worker_link"
require_relative "http_transport"

module Samagotchi
  module SessionAccess
    # A session's worker reached through another machine's chi web, with the
    # interface the attached TUI (TerminalUI::AttachedLoop) and its
    # EventStream use on a BridgeClient: chi web relays each request to the
    # worker's Bridge, on loopback there. One object per remote attach, for
    # its whole life: a new worker changes its #worker_key (the worker's
    # Bridge epoch), never the object. Built by Remote#attach_client.
    #
    # Every reply goes through one status mapper (Mapping), so the loop
    # reads each condition as it reads it from a Bridge here. Every
    # RemoteFailed (a refused connection, a timeout, a chi web too old, a
    # refused token) becomes Unreachable with its message: the loop catches
    # IOError wherever a Bridge call can fail, so it never crashes on one.
    class WebBridgeClient
      # The worker can't be reached through chi web: no live worker there,
      # the session is gone, or chi web itself can't be asked (the message
      # says which).
      class Unreachable < IOError; end

      # A one-shot's read timeout: above chi web's own 30 s read of the
      # Bridge plus its <= 5 s wait for a waking worker's Bridge.
      READ_TIMEOUT = 45
      # An answer or a dismissal: chi web sends it once more after a 408.
      ANSWER_READ_TIMEOUT = HTTPTransport::READ_TIMEOUT
      # No byte for this long on the stream (the Bridge pings every 15 s): a
      # half-open connection (Wi-Fi gone, the laptop asleep), reconnected.
      STREAM_IDLE_TIMEOUT = 40.0
      # A read a join waits on (a turn's saved records, the children
      # counts): a slow chi web can't hold the join up for long (L9).
      JOIN_READ_TIMEOUT = 5
      # chi web's answers as the session's Bridge would have given them.
      module Mapping
        module_function

        # @param route [Symbol] :turn, :command, :answer, :dismiss,
        #   :dequeue, :cancel, :exit, :recap, :stats, :children, :records
        # @param reply [HTTPTransport::Reply]
        # @param session_id [String]
        # @param remote [String] the remote's name
        # @return [BridgeClient::Response] 504 as the Bridge's 408
        #   deadline_passed; 501 as its 404 not_found (an older worker),
        #   and /command's for one builtin as its 400 unknown_command;
        #   the rest unchanged (202 acks, 409s, the route's own 404s,
        #   403 parent_answer_refused, 502 bridge_error)
        # @raise [Unreachable] 503 not_live, or 404 not_found (the session)
        def response(route, reply, session_id:, remote:)
          json = reply.json.is_a?(Hash) ? reply.json : {}
          case [reply.status, json["error"]]
          in [503, "not_live"] | [404, "not_found"] then raise Unreachable, "#{WorkerLink.not_live(session_id)} on #{remote}"
          in [504, _] then bridge(408, error: "deadline_passed", detail: json["detail"])
          in [501, _] if route == :command && json["command"]
            bridge(400, error: "unknown_command", detail: json["detail"], command: json["command"])
          in [501, _] then bridge(404, error: "not_found", detail: json["detail"])
          else BridgeClient::Response.new(status: reply.status, body: reply.body)
          end
        end

        def stream(sock, status, headers) = BridgeClient::StreamOpen.classify(sock, status, headers)

        def bridge(status, **body) = BridgeClient::Response.new(status: status, body: JSON.generate(body.compact))
      end

      attr_reader :session_id
      # @return [String, nil] the worker followed: its Bridge's epoch (its
      #   start time for a worker from before the epoch in its sidecar)
      attr_accessor :worker_key

      # @param remote [Remote] the remote's chi web
      # @param session_id [String]
      # @param worker_key [String, nil] the live worker's epoch, from the wake
      def initialize(remote:, session_id:, worker_key:)
        @remote = remote
        @session_id = session_id
        @worker_key = worker_key
      end

      def inspect = "#<#{self.class.name} #{@remote.entry.label} #{@session_id}>"

      # No Bridge port here: the worker is reached through chi web.
      def port = nil

      # POST …/turn. history: false (chi web's prompt history is that
      # machine's page's). +author+ is never sent: the remote chi web stamps
      # a turn's author from the token this client holds (Web::Principal),
      # never from the body.
      # @return [BridgeClient::Response]
      def post_turn(prompt:, client_id: nil, no_interrupt: false, images: nil, delivery: nil, author: nil)
        body = { prompt: prompt, client_id: client_id, history: false }
        body[:no_interrupt] = true if no_interrupt
        body[:images] = images if images && !images.empty?
        body[:delivery] = delivery unless delivery.nil? || Delivery.next_step?(delivery)
        post(:turn, "turn", body)
      end

      # POST …/command.
      # @return [BridgeClient::Response]
      def post_command(line:, client_id: nil, card: false)
        body = { line: line, client_id: client_id, history: false }
        body[:card] = true if card
        post(:command, "command", body)
      end

      # POST …/answer (chi web passes client_id on only when it is chi
      # answer's).
      # @return [BridgeClient::Response]
      def answer(id:, selected:, freeform: nil, client_id: nil)
        post(:answer, "answer", { id: id, selected: selected, freeform: freeform, client_id: client_id }.compact,
             read_timeout: ANSWER_READ_TIMEOUT)
      end

      # POST …/question/dismiss.
      # @return [BridgeClient::Response]
      def dismiss_question(id:)
        post(:dismiss, "question/dismiss", { id: id }, read_timeout: ANSWER_READ_TIMEOUT)
      end

      # POST …/turn/:enqueued_id/dequeue.
      # @return [BridgeClient::Response]
      def dequeue(enqueued_id:, client_id: nil)
        post(:dequeue, "turn/#{URI.encode_www_form_component(enqueued_id.to_s)}/dequeue", { client_id: client_id }.compact)
      end

      # POST …/cancel.
      # @return [BridgeClient::Response]
      def cancel(reason:)
        post(:cancel, "cancel", { reason: reason })
      end

      # POST …/exit: the worker asked to exit (chi web passes client_id on
      # only when it is an attached TUI's), stop: true first stopping what
      # the user can stop, ask: false leaving the delegate children out of
      # the list (a UI that can't ask about them).
      # @return [BridgeClient::Response] 200 {status: exiting, discard,
      #   stopped}, 409 held {reason, tasks, holds}, 408 late, 404 an older
      #   worker's
      def request_exit(client_id:, delete: false, stop: false, ask: true)
        body = { client_id: client_id }
        body[:delete] = true if delete
        body[:stop] = "all" if stop
        body[:ask] = false unless ask
        post(:exit, "exit", body)
      end

      # POST …/recap: the saved recap, and a new one asked for.
      # @return [BridgeClient::Response] 200 {enabled, saved, request, min_user_turns, session_off}
      def request_recap = post(:recap, "recap", {})

      # GET …/stats: the worker's metrics (its state's, for an older
      # worker), nil when it didn't give them.
      # @return [Hash, nil]
      # @raise [Unreachable]
      def stats
        response = get(:stats, "stats", read_timeout: READ_TIMEOUT)
        response.status == 200 ? response.json&.dig("metrics") : nil
      end

      # GET …/children/counts: the session's delegates' counts there.
      # @return [Hash] {running, waiting, unreported}
      # @raise [Unreachable] chi web couldn't answer (or the session is gone)
      def children_counts
        response = get(:children, "children/counts", read_timeout: JOIN_READ_TIMEOUT)
        raise Unreachable, "children counts: chi web answered #{response.status}" unless response.status == 200

        response.json
      end

      # GET …/turns/:turn_id/records: a turn's saved tool records and turn
      # record there.
      # @return [Hash] {tool_records: [...], turn_record: {...} | nil}
      # @raise [Unreachable]
      def turn_records(turn_id)
        response = get(:records, "turns/#{URI.encode_www_form_component(turn_id.to_s)}/records",
                       read_timeout: JOIN_READ_TIMEOUT)
        raise Unreachable, "turn records: chi web answered #{response.status}" unless response.status == 200

        response.json
      end

      # Follow the session's events through chi web (see EventStream): with
      # epoch_watch, announce_retries and STREAM_IDLE_TIMEOUT.
      # @return [BridgeClient::EventStream] started
      def follow(snapshot: true, client_id: nil, reconnect_delays: BridgeClient::EventStream::DEFAULT_RECONNECT_DELAYS,
                 rediscover: nil, &on_event)
        BridgeClient::EventStream.new(self, snapshot: snapshot, client_id: client_id, reconnect_delays: reconnect_delays,
                                            rediscover: rediscover, epoch_watch: true, announce_retries: true,
                                            idle_timeout: STREAM_IDLE_TIMEOUT, &on_event).start
      end

      # GET /api/sessions/:id/stream through StreamRequest, classifying chi
      # web's stream answers as Bridge outcomes.
      # @param header_timeout [Float] see BridgeClient::STREAM_HEADER_TIMEOUT
      # @yield [sock] called after response headers arrive, before classifying a
      #   refusal; EventStream uses it to publish the socket for #close
      # @return [BridgeClient::StreamOpen::Opened, BridgeClient::StreamOpen::Refused,
      #   BridgeClient::StreamOpen::Unreachable]
      def open_stream(query: "", last_event_id: nil, header_timeout: BridgeClient::STREAM_HEADER_TIMEOUT, attempts: 1)
        uri = URI(@remote.entry.url)
        return refused("tls_unsupported") if uri.scheme == "https"

        token = @remote.entry.token
        connection = BridgeClient::StreamRequest.open(host: uri.hostname, port: uri.port,
                                                      path: "/api/sessions/#{@session_id}/stream#{query}",
                                                      last_event_id: last_event_id, timeout: header_timeout,
                                                      headers: token ? { "Authorization" => "Bearer #{token}" } : {})
        return BridgeClient::StreamOpen::Unreachable.new(attempts: 1) unless connection

        sock, status, headers = connection
        unless !block_given? || yield(sock)
          sock.close rescue nil
          return BridgeClient::StreamOpen::Unreachable.new(attempts: 1)
        end
        return refused("chunked_unsupported", sock) if headers["transfer-encoding"].to_s.downcase.include?("chunked")

        Mapping.stream(sock, status, headers)
      rescue SystemCallError, SocketError, IOError
        sock&.close rescue nil
        BridgeClient::StreamOpen::Unreachable.new(attempts: 1)
      end

      private

      def post(route, path, body, read_timeout: READ_TIMEOUT)
        reply = @remote.route_request(:post, "/api/sessions/#{@session_id}/#{path}", body: body, read_timeout: read_timeout)
        Mapping.response(route, reply, session_id: @session_id, remote: @remote.name)
      rescue RemoteFailed => e
        raise Unreachable, e.message
      end

      def get(route, path, read_timeout:)
        reply = @remote.route_request(:get, "/api/sessions/#{@session_id}/#{path}", read_timeout: read_timeout)
        Mapping.response(route, reply, session_id: @session_id, remote: @remote.name)
      rescue RemoteFailed => e
        raise Unreachable, e.message
      end

      def refused(reason, sock = nil)
        sock&.close rescue nil
        Log.warn(:attached, "stream_refused", reason: reason, remote: @remote.name)
        BridgeClient::StreamOpen::Unreachable.new(attempts: 1)
      end
    end
  end
end
