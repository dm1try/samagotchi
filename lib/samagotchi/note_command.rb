# frozen_string_literal: true

require_relative "session"
require_relative "session_manager"

module Samagotchi
  # `chi note`: push text into sessions as a context note (background the
  # model sees on its next turn), never as a prompt; nothing wakes. For a
  # script, e.g. an Automator action:
  #   pbpaste | chi note --source slack $(chi sessions list --live --format tsv | cut -f1)
  class NoteCommand
    USAGE = <<~TEXT
      Usage: chi note [--source NAME] [-m TEXT] (ID|PREFIX)... | --all
        Adds TEXT (or stdin) to each session as a context note: background
        the model sees on its next turn, not a prompt. It starts no turn.
        --source NAME  where it came from, shown to the model (default: cli)
        -m TEXT        the note; without it, stdin is read
        --all          every session a worker runs now
        Find ids with: chi sessions list --live [--format tsv]
    TEXT

    # @param argv [Array<String>] the arguments after "note"
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
    end

    # @return [Integer] exit status: 0 all queued, 1 any refused or failed,
    #   2 usage
    def run
      options = parse or return 2
      return 0 if options[:help]

      text = options[:text] || read_stdin
      unless text
        usage_error("no note text: pass -m TEXT or pipe it in")
        return 2
      end
      begin
        text = SessionManager.checked_note_text(text)
      rescue SessionManager::NoteRejected => e
        @stderr.puts("chi note: #{e.message}")
        return 1
      end

      ids, all_found = targets(options)
      delivered = ids.map { |id| deliver(id, text, options[:source]) }
      all_found && !ids.empty? && delivered.all? ? 0 : 1
    end

    private

    def parse
      options = { source: "cli", ids: [] }
      until @argv.empty?
        arg = @argv.shift
        case arg
        when "-h", "--help", "help"
          @stdout.puts(USAGE)
          return { help: true }
        when "--all" then options[:all] = true
        when "--source", "-m", "--message"
          value = @argv.shift or return usage_error("#{arg} needs a value")
          options[arg == "--source" ? :source : :text] = value
        when /\A--source=(.*)\z/m then options[:source] = Regexp.last_match(1)
        when /\A--message=(.*)\z/m then options[:text] = Regexp.last_match(1)
        when /\A-/ then return usage_error("unknown option #{arg}")
        else options[:ids] << arg
        end
      end
      return usage_error("give session ids or --all") if options[:ids].empty? && !options[:all]
      return usage_error("--all takes no ids") if options[:all] && options[:ids].any?

      options
    end

    # A terminal on stdin means nobody piped a note in: waiting there
    # would just hang a script.
    def read_stdin
      return nil if @stdin.respond_to?(:tty?) && @stdin.tty?

      @stdin.read
    end

    # @return [Array(Array<String>, Boolean)] full ids, and whether every
    #   given id was found
    def targets(options)
      if options[:all]
        ids = SessionManager.session_summaries(live: true, include_tests: false, state_dir: @state_dir).map { |s| s[:id] }
        @stderr.puts("chi note: no live sessions (chi sessions list --live)") if ids.empty?
        return [ids, true]
      end

      found = options[:ids].uniq.map { |given| resolve(given) }
      [found.compact.uniq, found.all?]
    end

    def resolve(given)
      id = Session.resolve_id(given, state_dir: @state_dir)
      Session.load(id, state_dir: @state_dir)
      id
    rescue ArgumentError => e
      message = e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"
      @stderr.puts("chi note: #{message}")
      nil
    end

    # @return [Boolean] whether the note was queued
    def deliver(id, text, source)
      short = id[0, 8]
      owner = SessionManager.session_owner(id, state_dir: @state_dir)
      if owner && owner["kind"] == "tui"
        @stdout.puts("#{short}  refused: it is open in a chi REPL; notes need attached mode")
        return false
      end

      path = SessionManager.write_note(id, text: text, source: source, state_dir: @state_dir)
      if owner
        @stdout.puts("#{short}  queued: its worker adds it within a few seconds")
      else
        queued = SessionManager.find_new_note_files(File.dirname(File.dirname(path))).size
        @stdout.puts("#{short}  waits for the session's next start (#{queued} #{queued == 1 ? "note" : "notes"} queued)")
      end
      true
    end

    def usage_error(message)
      @stderr.puts("chi note: #{message}")
      @stderr.puts(USAGE)
      nil
    end
  end
end
