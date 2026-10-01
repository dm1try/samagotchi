# frozen_string_literal: true

require_relative "session"
require_relative "session_manager"
require_relative "cli/command"
require_relative "cli/flags"

module Samagotchi
  # `chi sessions delete`: remove sessions for good (SessionManager.delete_session),
  # one line per id. A live worker's session is refused unless --force stops
  # the worker first; a chi REPL's never is.
  class SessionDeleteCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi sessions delete [--force] (ID|PREFIX)...
        Deletes each session: its history, notes, images and queued input.
        This can't be undone.
        -f, --force   stop a session's running worker first (without it,
                      a live session is refused); a session open in a
                      chi REPL is always refused
    TEXT
    PREVIEW_LIMIT = 60
    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS) { |f| f.switch "-f", "--force" }

    # @param argv [Array<String>] the arguments after "sessions delete"
    def initialize(argv, stdout: $stdout, stderr: $stderr, state_dir: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
    end

    # @return [Integer] exit status: 0 all deleted, 1 any refused or
    #   unknown, 2 usage
    def run
      options = parse
      return options if options.is_a?(Integer)

      options[:ids].uniq.map { |given| delete(given, force: options[:force]) }.all? ? 0 : 1
    end

    private

    def command_name = "chi sessions delete"

    # @return [Hash, Integer] the options, or the exit status after the
    #   help or a usage error
    def parse
      parsed = parse_flags(FLAGS, @argv, force: false)
      return parsed if parsed.is_a?(Integer)
      return usage_error("give session ids") if parsed.args.empty?

      parsed.options.merge(ids: parsed.args)
    end

    # @return [Boolean] whether the session is gone
    def delete(given, force:)
      id = Session.resolve_id(given, state_dir: @state_dir)
      short = id[0, 8]
      preview = preview_of(id)
      result = SessionManager.delete_session(id, state_dir: @state_dir, stop: force)
      @stdout.puts(["#{short}  deleted#{" (stopped its worker)" if result[:stopped]}", preview].compact.join("  "))
      true
    rescue SessionManager::OwnedByTUI
      @stdout.puts("#{short}  refused: it is open in a chi REPL; close it there first")
      false
    rescue SessionManager::DeleteRefused => e
      line = if e.reason == :still_stopping then "its worker is still shutting down; try again in a moment"
             else "its worker is running (--force stops it first)"
             end
      @stdout.puts("#{short}  refused: #{line}")
      false
    rescue ArgumentError => e
      error_line("chi sessions delete: #{e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"}")
      false
    rescue SystemCallError => e
      @stdout.puts("#{short}  failed: #{e.message}")
      false
    end

    def preview_of(id)
      text = Session.load(id, state_dir: @state_dir).first_preview.to_s.gsub(/\s+/, " ").strip
      return nil if text.empty?

      text.length > PREVIEW_LIMIT ? "#{text[0, PREVIEW_LIMIT - 1]}…" : text
    rescue ArgumentError, JSON::ParserError
      nil
    end
  end
end
