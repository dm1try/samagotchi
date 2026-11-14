# frozen_string_literal: true

require_relative "worker_idle_exit"

module Samagotchi
  # One exit at a time (Worker#exit_request, Bridge POST /exit): the kind
  # being taken (claimed before the slow stop-all, so a request of another
  # kind meanwhile is refused, not told it went through), the exit taken
  # (who asked, whether it deletes or restarts) and what the last stop-all
  # stopped. A pure state object: it calls nothing while it holds its lock.
  #
  # Threads: safe from any thread. Its fields change only under its own
  # mutex, and the taken exit is one value replaced whole (#taken), so a
  # reader never sees a kind with another request's flags. Today every
  # writer also holds the event lock (Engine#synchronize_events: the Bridge's
  # /exit, the loop's leave); nothing here depends on it. Lock order: the
  # event lock, then this one.
  class WorkerExitClaim
    # The answer for a request that doesn't get the claim, boxed so a nil
    # (accepted) is told apart from "claimed".
    Refused = Data.define(:value)

    # The exit taken: its +kind+ (:exit, :delete, :restart) and the client
    # that asked (+by+).
    Taken = Data.define(:kind, :by) do
      def restart? = kind == :restart
      def deletes? = kind == :delete
    end

    def initialize
      @mutex = Mutex.new
      # The kind being taken, or taken (:exit, :delete, :restart); nil when free.
      @claim = nil
      # The Taken exit once accepted; nil while free or being taken.
      @taken = nil
      # The last stop-all's HoldStop::Stopped (Worker#exit_hold); kept across a
      # forget, cleared by a plain exit's accept.
      @stopped = nil
    end

    # @return [Refused, nil] nil when this request now holds the claim;
    #   else its answer: nil (accepted: an exit of the same kind is already
    #   taken) or WorkerIdleExit.leaving (one of another kind is, or is still
    #   being taken)
    def claim(kind)
      @mutex.synchronize do
        next Refused.new(value: nil) if @claim == kind && @taken
        next Refused.new(value: WorkerIdleExit.leaving(@claim)) if @claim

        @claim = kind
        nil
      end
    end

    # The claimed exit goes through: it is taken by +by+ (a client id), and
    # a plain one (no +stop+) drops the last stop-all's list.
    def accept(by:, stop:)
      @mutex.synchronize do
        @stopped = nil unless stop
        @taken = Taken.new(kind: @claim, by: by)
      end
      nil
    end

    # What a stop-all exit stopped (HoldStop#stop_all), for the Bridge's 200.
    def stopped!(stopped)
      @mutex.synchronize { @stopped = stopped }
    end

    # The taken exit is let go: held at the leave, or its hand-off failed.
    def forget
      @mutex.synchronize do
        @claim = nil
        @taken = nil
      end
      nil
    end

    # A request that raised lets its claim go, unless its exit was taken.
    def release
      @mutex.synchronize do
        next if @taken

        @claim = nil
      end
      nil
    end

    # @return [Taken, nil] the exit taken, one read: its kind and asker
    #   always belong together
    def taken = @mutex.synchronize { @taken }

    def taken? = !taken.nil?

    def restart? = taken&.restart? || false

    def deletes? = taken&.deletes? || false

    # @return [HoldStop::Stopped, nil] the last stop-all's list
    def stopped = @mutex.synchronize { @stopped }
  end
end
