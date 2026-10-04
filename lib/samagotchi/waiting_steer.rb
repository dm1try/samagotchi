# frozen_string_literal: true

module Samagotchi
  # A message for the running turn that may cut its generation but came too
  # early (the generation hadn't streamed only thinking for long enough):
  # it waits here until the thinking passes steer.cut_after (the Engine
  # checks on each thinking chunk), or until a drain hands the message to
  # the model at a boundary, or the turn ends. One cut covers every waiting
  # message: the first one's source names it.
  #
  # The epoch counts the drains that took input. A caller reads it before
  # it queues its message; a drain after that may have taken the message
  # already, so the message doesn't wait (it may be in the model's prompt).
  # Written from the UIs' threads and the turn's; its own Mutex.
  class WaitingSteer
    def initialize
      @mutex = Mutex.new
      @source = nil
      @epoch = 0
    end

    # @return [Integer] the drains that took input so far
    def epoch
      @mutex.synchronize { @epoch }
    end

    # +source+'s message waits for a cut, unless a drain took input since
    # +epoch+. Returns whether it waits.
    def wait!(source, epoch: nil)
      @mutex.synchronize do
        next false if epoch && epoch != @epoch

        @source ||= source.to_s
        true
      end
    end

    def waiting?
      @mutex.synchronize { !@source.nil? }
    end

    # The waiting source, taken (nil when none waits).
    def take
      @mutex.synchronize do
        source = @source
        @source = nil
        source
      end
    end

    # A drain took input: what waited is delivered.
    def delivered!
      @mutex.synchronize do
        @epoch += 1
        @source = nil
      end
    end

    # The turn ended, or a cut happened: nothing waits.
    def clear!
      @mutex.synchronize { @source = nil }
    end
  end
end
