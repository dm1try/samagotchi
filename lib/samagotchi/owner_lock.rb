# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Samagotchi
  # The single-owner lock of a session: whichever process runs the session's
  # Engine (a SessionManager worker or the in-process TUI) holds an exclusive
  # flock on `<session_dir>/owner.lock` for its lifetime. A second would-be
  # owner backs off, so one session never gets two Engines.
  #
  # flock locks belong to the open file description: the kernel releases them
  # when the owner exits (however it dies), Ruby opens files close-on-exec so a
  # spawned grandchild never inherits one, and probing from another descriptor
  # (even in the owner's own process) never releases the owner's lock.
  class OwnerLock
    FILE = "owner.lock"
    DEFAULT_WAIT = 2.0
    RETRY_INTERVAL = 0.05
    OWNER_READ_ATTEMPTS = 10
    # Seconds .await_release waits past a leaving worker's own budget: its
    # last save, the task watch's absorb, its exit.
    LEAVE_MARGIN = 5.0
    # Seconds between .await_release's looks at the lock.
    RELEASE_POLL = 0.1

    # Who holds the lock, as .owner reads it from the lock file. Its fields
    # may be nil for a moment right after acquisition.
    # kind: "worker" or "tui"; pid as written (an Integer). leaving_at (an
    # ISO 8601 time) and leave_wait (seconds): set once a worker is leaving
    # (#mark_leaving), its Bridge closed, the lock held for its last work
    # (the recap on leave) for up to leave_wait.
    Owner = Data.define(:pid, :kind, :started_at, :leaving_at, :leave_wait) do
      def initialize(pid: nil, kind: nil, started_at: nil, leaving_at: nil, leave_wait: nil) = super

      # The interactive TUI's: it reads no input files and takes no notes.
      def tui? = kind == "tui"

      def worker? = kind == "worker"

      # A worker that closed its Bridge and releases the lock once its
      # last work is done.
      def leaving? = worker? && !leaving_at.nil?

      # Seconds of its leave_wait still to run at +now+ (0 when past).
      def leave_left(now = Time.now)
        started = Time.iso8601(leaving_at.to_s)
        [leave_wait.to_f - (now - started), 0.0].max
      rescue ArgumentError
        leave_wait.to_f
      end
    end

    # Take the lock, retrying for up to +wait+ seconds (another process's
    # #owner probe holds it for a moment). On success the owner's pid and kind
    # are written into the lock file for #owner to report.
    # @param session_dir [String]
    # @param kind [String] "worker" or "tui"
    # @return [OwnerLock, nil] nil when another owner holds it
    def self.acquire(session_dir, kind:, wait: DEFAULT_WAIT)
      FileUtils.mkdir_p(session_dir)
      # Held open on purpose: the flock lives as long as the OwnerLock (#release closes it).
      file = File.open(path(session_dir), File::RDWR | File::CREAT, 0o644) # rubocop:disable Style/FileOpen
      deadline = monotonic_now + wait.to_f
      until file.flock(File::LOCK_EX | File::LOCK_NB)
        if monotonic_now >= deadline
          file.close
          return nil
        end
        sleep(RETRY_INTERVAL)
      end
      new(file, kind: kind)
    end

    # The current owner, read without disturbing it.
    # @param session_dir [String]
    # @return [Owner, nil] while held, nil when free
    def self.owner(session_dir)
      File.open(path(session_dir), File::RDONLY) do |file|
        if file.flock(File::LOCK_SH | File::LOCK_NB)
          file.flock(File::LOCK_UN)
          return nil
        end
        # A new owner truncates, then writes: retry briefly rather than
        # report an owner of unknown kind.
        data = {}
        OWNER_READ_ATTEMPTS.times do
          data = parse(File.read(file.path))
          break unless data.empty?

          sleep(RETRY_INTERVAL / 5)
        end
        Owner.new(pid: data["pid"], kind: data["kind"], started_at: data["started_at"],
                  leaving_at: data["leaving_at"], leave_wait: data["leave_wait"])
      end
    rescue Errno::ENOENT
      nil
    end

    # Wait for a leaving worker (Owner#leaving?) to release the lock: up to
    # its leave_wait still to run plus LEAVE_MARGIN, looking every
    # RELEASE_POLL seconds. An owner that isn't leaving (a live worker, a
    # stuck one, a chi REPL) or no owner returns at once. A Ctrl-C (Interrupt)
    # stops the wait as it would any sleep.
    # @param on_wait [#call, nil] called once with the Owner before waiting
    # @return [Symbol] :not_leaving, :released, or :timeout (still held)
    def self.await_release(session_dir, on_wait: nil, margin: LEAVE_MARGIN, clock: method(:monotonic_now),
                           sleeper: method(:sleep), now: -> { Time.now })
      holder = owner(session_dir)
      return :not_leaving unless holder&.leaving?

      on_wait&.call(holder)
      deadline = clock.call + holder.leave_left(now.call) + margin
      loop do
        return :released unless owner(session_dir)
        return :timeout if clock.call >= deadline

        sleeper.call(RELEASE_POLL)
      end
    end

    def self.path(session_dir)
      File.join(session_dir, FILE)
    end

    def self.parse(raw)
      data = JSON.parse(raw.to_s)
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError
      {}
    end
    private_class_method :parse

    def self.monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic_now

    attr_reader :kind

    def initialize(file, kind:)
      @file = file
      @kind = kind.to_s
      @record = { "pid" => Process.pid, "kind" => @kind, "started_at" => Time.now.iso8601(3) }
      write_record
    end

    # The holder is leaving: its Bridge is closed and it releases the lock
    # within +wait+ seconds (its recap on leave's timeout), which
    # .await_release reads. .owner retries the moment the file is empty.
    # @param wait [Numeric]
    def mark_leaving(wait:)
      return if @file.closed?

      @record = @record.merge("leaving_at" => Time.now.iso8601(3), "leave_wait" => wait.to_f)
      write_record
    end

    def write_record
      @file.truncate(0)
      @file.rewind
      @file.write(JSON.generate(@record))
      @file.flush
    end
    private :write_record

    # Release the lock (process exit releases it too).
    def release
      return if @file.closed?

      @file.flock(File::LOCK_UN)
      @file.close
    end
  end
end
