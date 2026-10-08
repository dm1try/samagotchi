# frozen_string_literal: true

require "open3"

module Samagotchi
  # A command run in a process group of its own, so a stop reaches what it
  # started too: TERM the group, a grace, then KILL it. Execute, TaskRuntime
  # and ContextFetch spawn and stop their commands here, each with its own
  # grace and its own "has it stopped?" check (the leader gone, the pipes
  # closed, the pid reaped). The mcp bundle's client stops its server here
  # too (after closing its stdin), so it requires chi >= 0.33.0.
  module ProcessGroup
    # A group that is gone, or one that isn't ours to signal.
    QUIET = [Errno::ESRCH, Errno::EPERM].freeze
    READ_CHUNK_BYTES = 65_536

    module_function

    # Process.spawn in a new process group, whose id is the pid.
    # @return [Integer] the pid
    def spawn(env, *argv, **) = Process.spawn(env, *argv, pgroup: true, **)

    # Sends +sig+ to every process in the group +pgid+.
    # @param leader [Boolean] when the group can't be signalled, signal the
    #   process +pgid+ alone (a leader that left its group)
    # @param quiet [Array<Class>] the errors that mean there is nothing to
    #   signal; any other is raised
    # @return [Boolean] whether a signal was sent
    def signal(pgid, sig, leader: false, quiet: QUIET)
      check!(pgid)
      Process.kill(sig, -pgid)
      true
    rescue *quiet
      return false unless leader

      begin
        Process.kill(sig, pgid)
        true
      rescue *quiet
        false
      end
    end

    # A pid chi may signal or ask about: an Integer above 1. kill(0) and
    # kill(-1) reach chi's own group and every process of the user, so a
    # pid that isn't one (a broken or edited record) never gets that far.
    def signalable?(pid) = pid.is_a?(Integer) && pid > 1

    # @raise [ArgumentError] unless #signalable?
    def check!(pid)
      raise ArgumentError, "not a process group chi may signal: #{pid.inspect}" unless signalable?(pid)
    end

    # Whether +pid+ runs and leads its own group, as #spawn's process does
    # (not, then, a reused pid in some other group).
    # @param started [String, nil] the start time #start_time read when chi
    #   spawned it: a process that started at another time is one that
    #   reused the pid, even as a group leader. nil checks the group only (a
    #   record from an older chi), and so does a time that can't be read
    #   now (a ps that failed once must not disown a live task).
    # @param start_time [#call] (pid) the reader, #start_time by default
    def leader?(pid, started: nil, start_time: method(:start_time))
      return false unless signalable?(pid) && Process.getpgid(pid) == pid
      return true if started.nil?

      now = start_time.call(pid)
      now.nil? || now == started
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    # When +pid+'s process started, as an opaque string to compare: the
    # start in clock ticks from /proc/PID/stat on Linux, ps's lstart (to the
    # second, in UTC) elsewhere. nil when it isn't running or can't be read.
    # @return [String, nil]
    def start_time(pid)
      return nil unless signalable?(pid)

      stat = "/proc/#{pid}/stat"
      return proc_start_time(File.read(stat)) if File.exist?(stat)

      out, status = Open3.capture2({ "LC_ALL" => "C", "TZ" => "UTC" }, "ps", "-o", "lstart=", "-p", pid.to_s,
                                   err: File::NULL)
      time = out.strip
      status.success? && !time.empty? ? time : nil
    rescue SystemCallError, IOError
      nil
    end

    # Field 22 (starttime); the command name (field 2) may hold spaces and
    # parentheses, so the fields are counted after its last ")".
    def proc_start_time(stat) = stat[/\A.*\)\s(.*)\z/m, 1]&.split&.[](19)

    # Whether +pid+ is still running (or a zombie not reaped yet).
    # @raise [ArgumentError] unless #signalable?
    def alive?(pid)
      check!(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # How long #stop waits for +stopped+ after the KILL by default.
    KILL_WAIT_SEC = 1.0

    # TERMs the group, waits up to +grace+ for +stopped+, then KILLs it and
    # waits up to +kill_wait+ for +stopped+ again (a KILL is delivered, not
    # done, when kill returns).
    # @param stopped [#call] true once it has stopped (default: the leader
    #   is gone)
    # @param wait [#call] (seconds) between two checks (default: a sleep)
    # @param signal_options [Hash] for #signal (leader:, quiet:)
    # @return [Boolean] true when it stopped within the grace (no KILL sent)
    # @raise [ArgumentError] unless #signalable?
    def stop(pgid, grace:, poll:, stopped: -> { !alive?(pgid) }, wait: ->(seconds) { sleep(seconds) },
             kill_wait: KILL_WAIT_SEC, **signal_options)
      check!(pgid)
      signal(pgid, "TERM", **signal_options)
      return true if wait_for(stopped, grace, poll, wait)

      signal(pgid, "KILL", **signal_options)
      wait_for(stopped, kill_wait, poll, wait)
      false
    end

    # Checks +stopped+ every +poll+ until it is true or +seconds+ are over.
    # @return [Boolean] whether it stopped
    def wait_for(stopped, seconds, poll, wait)
      deadline = monotonic + seconds
      until (done = stopped.call) || monotonic >= deadline
        wait.call(poll)
      end
      done ? true : false
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Reads a pipe in chunks on a thread of its own, so the output read so
    # far survives the pipe being closed under it (or the thread killed).
    class PipeReader
      # @param cap [Integer, nil] the most bytes it keeps
      # @param keep [:head, :tail] past the cap: :head stops reading (and
      #   #over? is true), :tail keeps the last +cap+ bytes
      def initialize(io, cap: nil, keep: :head, chunk: READ_CHUNK_BYTES)
        @io = io
        @buffer = String.new(encoding: Encoding::BINARY)
        @over = false
        @thread = Thread.new do
          Thread.current.report_on_exception = false
          loop { break unless take(io.readpartial(chunk), cap, keep) }
        rescue IOError # EOFError is one
          nil
        end
      end

      def done? = !@thread.alive?

      # Whether a :head reader stopped at its cap.
      def over? = @over

      # @return [Thread, nil] the thread when it ended within +seconds+
      def wait(seconds) = @thread.join(seconds)

      def kill = @thread.kill

      # Closes the pipe once the thread had +poll+ to end by itself (a
      # reader still blocked gets IOError), then ends the thread, killing it
      # after +grace+. The text is safe to read afterwards.
      def finish(poll:, grace:)
        @thread.join(poll) unless done?
        close_quietly
        @thread.kill unless @thread.join(grace)
      end

      # What it read, in +encoding+ (default: the pipe's).
      def text(encoding = @io.external_encoding || Encoding.default_external)
        @buffer.dup.force_encoding(encoding)
      end

      private

      # @return [Boolean] whether to read on
      def take(chunk, cap, keep)
        if cap && keep == :head && @buffer.bytesize + chunk.bytesize > cap
          @over = true
          return false
        end

        @buffer << chunk
        @buffer = @buffer.byteslice(-cap, cap) if cap && keep == :tail && @buffer.bytesize > cap
        true
      end

      def close_quietly
        @io.close unless @io.closed?
      rescue IOError
        nil
      end
    end
  end
end
