# frozen_string_literal: true

require "fileutils"
require_relative "session"

module Samagotchi
  # A session's transition lock: the one code that flocks a session folder's
  # LOCK (continue.lock). A multi-step lifecycle transition (a continue
  # today) holds it exclusively; an arrival or a check that must not overlap
  # one (a followed send, a link or chain delete) takes it shared and
  # non-blocking, and a read-only caller only probes it (#held?).
  #
  # Rules (docs/internals/session-lifecycle.md, "Locks and crash repair"):
  # - Order: transition locks (several ids sorted) before any owner.lock.
  # - The hold is the current thread's (Thread#thread_variable_*, not
  #   fiber-local and never per process: chi web is multi-threaded). A
  #   thread holding an id exclusively passes through #exclusive and #shared
  #   of that id without touching the file (each acquisition is a fresh open:
  #   a second flock on a held fd, or a dup of it, would convert the lock).
  #   Work handed to another thread does not carry the hold: it takes it
  #   again, or is refused.
  # - No fork while held: a forked child keeps the flock. Workers start
  #   through Process.spawn, whose descriptors are close-on-exec.
  module SessionTransition
    # The lock file in a session's folder. The name stays continue.lock: an
    # older chi's continue, follow_guard and delete honour it.
    LOCK = "continue.lock"
    # How often an exclusive try with a deadline tries again.
    RETRY = 0.01
    # The thread variable holding this thread's exclusive holds
    # ({ lock path => true }).
    REGISTRY = :samagotchi_session_transition

    # What #exclusive yields: the ids it holds and why.
    Token = Data.define(:ids, :kind)

    # An exclusive hold not taken by its deadline, or an arrival that met
    # one. It owns its refusal text, which names the holder (.held) when it
    # can be told: a continue ("being continued", "as X" once its intent
    # names the new link), a delete ("being deleted"), a stop ("being
    # stopped"), an archive ("being archived"), else "busy with another
    # change" (a shared holder, an older chi's, a kind this chi doesn't
    # name). A nil +session_id+ says "this session" (a peer's line,
    # which carries no id).
    class Busy < StandardError
      WORDS = { continue: "being continued", delete: "being deleted", stop: "being stopped", archive: "being archived",
                nil => "busy with another change" }.freeze

      # +kind+ the holder's (nil: not told), +successor_id+ the new link a
      # continue holding it names.
      attr_reader :session_id, :kind, :successor_id

      def initialize(session_id, kind: nil, successor_id: nil)
        @session_id = session_id
        @kind = kind
        @successor_id = successor_id
        super("#{words}; try again in a moment")
      end

      # The refusal of an arrival or a taker that met +session_id+'s lock
      # held: the one place that says who holds it. The kind the exclusive
      # holder recorded (SessionTransition.holder) first: a delete, a stop
      # or an archive is said as such whatever else is on disk (a crashed
      # continue's intent); else a continue in flight
      # (ContinueIntent.in_flight: an older chi's records no kind) names
      # its new link.
      # @return [Busy]
      def self.held(session_id, state_dir:)
        kind = SessionTransition.holder(session_id, state_dir: state_dir)
        return new(session_id, kind: kind) if SessionTransition.other_than_continue?(kind)

        require_relative "continue_intent"
        successor = session_id && ContinueIntent.in_flight(session_id, state_dir: state_dir)
        new(session_id, kind: successor ? :continue : kind, successor_id: successor)
      end

      private

      def words
        if @successor_id
          require_relative "session_chain/successor"
          return SessionChain::Continued.new(@session_id, @successor_id, in_flight: true).message
        end

        subject = @session_id ? "session #{@session_id.to_s[0, 8]}" : "this session"
        "#{subject} is #{WORDS.fetch(@kind, WORDS[nil])}"
      end
    end

    module_function

    # The block under an exclusive hold of every id's lock, taken in sorted
    # order, each folder created when missing. Ids this thread already holds
    # are passed through. +deadline+ nil blocks until each lock is free;
    # seconds try each until then.
    # @yieldparam token [Token]
    # @return the block's value
    # @raise [Busy] an id not taken in time (the ids taken before it are let go)
    # @raise [ArgumentError] an id that isn't a session id
    def exclusive(ids, kind:, state_dir:, deadline: nil)
      ids = Array(ids).uniq.sort
      bad = ids.reject { |id| Session.valid_id?(id) }
      raise ArgumentError, "not a session id: #{bad.first.inspect}" unless bad.empty?

      ends_at = monotonic + deadline if deadline
      taken = []
      ids.each do |id|
        path = lock_path(id, state_dir)
        next if holds.key?(path)

        FileUtils.mkdir_p(File.dirname(path))
        file = File.open(path, File::RDWR | File::CREAT, 0o600) # rubocop:disable Style/FileOpen -- held past this loop, closed in the ensure
        taken << [path, file]
        lock_until(file, ends_at) or raise Busy.held(id, state_dir: state_dir)
        holds[path] = true
        mark(file, kind)
      end
      yield Token.new(ids: ids, kind: kind)
    ensure
      # Only ids this call took: none of them was held before it. A kind is
      # cleared only from a lock this call held (never another holder's).
      taken&.reverse_each do |path, file|
        mark(file, nil) if holds.delete(path)
        file.close
      end
    end

    # The block under an exclusive hold of +id+'s lock taken in one try,
    # its argument nil when it isn't (another holder, this thread's included:
    # a crash repair never undoes the continue running on its own thread).
    # The folder is not created (its lock file is). Crash repair's
    # (SessionContinue.repair_interrupted).
    # @yieldparam token [Token, nil]
    # @raise [Errno::ENOENT] the folder is gone
    def try_exclusive(id, kind:, state_dir:)
      return yield(nil) unless Session.valid_id?(id)

      path = lock_path(id, state_dir)
      return yield(nil) if holds.key?(path)

      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        next yield(nil) unless file.flock(File::LOCK_EX | File::LOCK_NB)

        holds[path] = true
        mark(file, kind)
        begin
          yield Token.new(ids: [id], kind: kind)
        ensure
          holds.delete(path)
          mark(file, nil)
        end
      end
    end

    # The block under a shared hold of +id+'s lock, so no transition of it
    # starts until the block returns; its argument is false when another
    # holds it exclusively now (not waited for: nothing is held then) or
    # +id+ isn't a session id, true when this thread holds it. The lock
    # file is created when missing, and the folder only for a session whose
    # file is there: a deleted session's folder is never made again
    # (nothing is held, true: no transition holds a lock in a folder that
    # isn't there) and the caller's own gone refusal follows. A lock file this call made for a
    # session whose file is gone once the block returns (a delete that
    # removed it meanwhile, a folder with no session) is taken back
    # (#forget). A caller that may not write the session folder (a peer's
    # chi behind the mailbox door: the sessions folder read-only) holds an
    # existing lock file opened read-only, and, with none there to open,
    # holds nothing (true).
    # @yieldparam held [Boolean]
    # @return the block's value
    def shared(id, state_dir:)
      return yield(false) unless Session.valid_id?(id)

      path = lock_path(id, state_dir)
      return yield(true) if holds.key?(path)

      made = !File.exist?(path)
      file = open_shared(id, path, state_dir) or return yield(true)
      begin
        yield(file.flock(File::LOCK_SH | File::LOCK_NB) ? true : false)
      ensure
        file.close
        forget(id, state_dir: state_dir) if made
      end
    end

    # Whether +id+'s lock is held exclusively now, by anyone (this thread
    # too: a kernel probe, the registry is not read). Creates nothing; the
    # shared try is let go at once.
    def held?(id, state_dir:)
      return false unless Session.valid_id?(id)

      File.open(lock_path(id, state_dir), File::RDONLY) { |file| !file.flock(File::LOCK_SH | File::LOCK_NB) }
    rescue Errno::ENOENT
      false
    end

    # The kind the exclusive holder of +id+'s lock recorded (#exclusive's
    # and #try_exclusive's +kind+, written into the lock file while held),
    # one of Busy::WORDS' kinds: nil when nobody holds it exclusively now (a
    # shared holder, such as a send, is no transition), or the holder
    # recorded none this chi names (an older chi, a raw flock). Read only
    # behind a failed shared try (#held?), so a crash's leftover is never
    # believed.
    # @return [Symbol, nil]
    def holder(id, state_dir:)
      return nil unless held?(id, state_dir: state_dir)

      recorded = File.read(lock_path(id, state_dir), 64).to_s.strip
      Busy::WORDS.keys.compact.find { |kind| kind.to_s == recorded }
    rescue SystemCallError
      nil
    end

    # Whether +kind+ (#holder's) is a transition this chi names that is no
    # continue (a delete, a stop, an archive): its hold names no new link,
    # whatever intent a crashed continue left.
    def other_than_continue?(kind) = !kind.nil? && kind != :continue

    # Whether the current thread holds +id+ exclusively (the registry).
    def holding?(id, state_dir:)
      Session.valid_id?(id) && holds.key?(lock_path(id, state_dir))
    end

    # Take back the lock file #exclusive left in the folder of a session
    # with no session file (a continue's successor never saved, a link
    # deleted while a continue waited for it), and the folder when that
    # leaves it empty: an empty folder holding only the lock is no session.
    # Only when nobody holds it (one try; held, it stays) and this thread
    # doesn't; a saved session's lock is never touched.
    # @return [Boolean] whether the lock file went
    def forget(id, state_dir:)
      return false unless Session.valid_id?(id) && !Session.exist?(id, state_dir: state_dir)

      path = lock_path(id, state_dir)
      return false if holds.key?(path)

      gone = File.open(path, File::RDWR) do |file|
        next false unless file.flock(File::LOCK_EX | File::LOCK_NB)

        File.unlink(path)
        true
      end
      begin
        Dir.rmdir(File.dirname(path))
      rescue Errno::ENOTEMPTY, Errno::EEXIST, Errno::ENOENT
        nil
      end
      gone
    rescue Errno::ENOENT
      false
    end

    def lock_path(id, state_dir) = File.join(Session.session_dir(id, state_dir: state_dir), LOCK)

    # #shared's descriptor: made when missing (its folder too, only for a
    # session whose file is there), else (no write access) the file opened
    # read-only, or nil when there is nothing to open.
    def open_shared(id, path, state_dir)
      begin
        File.open(path, File::RDWR | File::CREAT, 0o600)
      rescue Errno::ENOENT
        return nil unless Session.exist?(id, state_dir: state_dir)

        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::RDWR | File::CREAT, 0o600)
      end
    rescue Errno::ENOENT
      nil
    rescue Errno::EACCES, Errno::EPERM, Errno::EROFS
      begin
        File.open(path, File::RDONLY)
      rescue Errno::ENOENT, Errno::EACCES
        nil
      end
    end

    # Record +kind+ (nil: none) as the holder's in a lock file this thread
    # holds exclusively (#holder reads it). The file is the lock's only
    # content: an older chi only flocks it. Never fatal.
    def mark(file, kind)
      file.truncate(0)
      file.rewind
      file.write(kind.to_s) if kind
      file.flush
    rescue IOError, SystemCallError
      nil
    end

    # This thread's holds.
    def holds
      Thread.current.thread_variable_get(REGISTRY) || Thread.current.thread_variable_set(REGISTRY, {})
    end

    # Lock +file+ exclusively: blocking when +ends_at+ is nil, else tried
    # until that monotonic time. Whether it was taken.
    def lock_until(file, ends_at)
      unless ends_at
        file.flock(File::LOCK_EX)
        return true
      end

      loop do
        return true if file.flock(File::LOCK_EX | File::LOCK_NB)
        return false if monotonic >= ends_at

        sleep RETRY
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    private_class_method :lock_path, :open_shared, :mark, :holds, :lock_until, :monotonic
  end
end
