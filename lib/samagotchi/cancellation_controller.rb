# frozen_string_literal: true

module Samagotchi
  # One turn's cancel signal. #cancel! flips it once, keeps the reason and
  # calls every listener registered with #on_cancel (a listener added after
  # the cancel runs at once). The HTTP layer listens to abort an in-flight
  # request; the loops poll #cancelled? between steps.
  class CancellationController
    def initialize
      @mutex = Mutex.new
      @cancelled = false
      @reason = nil
      @listeners = {}
      @next_listener_id = 0
    end

    def cancel!(reason = :manual)
      listeners = []
      @mutex.synchronize do
        return false if @cancelled

        @cancelled = true
        @reason = reason
        listeners = @listeners.values
        @listeners = {}
      end

      listeners.each do |listener|
        listener.call(reason)
      rescue StandardError
        nil
      end
      true
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end

    def reason
      @mutex.synchronize { @reason }
    end

    def on_cancel(&block)
      raise ArgumentError, "block required" unless block

      immediate_reason = nil
      listener_id = nil
      @mutex.synchronize do
        if @cancelled
          immediate_reason = @reason
        else
          listener_id = next_listener_id
          @listeners[listener_id] = block
        end
      end

      if immediate_reason
        block.call(immediate_reason)
        nil
      else
        listener_id
      end
    end

    def remove_listener(listener_id)
      return unless listener_id

      @mutex.synchronize { @listeners.delete(listener_id) }
    end

    private

    def next_listener_id
      @next_listener_id += 1
    end
  end
end
