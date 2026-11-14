# frozen_string_literal: true

require_relative "session"
require_relative "session_manager"
require_relative "cli/command"
require_relative "cli/flags"
require_relative "session_access/local"

module Samagotchi
  # `chi sessions delete`: remove sessions for good (SessionManager.delete_session),
  # one line per id. A live worker's session is refused unless --force stops
  # the worker first; a one-turn chi run's never is.
  class SessionDeleteCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi sessions delete [--force] [--chain] (ID|PREFIX)...
        Deletes each session: its history, notes, images and queued input.
        This can't be undone. Deleting a chain's newest link undoes its
        continue: the previous link comes back to the lists (not started),
        with the delegates and notes that had moved on.
        -f, --force   stop a session's running worker first (without it,
                      a live session is refused); a session in a one-turn
                      chi run (chi --non-interactive) is always refused
        --chain       delete every link of the session's chain, with their
                      delegates; running delegates are left running
    TEXT
    PREVIEW_LIMIT = 60
    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS) do |f|
      f.switch "-f", "--force"
      f.switch "--chain"
    end

    # @param argv [Array<String>] the arguments after "sessions delete"
    # @param access [SessionAccess::Local, nil] where the sessions are;
    #   default this machine's, in +state_dir+
    def initialize(argv, stdout: $stdout, stderr: $stderr, state_dir: nil, access: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
      @access = access || SessionAccess::Local.new(state_dir: @state_dir)
    end

    # @return [Integer] exit status: 0 all deleted, 1 any refused or
    #   unknown, 2 usage
    def run
      options = parse
      return options if options.is_a?(Integer)

      gone = options[:ids].uniq.map do |given|
        options[:chain] ? delete_chain(given, force: options[:force]) : delete(given, force: options[:force])
      end
      gone.all? ? 0 : 1
    end

    private

    def command_name = "chi sessions delete"

    # @return [Hash, Integer] the options, or the exit status after the
    #   help or a usage error
    def parse
      parsed = parse_flags(FLAGS, @argv, force: false, chain: false)
      return parsed if parsed.is_a?(Integer)
      return usage_error("give session ids") if parsed.args.empty?

      parsed.options.merge(ids: parsed.args)
    end

    # @return [Boolean] whether the session is gone
    def delete(given, force:)
      id = @access.resolve_id(given)
      short = id[0, 8]
      preview = preview_of(id)
      result = @access.delete(id, force: force)
      @stdout.puts(["#{short}  deleted#{" (stopped its worker)" if result[:stopped]}#{revived(result)}#{delegates(result, id)}",
                    preview].compact.join("  "))
      true
    rescue SessionManager::OwnedByTUI, SessionManager::DeleteRefused => e
      refused(e.session_id && e.session_id != id ? e.session_id[0, 8] : short, e)
    rescue ArgumentError => e
      error_line("chi sessions delete: #{e.message}")
      false
    rescue SystemCallError => e
      @stdout.puts("#{short}  failed: #{e.message}")
      false
    end

    # "; the previous link 1a2b3c4d is back in the lists" (D1), with the
    # delegates that went back to it.
    def revived(result)
      back = Array(result[:unarchived]).first
      return "" unless back

      moved = Array(result[:moved_back]).size
      "; the previous link #{back[0, 8]} is back in the lists" \
        "#{" with #{moved} delegate#{"s" unless moved == 1}" if moved.positive?}"
    end

    # "; 2 delegates deleted with it; 1 left running: 9d0e1f2a" (D7, a
    # chained link's own delegates).
    def delegates(result, id)
      gone = Array(result[:deleted]).size - (Array(result[:deleted]).include?(id) ? 1 : 0)
      running = Array(result[:left_running])
      words = []
      words << "#{gone} delegate#{"s" unless gone == 1} deleted with it" if gone.positive?
      words << "#{running.size} left running: #{running.map { |sid| sid[0, 8] }.join(", ")}" unless running.empty?
      words.empty? ? "" : "; #{words.join("; ")}"
    end

    # --chain: one line per link deleted, then a summary.
    # @return [Boolean] whether every link went
    def delete_chain(given, force:)
      id = @access.resolve_id(given)
      result = @access.delete_chain(id, force: force)
      result[:deleted].each { |sid| @stdout.puts("#{sid[0, 8]}  deleted#{" (stopped its worker)" if result[:stopped].include?(sid)}") }
      @stdout.puts(chain_summary(result))
      result[:left].empty?
    rescue SessionManager::OwnedByTUI, SessionManager::DeleteRefused => e
      refused((e.session_id || id).to_s[0, 8], e)
    rescue ArgumentError => e
      error_line("chi sessions delete: #{e.message}")
      false
    end

    def chain_summary(result)
      parts = ["#{result[:deleted].size} deleted"]
      parts << "#{result[:left].size} links kept: #{result[:refusal]}" unless result[:left].empty?
      parts << "back in the lists: #{result[:unarchived].map { |sid| sid[0, 8] }.join(", ")}" unless result[:unarchived].empty?
      unless result[:left_running].empty?
        parts << "left running, without a parent: #{result[:left_running].map { |sid| sid[0, 8] }.join(", ")}"
      end
      parts << "earlier links, cut off by a deleted link, are kept (archived)" if result[:cut_off]
      "chain: #{parts.join("; ")}"
    end

    # @return [false]
    def refused(short, error)
      line = case error
             when SessionManager::OwnedByTUI then "it is #{OwnerLock::TUI_BUSY}; let it finish first"
             else
               case error.reason
               when :still_stopping then "its worker is still shutting down; try again in a moment"
               when :worker_running then "its worker is running (--force stops it first)"
               else error.message
               end
             end
      @stdout.puts("#{short}  refused: #{line}")
      false
    end

    def preview_of(id)
      text = @access.show(id).display_title.gsub(/\s+/, " ").strip
      return nil if text.empty?

      text.length > PREVIEW_LIMIT ? "#{text[0, PREVIEW_LIMIT - 1]}…" : text
    rescue ArgumentError, JSON::ParserError
      nil
    end
  end
end
