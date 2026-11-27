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

    # An exclusive hold not taken by its deadline. It owns its refusal text.
    class Busy < StandardError
      WORDS = { continue: "being continued", delete: "being deleted", nil => "busy with another change" }.freeze

      attr_reader :session_id, :kind

      def initialize(session_id, kind: nil)
        @session_id = session_id
        @kind = kind
        super("session #{session_id.to_s[0, 8]} is #{WORDS.fetch(kind, WORDS[nil])}; try again in a moment")
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
        lock_until(file, ends_at) or raise Busy.new(id, kind: kind)
        holds[path] = true
      end
      yield Token.new(ids: ids, kind: kind)
    ensure
      # Only ids this call took: none of them was held before it.
      taken&.reverse_each do |path, file|
        holds.delete(path)
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
        begin
          yield Token.new(ids: [id], kind: kind)
        ensure
          holds.delete(path)
        end
      end
    end

    # The block under a shared hold of +id+'s lock, so no transition of it
    # starts until the block returns; its argument is false when another
    # holds it exclusively now (not waited for: nothing is held then) or
    # +id+ isn't a session id, true when this thread holds it. The folder
    # and lock file are created when missing.
    # @yieldparam held [Boolean]
    # @return the block's value
    def shared(id, state_dir:)
      return yield(false) unless Session.valid_id?(id)

      path = lock_path(id, state_dir)
      return yield(true) if holds.key?(path)

      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o600) do |file|
        yield(file.flock(File::LOCK_SH | File::LOCK_NB) ? true : false)
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

    private_class_method :lock_path, :holds, :lock_until, :monotonic
  end
end
