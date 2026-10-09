# frozen_string_literal: true

require_relative "client_id"
require_relative "session"
require_relative "session_inbox"
require_relative "session_manager"
require_relative "session_chain"
require_relative "context_quote"
require_relative "reply_wait"
require_relative "parent_report"
require_relative "image_store"
require_relative "host_registry"
require_relative "model_profile"
require_relative "vision_support"
require_relative "cli/command"
require_relative "cli/flags"
require_relative "cli/parent_wait"

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
    include CLI::ParentWait

    CLIENT_ID = ClientId::CLI_SEND
    # The cap on one turn's images the Bridge checks.
    MAX_IMAGES = ImageStore::MAX_TURN_REFS

    USAGE = <<~TEXT
      Usage: chi send [-m TEXT] [--image PATH]... (ID|PREFIX)...
             chi send --new [--dir DIR] [--model M] [--llm-context LAYERS] [-m TEXT] [--image PATH]...
             chi send --new --continues (ID|PREFIX|last:ID) [-m TEXT] [--image PATH]...
             chi send --wait [--timeout S] [--format json] [-m TEXT] [--image PATH]... (--new | ID)
             chi send --wait [--timeout S] [--format json] ID
        Sends a message to each session, as if typed in it: a turn starts,
        or a running one picks it up. A stopped session's worker starts.
        A session command (/model x, !cmd) runs as the command; --wait
        then has no reply to wait for (exit 0, status command).
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
        --continues ID
                    (--new) start the next link of that session's chain:
                    in its folder, on its model and LLM context, with a
                    note carrying its recap; it is archived. last:ID
                    names the chain's latest link. Without -m the new
                    session waits idle. Refused for a session continued
                    already (naming the next link) or with delegates
                    still open
        --model M   (--new) its model; default the configured one
        --llm-context LAYERS, --llm-context-apply RULE, --llm-context-budget N
                    (--new) its own LLM context strategy (none, stale,forget),
                    apply rule and budget (64k, off), as chi takes them
        --wait      wait for the answer and print it (one session); the
                    other lines go to stderr. Exit 3: it waits for an
                    answer from you: the question, its options and the
                    chi answer command go to stderr (or chi --attach ID,
                    the web). With no message (no -m, nothing piped)
                    nothing is sent: it waits for the session's next
                    reply, a running turn's too (after exit 3, 4 or 130,
                    wait again this way)
        --timeout S (--wait) give up after S seconds, exit 4 (the turn
                    goes on); default no limit
        --format json
                    (--wait) one JSON object on stdout, whatever the end:
                    status answered (text), question (question,
                    answer_with), running, or failed, canceled,
                    limit, no_answer, error, worker_gone, stopped,
                    command (detail)
        Exit with --wait: 0 answered, 1 failed or gone, 2 usage, 3 a
        question waits, 4 still running (--timeout), 130 Ctrl-C.
        Only sessions on this machine. Answers show in the attached TUI
        or web page, not here.
        Find ids with: chi sessions list --live [--scope=all] [--format tsv]
    TEXT

    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS) do |f|
      f.value "-m", "--message"
      f.switch "--new"
      f.value "--dir"
      f.value "--continues"
      f.value "--model"
      f.value "--llm-context", key: :llm_strategy
      f.value "--llm-context-apply", key: :llm_apply
      f.value "--llm-context-budget", key: :llm_budget
      f.value "--image", key: :images, repeat: true
      f.switch "--wait"
      f.value "--timeout"
      f.value "--format"
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

    private

    # Under #run (CLI::ParentWait).
    # @return [Integer] exit status: 0 all sent, 1 any refused or failed,
    #   2 usage; with --wait 0 answered, 3 waiting for an answer, 4 still
    #   running after --timeout, 130 Ctrl-C (the turn goes on)
    def run_parsed(options)
      # With --wait stdout is the answer alone.
      @info = options[:wait] ? @stderr : @stdout
      prompt = compose(utf8(read_stdin), utf8(options[:message]))
      # Before the wait-only case, which would drop the images.
      return usage_error("--image needs a message: pass -m TEXT or pipe it in") if prompt.nil? && !options[:images].empty?
      return run_wait_only(options) if prompt.nil? && options[:wait] && !options[:new]

      # The next link of a chain may start idle, waiting for its first message.
      idle_link = prompt.nil? && options[:continues]
      return usage_error("--wait needs a message to wait for: pass -m TEXT") if idle_link && options[:wait]
      return usage_error("no message: pass -m TEXT or pipe it in") unless prompt || idle_link

      begin
        prompt &&= SessionInbox.checked_text(prompt, noun: "message")
      rescue SessionInbox::NoteRejected => e
        @stderr.puts("chi send: #{e.message}")
        return 1
      end
      # A file that is not there or not an image: a run-time failure (1),
      # reported in the --format json line too; --image itself was fine.
      return CLI::Exit::FAILED unless ingest_images(options[:images])

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

    def command_name = "chi send"

    # @return [Hash, Integer] the options, or the exit status after the
    #   help or a usage error
    def parse
      parsed = parse_flags(FLAGS, @argv, images: [])
      return parsed if parsed.is_a?(Integer)

      options = parsed.options.merge(ids: parsed.args)
      if options[:format]
        return usage_error("--format needs --wait") unless options[:wait]
        return usage_error("--format takes text or json") unless FORMATS.include?(options[:format])
      end
      if options[:timeout]
        return usage_error("--timeout needs --wait") unless options[:wait]

        options[:timeout] = Float(options[:timeout], exception: false)
        return usage_error("--timeout takes seconds") unless options[:timeout]&.positive?
      end
      return usage_error("--wait takes one session") if options[:wait] && options[:ids].uniq.size > 1
      return usage_error("at most #{MAX_IMAGES} images") if options[:images].size > MAX_IMAGES
      return new_options(options) if options[:new]

      %i[dir model continues].each { |key| return usage_error("--#{key} needs --new") if options[key] }
      LLM_CONTEXT_FLAGS.each { |key, flag| return usage_error("#{flag} needs --new") if options[key] }
      return usage_error("give session ids") if options[:ids].empty?

      options
    end

    # The --llm-context* option keys, and their fields.
    LLM_CONTEXT_FLAGS = { llm_strategy: "--llm-context", llm_apply: "--llm-context-apply",
                          llm_budget: "--llm-context-budget" }.freeze
    LLM_CONTEXT_FIELDS = { llm_strategy: :strategy, llm_apply: :apply, llm_budget: :budget_tokens }.freeze

    def new_options(options)
      return usage_error("--new takes no session ids: it starts one session") unless options[:ids].empty?

      if options[:continues]
        taken = [("--dir" if options[:dir]), ("--model" if options[:model])] +
                LLM_CONTEXT_FLAGS.filter_map { |key, flag| flag if options[key] }
        unless taken.compact.empty?
          return usage_error("--continues takes the previous session's folder, model and LLM context; " \
                             "leave out #{taken.compact.join(", ")}")
        end
      end

      words = LLM_CONTEXT_FIELDS.filter_map { |key, field| [field, options[key]] if options[key] }.to_h
      begin
        options[:llm_context] = LLMContextOverride.update(nil, words) unless words.empty?
      rescue ArgumentError => e
        return usage_error(e.message)
      end

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

    # A worker session like the web start page's: saved as running with the
    # message before its worker spawns, so lists and the web show it at
    # once. The full id, so a script can pass it on. The model's host is
    # checked here (in spawn_session, as in the web): an unknown one is
    # refused before anything is spawned; an id the host's saved model list
    # doesn't have starts with a warning on stderr.
    # @return [Integer] the exit status
    def run_new(prompt, options)
      images = !@images.empty?
      model, typed = continued_model(options)
      return 1 if model == false

      if images && (refusal = vision_refusal(model, typed: typed))
        error_line("chi send: refused: #{refusal}")
        return 1
      end
      # With images the web's way: idle (the message names it in the
      # lists), the images copied in, then the message as a turn. So too a
      # line that may be a session command (/model x): its worker's answer
      # says whether it ran as one.
      through_worker = images || command_like?(prompt)
      begin
        start = through_worker ? { prompt: nil, title: prompt } : { prompt: prompt }
        session = if options[:continues]
                    SessionManager.continue_session(options[:continues], **start, state_dir: @state_dir)
                  else
                    SessionManager.spawn_session(**start, working_directory: options[:dir],
                                                          model_name: options[:model], llm_context: options[:llm_context],
                                                          state_dir: @state_dir)
                  end
      rescue SessionManager::ContinueRefused, SessionManager::ArchiveRefused, SessionManager::OwnedByTUI => e
        error_line("chi send: refused: #{e.message}")
        return 1
      rescue StandardError => e
        error_line("chi send: could not start a session: #{e.message}")
        return 1
      end
      error_line("chi send: warning: #{session.model_warning}") if session.model_warning
      if through_worker
        return 1 unless deliver_new(session, prompt)
      else
        @info.puts("#{session.id}  started#{continued_words(session)}")
      end
      @session_id = session.id
      return 0 unless options[:wait]
      return report_command(session.id) if @sent_command

      wait_for_reply(session.id, cursor: nil, baseline: baseline_of(session, question_id: nil),
                                 timeout: options[:timeout])
    end

    # --continues: the model the new link will run (the previous link's),
    # for the images check; [nil, nil] without --continues.
    # @return [Array, false] [model_name, model_typed], or false after the
    #   error line (no such session)
    def continued_model(options)
      return [options[:model], nil] unless options[:continues]

      previous = Session.load(SessionChain.resolve(options[:continues], state_dir: @state_dir), state_dir: @state_dir)
      [previous.model_name, previous.model_typed]
    rescue ArgumentError => e
      error_line("chi send: #{e.message}")
      false
    end

    def continued_words(session) = session.continues ? " (continues #{session.continues[0, 8]})" : ""

    # One existing session, then its next reply. The cursor and baseline
    # are taken before the message goes in, so neither an older reply nor a
    # turn that ends before the first look is mistaken for the answer. A
    # running turn is refused: a message that misses it runs next, and the
    # running one's reply would come back as the answer.
    # @return [Integer] the exit status
    def run_wait(prompt, options)
      id = resolve(options[:ids].first) or return 1
      session = Session.load(id, state_dir: @state_dir)
      if session.status == Session::STATUS_RUNNING && (owner = SessionManager.session_owner(id, state_dir: @state_dir))
        # The turn waits on a question: the message would only queue
        # behind it, and the answer goes in with chi answer.
        if (waiting = session.waiting_question(live: owner.worker?))
          if ParentReport.approval?(waiting)
            error_line("#{id[0, 8]}  waiting for an approval: #{ParentReport::DENY_AND_TELL} " \
                       "(#{ParentReport.answer_with(id, waiting)})")
          else
            error_line("#{id[0, 8]}  waiting for an answer: #{ParentReport.answer_with(id, waiting)} (or --text); " \
                       "chi --attach #{id} shows it")
          end
        else
          error_line("#{id[0, 8]}  busy: a turn is running; wait or attach")
        end
        return 1
      end

      cursor = ReplyWait.newest_reply(id, state_dir: @state_dir)
      baseline = baseline_of(session)
      return 1 unless deliver(id, prompt)
      return report_command(id) if @sent_command

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
                         timeout: options[:timeout], owner_grace: live ? self.class::WORKER_GONE_AFTER : nil)
    end

    # The session as it was before the message went in (ReplyWait's
    # baseline).
    def baseline_of(session, **)
      ReplyWait.baseline_of(session, **)
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

      @sent_command = command_ack?(result[:ack])
      @info.puts("#{session.id}  started#{continued_words(session)}#{with_images}#{"; #{SENT_COMMAND}" if @sent_command}")
      true
    end

    SENT_COMMAND = "sent as a session command"

    # Whether the worker took the message as a session command (a POST
    # /turn whose line is one answers with its command_id).
    def command_ack?(ack) = ack.is_a?(Hash) && !ack["command_id"].to_s.empty?

    # Whether +text+ may be a session command, which only its worker knows
    # (a bundle's too).
    def command_like?(text) = text.to_s.lstrip.start_with?("/", "!")

    # --wait after a message that ran as a session command: no reply comes
    # for it. Its output shows where the session is open.
    # @return [Integer] 0
    def report_command(id)
      detail = "#{SENT_COMMAND}: no reply to wait for (its output shows in chi --attach #{id} or the web)"
      if @json
        @stdout.puts(JSON.generate({ status: "command", session_id: id, detail: detail }))
        @stdout.flush
        @reported = true
      else
        @stderr.puts("#{id[0, 8]}  #{detail}")
      end
      CLI::Exit::OK
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

      @sent_command = command_ack?(result[:ack])
      if @sent_command
        @info.puts("#{short}  #{SENT_COMMAND}")
        return true
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
  end
end
