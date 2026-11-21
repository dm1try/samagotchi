# frozen_string_literal: true

require "uri"
require_relative "../log"
require_relative "../plugin/sign_in"

module Samagotchi
  class Engine
    # Browser sign-ins (ctx.sign_in, docs/plugins.md, Sign-in): the flows
    # waiting now, their cards, the /callback paste, and their end when the
    # worker leaves (#shutdown closes every one first, so a card a later
    # worker loads never offers a dead sign-in). A flow never outlives its
    # worker and is tied to no turn (unless the bundle passes cancel:, a
    # turn's controller). Reads and writes @sign_in_flows under
    # @lifecycle_mutex.
    module SignInPart
      # Start a flow for +bundle+: a loopback listener, the address +build+
      # makes for its redirect_uri, the card with its button. Returns at
      # once; the bundle waits on Plugin::SignIn#wait. Once #shutdown has
      # begun it starts nothing: an already-stopped flow, no card, no port
      # (a command or a thread of the plugin's may still call it then). The
      # flow is listed before its card shows, so a shutdown in between
      # stops it and its card says cancelled.
      # @param build [#call] (redirect_uri) → the address to send the user to
      # @param cancel [CancellationController, nil] ends it :cancelled (a
      #   tool's turn's Stop, when the bundle passes ctx.cancel_controller)
      # @return [Plugin::SignIn]
      # @raise [ArgumentError] a bad option, a taken port, an address the
      #   card refuses (Plugin::Card's url check); nothing stays open then
      def start_sign_in(bundle:, title:, button:, timeout:, build:, port: nil, path: Plugin::SignIn::DEFAULT_PATH,
                        cancel: nil, listener_options: {})
        Plugin::SignIn.check_options!(timeout: timeout, path: path, cancel: cancel)
        return Plugin::SignIn.stopped(bundle: bundle, title: title) if sign_ins_closed?

        listener = Plugin::SignIn::Listener.new(port: port, path: path, **listener_options)
        flow = Plugin::SignIn.new(bundle: bundle, title: title, button: button, timeout: timeout, listener: listener,
                                  cancel: cancel, on_settle: ->(settled, outcome) { sign_in_settled(settled, outcome) })
        begin
          address = build.call(flow.redirect_uri).to_s.strip
          card = { title: title, body: Plugin::SignIn::PASTE_LINE, actions: [{ label: button, url: address }] }
          # The card's checks (the address), before anything is listed.
          card_id = Plugin::Card.build(source: bundle, level: :info, id: nil, **card)[:id]
          flow.started(address, card_id)
        rescue StandardError
          listener.close
          raise
        end
        unless list_sign_in(flow)
          listener.close
          return Plugin::SignIn.stopped(bundle: bundle, title: title)
        end

        show_sign_in_card(flow, card)
        Log.info(:plugins, "sign_in_started", bundle: bundle, card: card_id, port: listener.port, to: address_shown(address))
        flow.listen
        flow
      end

      # Whether a flow waits for its callback (WorkerIdleExit holds then).
      def sign_in_waiting? = waiting_sign_ins.any?

      # /callback <address>: the waiting flow whose redirect_uri +address+
      # starts with takes its query.
      # @return [Array(Boolean, String)] settled, and the line to answer
      def sign_in_callback(address)
        address = address.to_s.strip
        flows = waiting_sign_ins
        return [false, "no sign-in is waiting"] if flows.empty?

        flow = flows.find { |waiting| waiting.redirect_of?(address) }
        return [false, "that isn't this sign-in's address (it starts #{flows.first.redirect_uri})"] unless flow
        return [false, "that isn't this sign-in's address"] unless flow.offer(address.split("?", 2)[1])

        [true, "Got it."]
      end

      private

      def sign_ins_closed? = @lifecycle_mutex.synchronize { @shut_down }

      # @return [Boolean] false once #shutdown has begun (nothing listed)
      def list_sign_in(flow)
        @lifecycle_mutex.synchronize do
          next false if @shut_down

          (@sign_in_flows ||= []) << flow
          true
        end
      end

      # Its card, unless a shutdown stopped it already; one that stopped it
      # while the card showed gets its ended card again, after this one.
      def show_sign_in_card(flow, card)
        return unless flow.waiting?

        sign_in_card(flow.bundle, id: flow.card_id, **card)
        ended = Plugin::SignIn.ended_card(flow, flow.outcome) unless flow.waiting?
        sign_in_card(flow.bundle, **ended) if ended
      end

      # Read off the lock: a flow past its deadline ends in #waiting?, and
      # its #sign_in_settled takes the lock.
      def waiting_sign_ins
        @lifecycle_mutex.synchronize { (@sign_in_flows || []).dup }.select(&:waiting?)
      end

      # The worker leaves (#shutdown): each waiting flow stops, its card
      # replaced by the cancelled one, before the services go.
      def stop_sign_ins
        waiting_sign_ins.each(&:stop)
      end

      # A flow ended: it leaves the list; one that ended without a callback
      # gets its ended card in place of its button. :done leaves the card
      # for the bundle's result.
      def sign_in_settled(flow, outcome)
        @lifecycle_mutex.synchronize { @sign_in_flows&.delete(flow) }
        Log.info(:plugins, "sign_in_ended", bundle: flow.bundle, card: flow.card_id, outcome: outcome)
        card = Plugin::SignIn.ended_card(flow, outcome)
        sign_in_card(flow.bundle, **card) if card
      rescue StandardError => e
        Log.warn(:plugins, "sign_in_card_failed", bundle: flow.bundle, error: e.class.name)
      end

      # A flow's card is never a running turn's (a timeout fires whenever):
      # shown as an anytime command's is while a turn runs, else as a
      # between-turns card (a command's, held for its command_ran).
      def sign_in_card(bundle, **card)
        return running_anytime { show_card(source: bundle, **card) } if turn_running?

        show_card(source: bundle, **card)
      end

      # Its host and path: an authorize address can carry a login hint.
      def address_shown(address)
        uri = URI.parse(address)
        "#{uri.host}#{uri.path}"
      rescue URI::InvalidURIError
        "?"
      end
    end
  end
end
