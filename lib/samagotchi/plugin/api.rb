# frozen_string_literal: true

require_relative "../log"

module Samagotchi
  module Plugin
    # What a plugin's #register(chi) gets (docs/plugins.md). Each call
    # stages a registration and checks it; Loader commits them all once
    # #register returns, so a plugin that raises halfway adds nothing.
    class Api
      # @param bundle [String]
      # @param label [String] "<file> (bundle <name>)": what hooks and
      #   failures are named by
      # @param registries [Registries]
      # @param context [Context, nil] what handlers get as ctx
      def initialize(bundle:, label:, registries:, context: nil)
        @bundle = bundle
        @label = label
        @registries = registries
        @context = context
        @hooks = []
      end

      # Run the block on a hook event (docs/hooks.md: :before_turn,
      # :after_turn, :before_tool_call, …), like a bundle's hooks/*.rb:
      # the block gets the event hash, with event[:notify] and the other
      # helpers. A block that raises is logged (not shown) and skipped.
      # @param priority [Integer] lower runs first among bundle hooks
      def on(event, priority: 100, &block)
        raise ArgumentError, "on(#{event.inspect}) needs a block" unless block
        raise ArgumentError, "on: the event must be a Symbol or String" unless event.is_a?(Symbol) || event.is_a?(String)

        @hooks << { event: event.to_sym, priority: Integer(priority), block: block }
        nil
      end

      # Register what was staged. Called by Loader after #register.
      def commit!
        @hooks.each do |hook|
          bundle = @bundle
          label = @label
          block = hook[:block]
          @registries.hooks.register_bundle(bundle, hook[:event], hook_name: label.split(" ").first,
                                                                  priority: hook[:priority]) do |event|
            block.call(event)
          rescue StandardError => e
            # Logged only: a turn's live region is on screen.
            Log.warn(:plugins, "plugin_hook_failed", bundle: bundle, event: hook[:event].to_s, error: e.class.name,
                                                     msg: "#{label} #{hook[:event]} hook failed: #{e.message}")
          end
        end
      end

      # @return [Hash] how many of each it registered (for the log)
      def counts = { hooks: @hooks.size }
    end
  end
end
