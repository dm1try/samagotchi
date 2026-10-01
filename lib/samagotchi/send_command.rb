# frozen_string_literal: true

require_relative "session"
require_relative "session_inbox"
require_relative "session_manager"
require_relative "context_quote"
require_relative "reply_wait"
require_relative "image_store"
require_relative "host_registry"
require_relative "model_profile"
require_relative "vision_support"
require_relative "cli/command"
require_relative "cli/flags"

module Samagotchi
  # `chi send`: put text into sessions as the user's message, the same as
  # typing it in the attached TUI or the web composer; the other half of
  # `chi note`. Fire and forget: it returns once the message is queued, and
  # the answer shows in whatever is attached. For a script:
  #   pbpaste | chi send -m "is this the same bug?" 3fa2
  # --new starts a session instead, and --wait blocks for the reply and
  # prints it: an agent's one-shot the user can watch in the web.
  class SendCommand
    include CLI::Command

    CLIENT_ID = "cli:send"
    POLL_INTERVAL = ReplyWait::POLL_INTERVAL
    # No live worker this long while waiting: it died before it could mark
    # the session (a worker takes well under a second to start).
    WORKER_GONE_AFTER = 5
    # The cap on one turn's images the Bridge checks.
    MAX_IMAGES = ImageStore::MAX_TURN_REFS

    USAGE = <<~TEXT
      Usage: chi send [-m TEXT] [--image PATH]... (ID|PREFIX)...
             chi send --new [--dir DIR] [--model M] [-m TEXT] [--image PATH]...
             chi send --wait [--timeout S] [-m TEXT] [--image PATH]... (--new | ID)
             chi send --wait [--timeout S] ID
        Sends a message to each session, as if typed in it: a turn starts,
        or a running one picks it up. A stopped session's worker starts.
        -m TEXT     the message; stdin, when piped too, goes above it as a
                    quote (context); without -m, stdin is the message
        --image PATH
                    an image sent with the message (png, jpeg, gif, webp;
                    others converted, large ones downscaled); repeat for
                    more, up to 20. Needs text too (-m or stdin) and a
                    model that sees images: a session whose model is
                    known not to is refused before anything is sent
        --new       start a new session with the message instead, as the
                    web does, and print its id
        --dir DIR   (--new) its folder, the project it belongs to; default
                    the current one
        --model M   (--new) its model; default the configured one
        --wait      wait for the answer and print it (one session); the
                    other lines go to stderr. Exit 3: it waits for an
                    answer from you (chi --attach ID or the web). With
                    no message (no -m, nothing piped) nothing is sent: it
                    waits for the session's next reply, a running turn's
                    too (after exit 3 or 130, wait again this way)
        --timeout S (--wait) give up after S seconds; default no limit
        Only sessions on this machine. Answers show in the attached TUI
        or web page, not here.
        Find ids with: chi sessions list --live [--scope=all] [--format tsv]
    TEXT

    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS) do |f|
      f.value "-m", "--message"
      f.switch "--new"
      f.value "--dir"
      f.value "--model"
      f.value "--image", key: :images, repeat: true
      f.switch "--wait"
      f.value "--timeout"
      # Starting a turn in every live session at once is too easy to do
      # by accident.
      f.refuse "--all", "there is no --all: name the sessions"
    end

    # Whether +model_name+ (a session's; blank: the configured default)
    # takes images, decided as its worker decides before a turn with images
    # (Engine#turn_vision: VisionSupport, with models.<name>.vision under
    # the name as given (maybe an alias), the alias's target, the part
    # after a host prefix and the bare name). A native
    # host whose /props doesn't answer is unknown here, not a no: the
    # worker asks again when the turn runs.
    # @param typed [String, nil] the name the model was typed as (a session's model_typed)
    # @return [VisionSupport::Answer] value nil when unknown
    def self.vision_answer(model_name, registry: nil, typed: nil)
      registry ||= HostRegistry.new
      name = ModelProfile.required_model_name(model_name)
      target = registry.resolve(name)
      names = registry.lookup_names(typed.to_s.strip.empty? ? name : typed, resolved: name, target: target)
      entry = target.entry
      return VisionSupport.for(target, adapter: registry.adapter_for(entry), names: names) if entry.chat?

      profile = ModelProfile.resolve(names: names, entry: entry, client: target.client, bare_model: target.bare_model).profile
      answer = VisionSupport.for(target, profile: profile, names: names)
      props = target.client.server_props(model: target.bare_model)
      return UNKNOWN_VISION if answer.no? && !props&.answered? && !configured_no?(answer)

      answer
    rescue StandardError
      UNKNOWN_VISION
    end

    UNKNOWN_VISION = VisionSupport::Answer.new(value: nil, reason: nil)

    # A no from the config (models: / hosts: vision: false) holds without
    # the server.
    def self.configured_no?(answer) = answer.reason.to_s.include?("sets vision: false")
    private_class_method :configured_no?

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
      options = parse
      return options if options.is_a?(Integer)

      # With --wait stdout is the answer alone.
      @info = options[:wait] ? @stderr : @stdout
      prompt = compose(utf8(read_stdin), utf8(options[:message]))
      # Before the wait-only case, which would drop the images.
      return usage_error("--image needs a message: pass -m TEXT or pipe it in") if prompt.nil? && !options[:images].empty?
      return run_wait_only(options) if prompt.nil? && options[:wait] && !options[:new]
      return usage_error("no message: pass -m TEXT or pipe it in") unless prompt

      begin
        prompt = SessionInbox.checked_text(prompt, noun: "message")
      rescue SessionInbox::NoteRejected => e
        @stderr.puts("chi send: #{e.message}")
        return 1
      end
      return 2 unless ingest_images(options[:images])

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
    ensure
      FileUtils.rm_rf(@image_dir) if @image_dir
    end

    private

    def command_name = "chi send"

    # @return [Hash, Integer] the options, or the exit status after the
    #   help or a usage error
    def parse
      parsed = parse_flags(FLAGS, @argv, images: [])
      return parsed if parsed.is_a?(Integer)

      options = parsed.options.merge(ids: parsed.args)
      if options[:timeout]
        return usage_error("--timeout needs --wait") unless options[:wait]

        options[:timeout] = Float(options[:timeout], exception: false)
        return usage_error("--timeout takes seconds") unless options[:timeout]&.positive?
      end
      return usage_error("--wait takes one session") if options[:wait] && options[:ids].uniq.size > 1
      return usage_error("at most #{MAX_IMAGES} images") if options[:images].size > MAX_IMAGES
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
    # once. The full id, so a script can pass it on. Only the model's host
    # is checked here (in spawn_session, as in the web): a wrong model id
    # fails in the worker.
    # @return [Integer] the exit status
    def run_new(prompt, options)
      images = !@images.empty?
      if images && (refusal = vision_refusal(options[:model]))
        error_line("chi send: refused: #{refusal}")
        return 1
      end
      begin
        # With images the web's way: idle (the message names it in the
        # lists), the images copied in, then the message as a turn.
        start = images ? { prompt: nil, title: prompt } : { prompt: prompt }
        session = SessionManager.spawn_session(**start, working_directory: options[:dir],
                                                        model_name: options[:model], state_dir: @state_dir)
      rescue StandardError => e
        error_line("chi send: could not start a session: #{e.message}")
        return 1
      end
      if images
        return 1 unless deliver_new(session, prompt)
      else
        @info.puts("#{session.id}  started")
      end
      return 0 unless options[:wait]

      wait_for_reply(session.id, cursor: nil, baseline: baseline_of(session, question_id: nil),
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
      baseline = baseline_of(session)
      return 1 unless deliver(id, prompt)

      wait_for_reply(id, cursor: cursor, baseline: baseline, timeout: options[:timeout])
    end

    # --wait with no message: the session's next reply, sending nothing,
    # so an agent can go back to waiting after exit 3 or 130. A running
    # turn is fine here (nothing joins its queue); a question pending now
    # was already reported. No message count: a note landing between turns
    # grows the messages without a turn. An idle session with no worker
    # waits for whatever wakes one (the web, chi send) rather than calling
    # it gone.
    # @return [Integer] the exit status
    def run_wait_only(options)
      id = resolve(options[:ids].first) or return 1
      session = Session.load(id, state_dir: @state_dir)
      live = session.status == Session::STATUS_RUNNING || SessionManager.session_owner(id, state_dir: @state_dir)
      wait_for_reply(id, cursor: ReplyWait.newest_reply(id, state_dir: @state_dir),
                         baseline: baseline_of(session).merge(messages: nil),
                         timeout: options[:timeout], owner_grace: live ? WORKER_GONE_AFTER : nil)
    end

    # The session as it was before the message went in (ReplyWait's
    # baseline).
    def baseline_of(session, **options)
      ReplyWait.baseline_of(session, **options)
    end

    # @return [Integer] the exit status
    def wait_for_reply(id, cursor:, baseline:, timeout:, owner_grace: WORKER_GONE_AFTER)
      result = ReplyWait.call(id, state_dir: @state_dir, cursor: cursor, timeout: timeout, baseline: baseline,
                                  owner_grace: owner_grace, poll_interval: POLL_INTERVAL)
      return reply(result.text) if result.status == :done

      attach = "chi --attach #{id}"
      line, status = case result.status
                     when :waiting_for_answer
                       question = result.question[:question].to_s.strip.lines.first.to_s.strip
                       ["waiting for an answer: #{question}; open it: #{attach} or the web", 3]
                     when :no_reply then ["#{no_reply_line(result)}; #{attach} shows it", 1]
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

    def no_reply_line(result)
      case result.outcome
      when "failed" then result.text.to_s.strip.empty? ? "the turn failed" : "the turn failed: #{result.text.strip}"
      when "canceled" then "the turn was canceled"
      when "completed" then "the turn ended with no visible answer"
      else "the turn ended without a reply (canceled, failed or empty)"
      end
    end

    def reply(text)
      @stdout.puts(utf8(text))
      @stdout.flush
      0
    end

    # A new idle session's first turn, with the images. Its worker's Bridge
    # first: deliver_turn wakes a worker when none owns the session yet,
    # and the spawned one takes its lock only once it runs.
    # @return [Boolean] whether the message was queued
    def deliver_new(session, prompt)
      dir = Session.session_dir(session.id, state_dir: @state_dir)
      result = nil
      begin
        refs = copy_images(dir)
        if BridgeClient.wait_for(session.id, session_dir: dir, timeout: SessionManager::TURN_BRIDGE_WAIT)
          result = SessionManager.deliver_turn(session.id, prompt: prompt, client_id: CLIENT_ID, images: refs,
                                                           state_dir: @state_dir)
        end
      rescue StandardError => e
        @info.puts("#{session.id}  failed: #{e.message}")
        return false
      end
      # Kept, not deleted: it holds the images, and the message shows as
      # its preview; the user can attach and send it again.
      unless result
        @info.puts("#{session.id}  failed: its worker did not start; the session is kept (chi --attach #{session.id})")
        return false
      end
      unless result[:status] == :accepted
        @info.puts("#{session.id}  failed: #{result.dig(:ack, "detail") || "could not queue it"}")
        return false
      end

      @info.puts("#{session.id}  started#{with_images}")
      true
    end

    # @return [Boolean] whether the message was queued
    def deliver(id, prompt)
      short = id[0, 8]
      session = Session.load(id, state_dir: @state_dir)
      if !@images.empty? && (refusal = vision_refusal(session.model_name, typed: session.model_typed))
        @info.puts("#{short}  refused: #{refusal}")
        return false
      end
      owner = SessionManager.session_owner(id, state_dir: @state_dir)
      running = owner && session.status == Session::STATUS_RUNNING
      refs = copy_images(Session.session_dir(id, state_dir: @state_dir))
      result = SessionManager.deliver_turn(id, prompt: prompt, client_id: CLIENT_ID, images: refs, state_dir: @state_dir)
      unless result[:status] == :accepted
        @info.puts("#{short}  failed: #{result.dig(:ack, "detail") || "could not queue it"}")
        return false
      end

      # A busy worker runs a message with images as its own next turn
      # rather than merging it into the running one.
      note = if owner.nil? then " (started its worker)"
             elsif running then refs.empty? ? " (the running turn picks it up)" : " (runs after the current turn)"
             end
      @info.puts("#{short}  sent#{with_images}#{note}")
      true
    rescue SessionManager::OwnedByTUI
      @info.puts("#{short}  refused: it is open in a chi REPL; messages need attached mode")
      false
    rescue StandardError => e
      @info.puts("#{short}  failed: #{e.message}")
      false
    end

    # What to say when +model_name+ is known not to take images, or nil
    # (it does, or it is unknown: sent as before). Asked once per model.
    def vision_refusal(model_name, typed: nil)
      @vision ||= {}
      answer = @vision[[model_name.to_s, typed.to_s]] ||= self.class.vision_answer(model_name, typed: typed)
      return nil unless answer.no?

      name = model_name.to_s.strip
      name = Samagotchi::Config.get("default.model").to_s.strip if name.empty?
      name = "the model" if name.empty?
      "#{name} can't take images (#{answer.reason}); send text only or switch the model (/model)"
    end

    # Each --image read, converted and downscaled once, into a scratch
    # session dir; each target then gets copies of the stored files. A file
    # that can't be sent stops everything before anything is sent.
    # @return [Boolean] false after the error line
    def ingest_images(paths)
      @images = []
      return true if paths.empty?

      @image_dir = Dir.mktmpdir("chi-send-images")
      @images = paths.map { |path| ImageStore.ingest(@image_dir, path: path) }
      true
    rescue ImageStore::Error => e
      error_line("chi send: #{e.message}")
      false
    end

    # The images' files copied into a session dir, as the refs a turn takes.
    def copy_images(session_dir)
      @images.map do |ref|
        ImageStore.copy_file(ref, from: @image_dir, to: session_dir)
        { file: ref[:file], name: ref[:name] }
      end
    end

    def with_images
      case @images.size
      when 0 then ""
      when 1 then " with 1 image"
      else " with #{@images.size} images"
      end
    end

    # The text as UTF-8 whatever the locale says: with no LANG/LC_* (an app
    # started from Finder, launchd) stdin reads as US-ASCII and ARGV as
    # binary. Invalid bytes become U+FFFD rather than an error.
    def utf8(text)
      text&.dup&.force_encoding(Encoding::UTF_8)&.scrub
    end
  end
end
