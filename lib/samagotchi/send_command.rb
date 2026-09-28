# frozen_string_literal: true

require_relative "session"
require_relative "session_manager"
require_relative "context_quote"
require_relative "reply_wait"

module Samagotchi
  # `chi send`: put text into sessions as the user's message, the same as
  # typing it in the attached TUI or the web composer; the other half of
  # `chi note`. Fire and forget: it returns once the message is queued, and
  # the answer shows in whatever is attached. For a script:
  #   pbpaste | chi send -m "is this the same bug?" 3fa2
  # --new starts a session instead, and --wait blocks for the reply and
  # prints it: an agent's one-shot the user can watch in the web.
  class SendCommand
    CLIENT_ID = "cli:send"
    POLL_INTERVAL = ReplyWait::POLL_INTERVAL
    # No live worker this long while waiting: it died before it could mark
    # the session (a worker takes well under a second to start).
    WORKER_GONE_AFTER = 5

    USAGE = <<~TEXT
      Usage: chi send [-m TEXT] (ID|PREFIX)...
             chi send --new [--dir DIR] [--model M] [-m TEXT]
             chi send --wait [--timeout S] [-m TEXT] (--new | ID)
        Sends a message to each session, as if typed in it: a turn starts,
        or a running one picks it up. A stopped session's worker starts.
        -m TEXT     the message; stdin, when piped too, goes above it as a
                    quote (context); without -m, stdin is the message
        --new       start a new session with the message instead, as the
                    web does, and print its id
        --dir DIR   (--new) its folder, the project it belongs to; default
                    the current one
        --model M   (--new) its model; default the configured one
        --wait      wait for the answer and print it (one session); the
                    other lines go to stderr. Exit 3: it waits for an
                    answer from you (chi --attach ID or the web)
        --timeout S (--wait) give up after S seconds; default no limit
        Only sessions on this machine. Answers show in the attached TUI
        or web page, not here.
        Find ids with: chi sessions list --live [--scope=all] [--format tsv]
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
    #   2 usage; with --wait 0 answered, 3 waiting for an answer, 130
    #   Ctrl-C (the turn goes on)
    def run
      options = parse or return 2
      return 0 if options[:help]

      # With --wait stdout is the answer alone.
      @info = options[:wait] ? @stderr : @stdout
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

      return run_new(prompt, options) if options[:new]
      return run_wait(prompt, options) if options[:wait]

      # One id at a time, so each line follows the order of the ids given.
      seen = {}
      results = options[:ids].uniq.map do |given|
        id = resolve(given)
        next false unless id
        next true if seen[id]

        seen[id] = true
        deliver(id, prompt)
      end
      results.all? ? 0 : 1
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
        when "--new" then options[:new] = true
        when "--dir", "--model"
          options[arg.delete_prefix("--").to_sym] = @argv.shift or return usage_error("#{arg} needs a value")
        when /\A--(dir|model)=(.*)\z/m then options[Regexp.last_match(1).to_sym] = Regexp.last_match(2)
        when "--wait" then options[:wait] = true
        when "--timeout" then options[:timeout] = @argv.shift or return usage_error("#{arg} needs a value")
        when /\A--timeout=(.*)\z/ then options[:timeout] = Regexp.last_match(1)
        # Starting a turn in every live session at once is too easy to do
        # by accident.
        when "--all" then return usage_error("there is no --all: name the sessions")
        when /\A-/ then return usage_error("unknown option #{arg}")
        else options[:ids] << arg
        end
      end
      if options[:timeout]
        return usage_error("--timeout needs --wait") unless options[:wait]

        options[:timeout] = Float(options[:timeout], exception: false)
        return usage_error("--timeout takes seconds") unless options[:timeout]&.positive?
      end
      return usage_error("--wait takes one session") if options[:wait] && options[:ids].uniq.size > 1
      return new_options(options) if options[:new]
      %i[dir model].each { |key| return usage_error("--#{key} needs --new") if options[key] }
      return usage_error("give session ids") if options[:ids].empty?

      options
    end

    def new_options(options)
      return usage_error("--new takes no session ids: it starts one session") unless options[:ids].empty?

      if options[:dir]
        options[:dir] = File.expand_path(options[:dir])
        return usage_error("no folder #{options[:dir]}") unless File.directory?(options[:dir])
      end
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
      error_line("chi send: #{message}")
      nil
    end

    # A worker session like the web start page's: saved as running with the
    # message before its worker spawns, so lists and the web show it at
    # once. The full id, so a script can pass it on. The model name isn't
    # checked here (nor in the web): a wrong one fails in the worker.
    # @return [Integer] the exit status
    def run_new(prompt, options)
      begin
        session = SessionManager.spawn_session(prompt: prompt, working_directory: options[:dir],
                                               model_name: options[:model], state_dir: @state_dir)
      rescue StandardError => e
        error_line("chi send: could not start a session: #{e.message}")
        return 1
      end
      @info.puts("#{session.id}  started")
      return 0 unless options[:wait]

      wait_for_reply(session.id, cursor: nil, baseline: { messages: session.messages.size, question_id: nil },
                                 timeout: options[:timeout])
    end

    # One existing session, then its next reply. The cursor and baseline
    # are taken before the message goes in, so neither an older reply nor a
    # turn that ends before the first look is mistaken for the answer. A
    # running turn is refused: a message that misses it runs next, and the
    # running one's reply would come back as the answer.
    # @return [Integer] the exit status
    def run_wait(prompt, options)
      id = resolve(options[:ids].first) or return 1
      session = Session.load(id, state_dir: @state_dir)
      if session.status == Session::STATUS_RUNNING && SessionManager.session_owner(id, state_dir: @state_dir)
        error_line("#{id[0, 8]}  busy: a turn is running; wait or attach")
        return 1
      end

      cursor = ReplyWait.newest_reply(id, state_dir: @state_dir)
      baseline = { messages: session.messages.size, question_id: session.pending_question&.dig(:id) }
      return 1 unless deliver(id, prompt)

      wait_for_reply(id, cursor: cursor, baseline: baseline, timeout: options[:timeout])
    end

    # @return [Integer] the exit status
    def wait_for_reply(id, cursor:, baseline:, timeout:)
      result = ReplyWait.call(id, state_dir: @state_dir, cursor: cursor, timeout: timeout, baseline: baseline,
                                  owner_grace: WORKER_GONE_AFTER, poll_interval: POLL_INTERVAL)
      return reply(result.text) if result.status == :done

      attach = "chi --attach #{id}"
      line, status = case result.status
                     when :waiting_for_answer
                       question = result.question[:question].to_s.strip.lines.first.to_s.strip
                       ["waiting for an answer: #{question}; open it: #{attach} or the web", 3]
                     when :no_reply then ["the turn ended without a reply (canceled, failed or empty); #{attach} shows it", 1]
                     when :error then ["the worker failed: #{result.text}; #{attach} shows what happened", 1]
                     when :worker_gone then ["the worker is gone; #{attach} shows what happened", 1]
                     when :stopped then ["the session was stopped (chi sessions stop)", 1]
                     else ["still running after #{format("%g", timeout)} s: #{attach}", 1]
                     end
      error_line("chi send: #{line}")
      status
    rescue Interrupt
      error_line("chi send: still running: chi --attach #{id}")
      130
    rescue ArgumentError
      error_line("chi send: the session is gone (deleted while waiting)")
      1
    end

    def reply(text)
      @stdout.puts(utf8(text))
      @stdout.flush
      0
    end

    # @return [Boolean] whether the message was queued
    def deliver(id, prompt)
      short = id[0, 8]
      owner = SessionManager.session_owner(id, state_dir: @state_dir)
      running = owner && Session.load(id, state_dir: @state_dir).status == Session::STATUS_RUNNING
      result = SessionManager.deliver_turn(id, prompt: prompt, client_id: CLIENT_ID, state_dir: @state_dir)
      unless result[:status] == :accepted
        @info.puts("#{short}  failed: #{result.dig(:ack, "detail") || "could not queue it"}")
        return false
      end

      note = if owner.nil? then " (started its worker)"
             elsif running then " (the running turn picks it up)"
             end
      @info.puts("#{short}  sent#{note}")
      true
    rescue SessionManager::OwnedByTUI
      @info.puts("#{short}  refused: it is open in a chi REPL; messages need attached mode")
      false
    rescue StandardError => e
      @info.puts("#{short}  failed: #{e.message}")
      false
    end

    # The text as UTF-8 whatever the locale says: with no LANG/LC_* (an app
    # started from Finder, launchd) stdin reads as US-ASCII and ARGV as
    # binary. Invalid bytes become U+FFFD rather than an error.
    def utf8(text)
      text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
    end

    # stderr isn't buffered, stdout is when it's a pipe: flush the lines
    # already printed, so the output keeps the order of the ids given.
    def error_line(text)
      @stdout.flush
      @stderr.puts(text)
    end

    def usage_error(message)
      error_line("chi send: #{message}")
      @stderr.puts(USAGE)
      nil
    end
  end
end
