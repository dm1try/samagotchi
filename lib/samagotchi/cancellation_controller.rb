# frozen_string_literal: true

module Samagotchi
  # One turn's cancel signal. #cancel! flips it once, keeps the reason and
  # calls every listener registered with #on_cancel (a listener added after
  # the cancel runs at once). The HTTP layer listens to abort an in-flight
  # request; the loops poll #cancelled? between steps.
  #
  # #generation gives one model request a child controller: cancelled with
  # the turn, or alone by #cancel_generation! (a plugin cutting a looping
  # generation while the turn goes on).
  class CancellationController
    def initialize
      @mutex = Mutex.new
      @cancelled = false
      @reason = nil
      @detail = nil
      @listeners = {}
      @next_listener_id = 0
      @generation = nil
    end

    # @param detail [Object, nil] what the canceller says about it (a cut
    #   generation's {by:, reason:})
    def cancel!(reason = :manual, detail = nil)
      listeners = []
      @mutex.synchronize do
        return false if @cancelled

        @cancelled = true
        @reason = reason
        @detail = detail
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

    def detail
      @mutex.synchronize { @detail }
    end

    # Yields a child controller for one generation: it is cancelled when
    # this one is, and #cancel_generation! cancels it alone. Gone after the
    # block.
    def generation
      child = CancellationController.new
      listener_id = on_cancel { |reason| child.cancel!(reason) }
      @mutex.synchronize { @generation = child }
      yield child
    ensure
      @mutex.synchronize { @generation = nil if @generation.equal?(child) }
      remove_listener(listener_id)
    end

    # The running generation was cancelled (cut, or with the turn).
    def generation_cancelled?
      child = @mutex.synchronize { @generation }
      child ? child.cancelled? : false
    end

    # Cancel the running generation only. False with none, or when it was
    # already cancelled (cut before, or the turn was cancelled).
    def cancel_generation!(reason = :hook, detail = nil)
      child = @mutex.synchronize { @generation }
      return false unless child

      child.cancel!(reason, detail)
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
        yield(immediate_reason)
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
