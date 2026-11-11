# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Samagotchi
  # One append-only JSONL file beside a session (FILE in its folder, 0600): a
  # line is a Hash stamped with its time, and a broken line reads as none. The
  # generic half of a side reader's state (ObjectivesCheck, ObjectivesTrack):
  # what a line means, and which is the latest, stays with its reader.
  class JsonlStore
    attr_reader :file

    # @param file [String] the file's name in a session's folder
    def initialize(file)
      @file = file
    end

    # Append one line, +now+ as its "at".
    def write(session_dir, now: Time.now, **fields)
      FileUtils.mkdir_p(session_dir)
      File.open(File.join(session_dir, file), File::WRONLY | File::APPEND | File::CREAT, 0o600) do |io|
        io.write("#{JSON.generate({ at: now.utc.iso8601(3), **fields })}\n")
      end
    end

    # Every line that reads as a Hash, oldest first; none with no file.
    # @return [Array<Hash>]
    def lines(session_dir)
      File.readlines(File.join(session_dir, file), chomp: true).filter_map do |raw|
        line = JSON.parse(raw)
        line if line.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError
      []
    end

    # A line's "at"; the epoch for one that has none or a bad one.
    def self.time_of(line)
      Time.iso8601(line["at"].to_s)
    rescue ArgumentError
      Time.at(0)
    end

    # Whether the worker that wrote a running line still lives: a line with no
    # pid is taken as alive (its time limit still frees it).
    def self.worker_alive?(pid)
      return true unless pid.is_a?(Integer)

      Process.kill(0, pid)
      true
    rescue Errno::EPERM
      true
    rescue Errno::ESRCH
      false
    end
  end
end
