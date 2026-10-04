# frozen_string_literal: true

require "fileutils"

module Samagotchi
  # The debug log file (Log's writer). One #write per record, so records
  # from concurrent processes appending to the same file (O_APPEND) don't
  # interleave. Failures never break the caller: an IO error (a full disk,
  # a lost permission) pauses writing for RETRY_SECONDS, then it tries again.
  #
  # Rotation: a file over MAX_BYTES becomes <file>.1 (one kept), whichever
  # process notices first. It takes <file>.lock without waiting (busy: the
  # next write checks again) and looks again under it, so two processes
  # never both rotate. Every write stats the path: a writer whose file was
  # rotated away (another inode) reopens the new one.
  class DebugLog
    RETRY_SECONDS = 60
    MAX_BYTES = 5 * 1024 * 1024

    attr_reader :path

    def initialize(path:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, max_bytes: MAX_BYTES)
      @path = path.nil? || path.to_s.strip.empty? ? nil : path.to_s
      @clock = clock
      @max_bytes = max_bytes
      @io = nil
      @ino = nil
      @paused_until = nil
      @mutex = Mutex.new
    end

    def enabled?
      !@path.nil?
    end

    # @param record [String] one formatted record, newline-terminated
    # @return [Boolean] whether it was written
    def write(record)
      return false unless @path

      @mutex.synchronize do
        return false if @paused_until && @clock.call < @paused_until

        @paused_until = nil
        begin
          ensure_io
          follow_rotation
          ensure_io.write(record)
          true
        rescue StandardError
          pause
          false
        end
      end
    end

    def close
      @mutex.synchronize { close_io }
    end

    private

    def ensure_io
      return @io if @io

      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir) unless dir.empty?
      @io = File.open(@path, File::WRONLY | File::APPEND | File::CREAT)
      @io.sync = true
      @ino = @io.stat.ino
      @io
    end

    # Reopen when the path is another file now (rotated by someone else, or
    # deleted); rotate when it grew over the cap. Regular files only: a
    # FIFO or /dev/stderr is left alone.
    def follow_rotation
      stat = File.stat(@path)
      return close_io unless stat.ino == @ino
      return unless stat.file? && stat.size >= @max_bytes

      rotate
    rescue Errno::ENOENT
      close_io
    end

    def rotate
      File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        next unless lock.flock(File::LOCK_EX | File::LOCK_NB)

        stat = File.stat(@path)
        File.rename(@path, "#{@path}.1") if stat.ino == @ino && stat.size >= @max_bytes
        close_io
      end
    end

    def pause
      @paused_until = @clock.call + RETRY_SECONDS
      close_io
    end

    def close_io
      @io&.close
    rescue StandardError
      nil
    ensure
      @io = nil
    end
  end
end
