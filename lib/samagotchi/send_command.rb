# frozen_string_literal: true

require_relative "session"
require_relative "session_manager"
require_relative "context_quote"

module Samagotchi
  # `chi send`: put text into sessions as the user's message, the same as
  # typing it in the attached TUI or the web composer; the other half of
  # `chi note`. Fire and forget: it returns once the message is queued, and
  # the answer shows in whatever is attached. For a script:
  #   pbpaste | chi send -m "is this the same bug?" 3fa2
  class SendCommand
    CLIENT_ID = "cli:send"

    USAGE = <<~TEXT
      Usage: chi send [-m TEXT] (ID|PREFIX)...
        Sends a message to each session, as if typed in it: a turn starts,
        or a running one picks it up. A stopped session's worker starts.
        -m TEXT   the message; stdin, when piped too, goes above it as a
                  quote (context); without -m, stdin is the message
        Only sessions on this machine. Answers show in the attached TUI
        or web page, not here.
        Find ids with: chi sessions list --live [--format tsv]
    TEXT

    # @param argv [Array<String>] the arguments after "send"
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
    end

    # @return [Integer] exit status: 0 all sent, 1 any refused or failed,
    #   2 usage
    def run
      options = parse or return 2
      return 0 if options[:help]

      prompt = compose(utf8(read_stdin), utf8(options[:message]))
      unless prompt
        usage_error("no message: pass -m TEXT or pipe it in")
        return 2
      end
      begin
        prompt = SessionManager.checked_text(prompt, noun: "message")
      rescue SessionManager::NoteRejected => e
        @stderr.puts("chi send: #{e.message}")
        return 1
      end

      found = options[:ids].uniq.map { |given| resolve(given) }
      sent = found.compact.uniq.map { |id| deliver(id, prompt) }
      found.all? && sent.all? ? 0 : 1
    end

    private

    def parse
      options = { ids: [] }
      until @argv.empty?
        arg = @argv.shift
        case arg
        when "-h", "--help", "help"
          @stdout.puts(USAGE)
          return { help: true }
        when "-m", "--message"
          options[:message] = @argv.shift or return usage_error("#{arg} needs a value")
        when /\A--message=(.*)\z/m then options[:message] = Regexp.last_match(1)
        # Starting a turn in every live session at once is too easy to do
        # by accident.
        when "--all" then return usage_error("there is no --all: name the sessions")
        when /\A-/ then return usage_error("unknown option #{arg}")
        else options[:ids] << arg
        end
      end
      return usage_error("give session ids") if options[:ids].empty?

      options
    end

    # With both, stdin is the context quoted above the message; with one,
    # it goes in as is. nil when both are blank.
    def compose(context, message)
      context = nil if context.to_s.strip.empty?
      message = nil if message.to_s.strip.empty?
      return message || context unless context && message

      "#{ContextQuote.block(context)}#{message}"
    end

    # Only a pipe or a file is read. A terminal means nobody piped anything
    # in, and a socket a launcher or an agent's shell passes down may never
    # close: with -m, waiting on either would hang a script. (A pipe the
    # caller never closes still hangs, as it would for cat.)
    def read_stdin
      return nil if @stdin.respond_to?(:tty?) && @stdin.tty?
      if @stdin.respond_to?(:stat)
        stat = @stdin.stat
        return nil unless stat.pipe? || stat.file?
      end

      @stdin.read
    end

    def resolve(given)
      id = Session.resolve_id(given, state_dir: @state_dir)
      Session.load(id, state_dir: @state_dir)
      id
    rescue ArgumentError => e
      message = e.is_a?(Session::AmbiguousId) ? e.message : "no session #{given}"
      @stderr.puts("chi send: #{message}")
      nil
    end

    # @return [Boolean] whether the message was queued
    def deliver(id, prompt)
      short = id[0, 8]
      owner = SessionManager.session_owner(id, state_dir: @state_dir)
      running = owner && Session.load(id, state_dir: @state_dir).status == Session::STATUS_RUNNING
      result = SessionManager.deliver_turn(id, prompt: prompt, client_id: CLIENT_ID, state_dir: @state_dir)
      unless result[:status] == :accepted
        @stdout.puts("#{short}  failed: #{result.dig(:ack, "detail") || "could not queue it"}")
        return false
      end

      note = if owner.nil? then " (started its worker)"
             elsif running then " (the running turn picks it up)"
             end
      @stdout.puts("#{short}  sent#{note}")
      true
    rescue SessionManager::OwnedByTUI
      @stdout.puts("#{short}  refused: it is open in a chi REPL; messages need attached mode")
      false
    rescue StandardError => e
      @stdout.puts("#{short}  failed: #{e.message}")
      false
    end

    # The text as UTF-8 whatever the locale says: with no LANG/LC_* (an app
    # started from Finder, launchd) stdin reads as US-ASCII and ARGV as
    # binary. Invalid bytes become U+FFFD rather than an error.
    def utf8(text)
      text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
    end

    def usage_error(message)
      @stderr.puts("chi send: #{message}")
      @stderr.puts(USAGE)
      nil
    end
  end
end
