# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "atomic_file"
require_relative "config"
require_relative "paths"
require_relative "session_commands"

module Samagotchi
  # The prompts typed at a chi prompt, kept for ↑ across launches: one
  # global file (config history.file, else
  # $XDG_STATE_HOME/samagotchi/history.json), a JSON array oldest first. An
  # older file with one prompt per line still reads. The TUI and the web
  # server both append, so appends hold <file>.lock and replace the file
  # atomically (mode 0600: the web serves it to LAN token holders).
  module PromptHistory
    FILE = "history.json"
    STATE_DIR = "samagotchi"
    LIMIT = 100

    module_function

    # @return [String] the history file
    def path
      explicit = Config.get("history.file").to_s.strip
      return explicit unless explicit.empty?

      File.join(Paths.state_home, STATE_DIR, FILE)
    end

    # @return [Array<String>] the saved entries, oldest first; [] when the
    #   file is missing or unreadable
    def entries
      file = path
      return [] unless File.file?(file)

      raw = File.read(file)
      normalize(JSON.parse(raw))
    rescue JSON::ParserError
      normalize(raw.to_s.lines.map(&:chomp))
    rescue StandardError
      []
    end

    # Add +line+ as the newest entry, keeping the last LIMIT. The re-read
    # happens under the lock, so two writers never drop each other's line.
    # The rename replaces a symlinked history.file with a regular file.
    # @param line [String]
    def append(line)
      file = path
      FileUtils.mkdir_p(File.dirname(file))
      File.open("#{file}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        list = entries << line
        AtomicFile.write(file, JSON.pretty_generate(list.last(LIMIT)) + "\n", perm: 0o600)
      end
    end

    # A `!command` worth recalling; `!rollback` isn't one.
    def shell_line?(line)
      line.to_s.start_with?(SessionCommands::SHELL_BANG_PREFIX) && line.to_s.strip != SessionCommands::ROLLBACK_COMMAND
    end

    def normalize(list)
      Array(list).map { |entry| entry.to_s.gsub(/\r\n?/, "\n").strip }.reject(&:empty?)
    end
  end
end
