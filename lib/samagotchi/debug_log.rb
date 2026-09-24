# frozen_string_literal: true

require "fileutils"

module Samagotchi
  # The debug log file (Log's writer). One #write per record, so records
  # from concurrent processes appending to the same file (O_APPEND) don't
  # interleave. Failures never break the caller: an IO error (a full disk,
  # a lost permission) pauses writing for RETRY_SECONDS, then it tries again.
  class DebugLog
    RETRY_SECONDS = 60

    attr_reader :path

    def initialize(path:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @path = path.nil? || path.to_s.strip.empty? ? nil : path.to_s
      @clock = clock
      @io = nil
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
      @io
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
