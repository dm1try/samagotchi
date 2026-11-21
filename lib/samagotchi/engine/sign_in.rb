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
    # worker and is tied to no turn. Reads and writes @sign_in_flows under
    # @lifecycle_mutex.
    module SignInPart
      # Start a flow for +bundle+: a loopback listener, the address +build+
      # makes for its redirect_uri, the card with its button. Returns at
      # once; the bundle waits on Plugin::SignIn#wait.
      # @param build [#call] (redirect_uri) → the address to send the user to
      # @return [Plugin::SignIn]
      # @raise [ArgumentError] a bad option, a taken port, an address the
      #   card refuses (Plugin::Card's url check); nothing stays open then
      def start_sign_in(bundle:, title:, button:, timeout:, build:, port: nil, path: Plugin::SignIn::DEFAULT_PATH,
                        listener_options: {})
        Plugin::SignIn.check_options!(timeout: timeout, path: path)
        listener = Plugin::SignIn::Listener.new(port: port, path: path, **listener_options)
        flow = Plugin::SignIn.new(bundle: bundle, title: title, button: button, timeout: timeout, listener: listener,
                                  on_settle: ->(settled, outcome) { sign_in_settled(settled, outcome) })
        begin
          address = build.call(flow.redirect_uri).to_s.strip
          card_id = sign_in_card(bundle, title: title, body: Plugin::SignIn::PASTE_LINE,
                                         actions: [{ label: button, url: address }])
        rescue StandardError
          listener.close
          raise
        end
        flow.started(address, card_id)
        @lifecycle_mutex.synchronize { (@sign_in_flows ||= []) << flow }
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
