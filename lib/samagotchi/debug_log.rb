# frozen_string_literal: true

require "time"
require "fileutils"

module Samagotchi
  # Append-only debug log sink used for internal kernel events.
  # Failures are intentionally swallowed so logging never breaks agent execution.
  class DebugLog
    def initialize(path:)
      @path = path
      @io = nil
      @disabled = path.nil? || path.to_s.strip.empty?
    end

    def write(message)
      return if @disabled

      io = ensure_io
      return if io.nil?

      io.puts("[#{Time.now.utc.iso8601}] [verbose] #{message}")
      io.flush
    rescue StandardError
      @disabled = true
      close
    end

    def close
      @io&.close
      @io = nil
    rescue StandardError
      nil
    end

    private

    def ensure_io
      return @io if @io

      dir = File.dirname(@path)
      FileUtils.mkdir_p(dir) unless dir.nil? || dir.empty?
      @io = File.open(@path, "a")
      @io.sync = true
      @io
    rescue StandardError
      @disabled = true
      nil
    end
  end
end
