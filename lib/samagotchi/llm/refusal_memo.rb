# frozen_string_literal: true

module Samagotchi
  module LLM
    # What a host refused, remembered for its holder's life (an adapter: the
    # host's, HostRegistry keeps one per worker; ChatLoop: the worker's): a
    # +kind+ (a Symbol) for one model, or for the whole host when the model
    # is nil, with a value (true, or what the refusal named: an output cap).
    # The turn thread and the model-list reads share HostRegistry's adapter
    # (an IdleClient's adapter is its own), so every read and write takes the
    # lock.
    class RefusalMemo
      def initialize
        @mutex = Mutex.new
        @facts = {}
      end

      # Remember +kind+ for +model+ (nil: the host) as +value+.
      def remember(kind, model = nil, value = true)
        @mutex.synchronize { @facts[[kind, model]] = value }
      end

      # Whether +kind+ is remembered for +model+ (nil: the host).
      def refused?(kind, model = nil) = @mutex.synchronize { @facts.key?([kind, model]) }

      # The value remembered for +kind+ and +model+, or nil.
      def [](kind, model = nil) = @mutex.synchronize { @facts[[kind, model]] }
    end
  end
end
