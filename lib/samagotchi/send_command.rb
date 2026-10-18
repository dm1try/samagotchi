# frozen_string_literal: true

require_relative "client_id"
require_relative "delivery"
require_relative "terminal_ui/formatting"
require_relative "session"
require_relative "session_commands"
require_relative "session_inbox"
require_relative "session_manager"
require_relative "bundle_session_settings"
require_relative "session_chain"
require_relative "context_quote"
require_relative "reply_wait"
require_relative "parent_report"
require_relative "turn_flow"
require_relative "guardrails/parent_approvals"
require_relative "guardrails/parent_policy"
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
    # A cut's outcomes in the Bridge's ack (SteerCut#cut_for_steer).
    CUT_OUTCOMES = %w[now waits off].freeze

    USAGE = <<~TEXT
      Usage: chi send [-m TEXT] [--image PATH]... [--cut | --queue] (ID|PREFIX)...
             chi send --new [--dir DIR] [--model M] [--llm-context LAYERS] [--thinking LEVEL] [--toolkit NAME] [--set BUNDLE.KEY=VALUE]... [--parent-answers LEVEL] [-m TEXT] [--image PATH]...
             chi send --new --continues (ID|PREFIX|last:ID) [--model M] [-m TEXT] [--image PATH]...
             chi send --wait [--timeout S] [--format json] [-m TEXT] [--image PATH]... (--new | ID)
             chi send --queue --wait [--timeout S] [--format json] [-m TEXT] ID
             chi send --wait [--timeout S] [--format json] [--turn T] ID
        Sends a message to each session, as if typed in it: a turn starts,
        or a running one takes it at its next step. A stopped session's
        worker starts.
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
                    in its folder, on its model (or --model's; one whose
                    host is gone falls back to the default, with a
                    warning), LLM context, thinking level, toolkit and
                    bundle settings, with a note carrying its recap; it
                    is archived.
                    last:ID names the chain's latest link.
                    Without -m the new session waits idle. Refused for a
                    session continued already (naming the next link) or
                    with delegates still open
        --model M   (--new) its model; default the configured one
        --llm-context LAYERS, --llm-context-apply RULE, --llm-context-budget N
                    (--new) its own LLM context strategy (none, stale,forget),
                    apply rule and budget (64k, off), as chi takes them
        --thinking LEVEL
                    (--new) its own thinking level (off, low, medium,
                    high; default: none of its own), above a process
                    default such as SAMAGOTCHI_THINKING_LEVEL
        --toolkit NAME, --tool NAME, --no-tool NAME
                    (--new) its toolkit, the tools its prompts declare
                    (full, lean, child, a config or bundle one; default
                    config's toolkit.default), and tools declared on top
                    of it or left out (repeatable, a comma list too)
        --set BUNDLE.KEY=VALUE
                    (--new) a bundle setting for this session, over
                    config.yml's bundles: (repeatable; a key its bundle's
                    manifest lists in session_settings:; 3, 2.5, true,
                    false and off are typed, the rest is text:
                    --set cost-cap.cap=3)
        --parent-answers LEVEL
                    (--new) what a parent agent may answer on its
                    questions: hard, standard or soft, only stricter than
                    config.yml's guardrails.parent_answers (a looser one
                    warns; config.yml's applies)
        --wait      wait for the answer and print it (one session); the
                    other lines go to stderr. Exit 3: it waits for an
                    answer from you: the question, its options and the
                    chi answer command go to stderr (or chi --attach ID,
                    the web). With no message (no -m, nothing piped)
                    nothing is sent: it waits for the session's next
                    reply, a running turn's too (after exit 3, 4 or 130,
                    wait again this way). To an idle session whose last
                    turn already ended, that ended turn is the answer:
                    its reply, or its end when it left none. --turn T
                    waits for that running, queued or last-ended turn
        --cut       ask the running turn to cut the generation it is
                    streaming and take the message now (a generation that
                    has streamed only thinking for steer.cut_after; else
                    the message waits for the thinking to pass it). A
                    message without --cut goes in at the running turn's
                    next step and cuts nothing. To an idle session it
                    sends normally. Refused with --wait into a running
                    turn (the steer's turn is the running one)
        --queue     run the message as a turn of its own after the running
                    turn ends, instead of merging it at its next step. To
                    an idle session it runs at once. With --wait it
                    waits for that turn's own answer, so a running turn
                    is fine. Not with --cut. Refused for a worker older
                    than queueing (it would steer; restart it)
        --timeout S (--wait) give up after S seconds, exit 4 (the turn
                    goes on); default no limit
        --turn T    (--wait, no message) wait for this turn id, from the
                    JSON's turn_id; not with -m
        --format json
                    (--wait) one JSON object on stdout, whatever the end:
                    status answered (text), question (question,
                    answer_with), turn_id when known, running, or failed, canceled,
                    limit, no_answer, error, worker_gone, stopped,
                    command (detail); with --cut or --queue also
                    delivery (what the worker applied: next_step, cut,
                    queue), with --cut also cut (now, waits, off)
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
      f.value "--thinking"
      f.value "--toolkit"
      f.value "--tool", key: :tools, repeat: true
      f.value "--no-tool", key: :no_tools, repeat: true
      f.value "--set", key: :sets, repeat: true
      f.value "--parent-answers", key: :parent_answers
      f.value "--image", key: :images, repeat: true
      f.switch "--wait"
      f.switch "--cut"
      f.switch "--queue"
      f.value "--timeout"
      f.value "--format"
      f.value "--turn"
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
      @cut = options[:cut] == true
      @queue = options[:queue] == true
      prompt = compose(utf8(read_stdin), utf8(options[:message]))
      # Before the wait-only case, which would drop the images.
      return usage_error("--image needs a message: pass -m TEXT or pipe it in") if prompt.nil? && !options[:images].empty?
      return usage_error("--turn cannot be used with a message") if options[:turn] && prompt
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
      # A UI-only command (/stats, /exit, …) runs in the terminal and the web,
      # not in the worker: sent through, the worker doesn't run it and the
      # line reaches the model as a prompt, costing a whole turn. Refused
      # before anything is sent (before a --new session is created too); the
      # session's plugin commands are never local.
      if prompt && (local = local_command(prompt))
        return refuse_local_command(local, options)
      end

      # A parent agent's /continue yes is chi answer --option Continue by
      # another route: held to guardrails.parent_answers (tightened by each
      # target's own) here, and marked as chi answer's (#client_id_for) so
      # the worker checks it again.
      if prompt && parent_continue?(prompt) && (refusal = continue_refusal_for(options))
        @stderr.puts("chi send: #{refusal}")
        return CLI::Exit::FAILED
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
      return usage_error("--cut and --queue: choose one") if options[:cut] && options[:queue]

      if options[:format]
        return usage_error("--format needs --wait") unless options[:wait]
        return usage_error("--format takes text or json") unless FORMATS.include?(options[:format])
      end
      if options[:timeout]
        return usage_error("--timeout needs --wait") unless options[:wait]

        options[:timeout] = Float(options[:timeout], exception: false)
        return usage_error("--timeout takes seconds") unless options[:timeout]&.positive?
      end
      return usage_error("--turn needs --wait") if options[:turn] && !options[:wait]
      return usage_error("--turn is only for waiting without a message") if options[:turn] && (options[:new] || options[:queue] || options[:cut])
      return usage_error("--wait takes one session") if options[:wait] && options[:ids].uniq.size > 1
      return usage_error("at most #{MAX_IMAGES} images") if options[:images].size > MAX_IMAGES
      return new_options(options) if options[:new]

      %i[dir model continues thinking toolkit].each { |key| return usage_error("--#{key} needs --new") if options[key] }
      TOOLKIT_FLAGS.each { |key, flag| return usage_error("#{flag} needs --new") unless Array(options[key]).empty? }
      LLM_CONTEXT_FLAGS.each { |key, flag| return usage_error("#{flag} needs --new") if options[key] }
      return usage_error("--set needs --new") unless Array(options[:sets]).empty?
      return usage_error("--parent-answers needs --new") if options[:parent_answers]
      return usage_error("give session ids") if options[:ids].empty?

      options
    end

    # The --llm-context* option keys, and their fields.
    LLM_CONTEXT_FLAGS = { llm_strategy: "--llm-context", llm_apply: "--llm-context-apply",
                          llm_budget: "--llm-context-budget" }.freeze
    LLM_CONTEXT_FIELDS = { llm_strategy: :strategy, llm_apply: :apply, llm_budget: :budget_tokens }.freeze
    # --tool / --no-tool's option keys.
    TOOLKIT_FLAGS = { tools: "--tool", no_tools: "--no-tool" }.freeze

    def new_options(options)
      return usage_error("--new takes no session ids: it starts one session") unless options[:ids].empty?

      if options[:continues]
        taken = [("--dir" if options[:dir])] +
                LLM_CONTEXT_FLAGS.filter_map { |key, flag| flag if options[key] } + [("--thinking" if options[:thinking])] +
                [("--toolkit" if options[:toolkit])] + TOOLKIT_FLAGS.filter_map { |key, flag| flag unless Array(options[key]).empty? } +
                [("--set" unless Array(options[:sets]).empty?), ("--parent-answers" if options[:parent_answers])]
        unless taken.compact.empty?
          return usage_error("--continues takes the previous session's folder, LLM context, thinking level, " \
                             "toolkit, bundle settings and parent_answers; " \
                             "leave out #{taken.compact.join(", ")}")
        end
      end

      words = LLM_CONTEXT_FIELDS.filter_map { |key, field| [field, options[key]] if options[key] }.to_h
      begin
        options[:llm_context] = LLMContextOverride.update(nil, words) unless words.empty?
      rescue ArgumentError => e
        return usage_error(e.message)
      end

      if options[:thinking]
        word = options[:thinking].strip.downcase
        unless Thinking::LEVELS.map(&:to_s).include?(word)
          return usage_error("--thinking takes #{Thinking::LEVELS.join(", ")}, not #{options[:thinking]}")
        end

        options[:thinking] = Thinking.session_level(word)
      end
      if options[:parent_answers]
        word = options[:parent_answers].strip.downcase
        levels = Guardrails::ParentPolicy::ORDER
        return usage_error("--parent-answers takes #{levels.join(", ")}, not #{options[:parent_answers]}") unless levels.include?(word)

        options[:parent_answers] = word
      end
      toolkit = Toolkit.from_flags(name: options[:toolkit], add: options[:tools], remove: options[:no_tools])
      options[:toolkit_value] = toolkit if toolkit
      begin
        options[:bundle_settings] = BundleSessionSettings.from_flags(options[:sets]) unless Array(options[:sets]).empty?
      rescue BundleSessionSettings::Error => e
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
                    SessionManager.continue_session(options[:continues], **start, model: options[:model],
                                                                             state_dir: @state_dir)
                  else
                    SessionManager.spawn_session(**start, working_directory: options[:dir],
                                                          model_name: options[:model],
                                                          setup: SessionSetup.new(llm_context: options[:llm_context],
                                                                                  thinking: options[:thinking],
                                                                                  toolkit: options[:toolkit_value],
                                                                                  bundle_settings: options[:bundle_settings] || {},
                                                                                  parent_answers: options[:parent_answers]),
                                                          state_dir: @state_dir)
                  end
      rescue SessionContinue::Refused, SessionManager::ArchiveRefused, SessionManager::OwnedByTUI => e
        error_line("chi send: refused: #{e.message}")
        return 1
      rescue StandardError => e
        error_line("chi send: could not start a session: #{e.message}")
        return 1
      end
      error_line("chi send: warning: #{session.model_warning}") if session.model_warning
      if (capped = Guardrails::ParentPolicy.capped_note(options[:parent_answers]))
        error_line("chi send: warning: --parent-answers #{capped}")
      end
      if through_worker
        return 1 unless deliver_new(session, prompt)
      else
        @info.puts("#{session.id}  started#{continued_words(session)}")
      end
      @session_id = session.id
      return 0 unless options[:wait]
      return report_command(session.id) if @sent_command

      wait_for_reply(session.id, cursor: nil, baseline: baseline_of(session, question_id: nil),
                                 timeout: options[:timeout], turn: @sent_input_file ? @sent_enqueued_id : nil,
                                 report_turn_id: @sent_enqueued_id)
    end

    # The model the new session will run, for the images check: --model
    # (nil: the default), or with --continues the one the new link will run
    # (SessionContinue.model_for: --model's, else the previous link's, else
    # the default it falls back to).
    # @return [Array, false] [model_name, model_typed], or false after the
    #   error line (no such session, a model it can't start on)
    def continued_model(options)
      return [options[:model], nil] unless options[:continues]

      previous = Session.load(SessionChain.resolve(options[:continues], state_dir: @state_dir), state_dir: @state_dir)
      choice = SessionContinue.model_for(previous, options[:model])
      inherited = options[:model].to_s.strip.empty? && choice.warning.nil?
      inherited ? [previous.model_name, previous.model_typed] : [choice.model, nil]
    rescue ModelProfile::MissingModel => e
      error_line("chi send: could not start a session: #{e.message}")
      false
    rescue ArgumentError => e
      error_line("chi send: #{e.message}")
      false
    end

    def continued_words(session)
      return "" unless session.continues

      moved = Array(session.moved_children).size
      " (continues #{session.continues[0, 8]}#{"; #{moved} delegate#{"s" if moved != 1} moved" if moved.positive?})"
    end

    # One existing session, then its next reply. The cursor and baseline
    # are taken before the message goes in, so neither an older reply nor a
    # turn that ends before the first look is mistaken for the answer. A
    # running turn is refused: a message that misses it runs next, and the
    # running one's reply would come back as the answer. Not with --queue:
    # the message's own turn is waited for (ReplyWait's turn:, its
    # enqueued_id), whatever runs before it.
    # @return [Integer] the exit status
    def run_wait(prompt, options)
      id = resolve(options[:ids].first) or return 1
      session = Session.load(id, state_dir: @state_dir)
      if session.status == Session::STATUS_RUNNING && (owner = SessionManager.session_owner(id, state_dir: @state_dir)) &&
         (!@queue || session.waiting_question(live: owner.worker?))
        # The turn waits on a question: the message would only queue
        # behind it, and the answer goes in with chi answer.
        if (waiting = session.waiting_question(live: owner.worker?))
          # The whole question (its options, its tags) for what a parent may
          # give: config.yml tightened by the session's own parent_answers.
          strategy = Guardrails::ParentPolicy.for_session(session)
          question = ParentReport.question(session.pending_question, strategy: strategy)
          if ParentReport.approval?(waiting)
            error_line("#{id[0, 8]}  waiting for an approval: #{ParentReport.approval_advice(question, strategy: strategy)} " \
                       "(#{ParentReport.answer_with(id, question)})")
          else
            error_line("#{id[0, 8]}  waiting for an answer: #{ParentReport.answer_with(id, question)} (or --text); " \
                       "chi --attach #{id} shows it")
          end
        else
          error_line("#{id[0, 8]}  busy: a turn is running; wait or attach")
        end
        return 1
      end

      cursor = ReplyWait.newest_reply(id, state_dir: @state_dir)
      baseline = baseline_of(session)
      running_turn = if session.status == Session::STATUS_RUNNING
                       ReplyWait.own_turn(session, session_dir: Session.session_dir(id, state_dir: @state_dir))
                     end
      return 1 unless deliver(id, prompt)
      return report_command(id) if @sent_command

      # The ack's id names the queued message's turn, also when the turn
      # running at the check ended before it went in (an idle worker's ack
      # says next_step, and the file still runs as that turn).
      # A file fallback has no delivery field; use its id to see terminal
      # outcomes for commands that finish without starting a turn.
      turn = @sent_enqueued_id if @queue || @sent_input_file
      report_turn_id = if @queue
                         turn
                       elsif session.status == Session::STATUS_RUNNING
                         running_turn
                       else
                         @sent_enqueued_id
                       end
      wait_for_reply(id, cursor: cursor, baseline: baseline, timeout: options[:timeout], turn: turn,
                          queued: @queue && !turn.nil?,
                          report_turn_id: report_turn_id)
    end

    # --wait with no message: the session's next reply, sending nothing,
    # so an agent can go back to waiting after exit 3 or 130. A running
    # turn is fine here (nothing joins its queue); a question pending now
    # was already reported. No message count: a note landing between turns
    # grows the messages without a turn. An idle session with no worker
    # waits for whatever wakes one (the web, chi send) rather than calling
    # it gone. The turn running now, or the one whose continue offer
    # stands, is the one waited for (ReplyWait.own_turn): its reply, not a
    # turn's queued behind it; with none known, the next reply. An idle
    # session whose last turn already ended (no question standing) went
    # idle in the gap between waits: that turn's end is the answer — its
    # reply, or its no-reply outcome — so the wait returns it at once
    # (ReplyWait's ended_before:) instead of timing out "running" again.
    # @return [Integer] the exit status
    def run_wait_only(options)
      id = resolve(options[:ids].first) or return 1
      session = Session.load(id, state_dir: @state_dir)
      session_dir = Session.session_dir(id, state_dir: @state_dir)
      requested_turn = options[:turn]&.to_s
      if requested_turn && !ReplyWait.known_turn?(session, session_dir: session_dir, turn: requested_turn)
        error_line("chi send: turn #{requested_turn} is not a running, queued, or last ended turn")
        return 1
      end
      live = session.status == Session::STATUS_RUNNING || SessionManager.session_owner(id, state_dir: @state_dir)
      turn = requested_turn || ReplyWait.own_turn(session, session_dir: session_dir)
      # The gate for the settled case: idle, a turn ended (last_turn), no
      # question standing (a continue offer waits for its answer).
      settled = session.status == Session::STATUS_IDLE && session.last_turn && session.pending_question.nil?
      ended_before = requested_turn ? session.last_turn&.enqueued_id == requested_turn : settled
      report_turn_id = turn
      report_turn_id ||= session.last_turn&.enqueued_id if settled
      wait_for_reply(id, cursor: ReplyWait.newest_reply(id, state_dir: @state_dir),
                         baseline: baseline_of(session).merge(messages: nil),
                         timeout: options[:timeout], owner_grace: live ? self.class::WORKER_GONE_AFTER : nil,
                         turn: turn, ended_before: ended_before, report_turn_id: report_turn_id)
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
          result = SessionManager.deliver_turn(session.id, prompt: prompt, client_id: client_id_for(prompt), images: refs,
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

      ack = result[:ack].is_a?(Hash) ? result[:ack] : {}
      @sent_input_file = !ack.key?("delivery")
      @sent_enqueued_id = (ack["enqueued_id"] || ack[:enqueued_id])&.to_s
      @sent_command = command_ack?(result[:ack])
      @info.puts("#{session.id}  started#{continued_words(session)}#{with_images}#{"; #{SENT_COMMAND}" if @sent_command}")
      true
    end

    SENT_COMMAND = "sent as a session command"

    # Whether the worker took the message as a session command (a POST
    # /turn whose line is one answers with its command_id).
    def command_ack?(ack) = ack.is_a?(Hash) && !ack["command_id"].to_s.empty?

    # chi send's client id, or chi answer's for a parent agent's /continue
    # yes (the worker holds that to its guardrails.parent_answers).
    def client_id_for(prompt) = parent_continue?(prompt) ? ClientId::CLI_ANSWER : CLIENT_ID

    # The first refusal of a parent's /continue yes among the targets, each
    # by config.yml tightened by its own parent_answers; nil when none
    # refuses.
    def continue_refusal_for(options)
      target_parent_answers(options).each do |value|
        strategy = Guardrails::ParentPolicy.effective(value)
        refusal = Guardrails::ParentPolicy.continue_refusal(strategy: strategy)
        return refusal if refusal
      end
      nil
    end

    # The targets' own parent_answers values: a --new session's
    # --parent-answers, a --continues link's previous session's (the link
    # keeps it), each id's. An id that doesn't resolve is skipped (#resolve
    # reports it later); none left is config.yml's alone ([nil]).
    def target_parent_answers(options)
      return [options[:parent_answers]] if options[:new] && !options[:continues]

      sessions = if options[:new]
                   [target_session { SessionChain.resolve(options[:continues], state_dir: @state_dir) }]
                 else
                   options[:ids].map { |given| target_session { Session.resolve_id(given, state_dir: @state_dir) } }
                 end
      values = sessions.compact.map(&:parent_answers)
      values.empty? ? [nil] : values
    end

    # The session the block's id names, or nil when there is none.
    def target_session
      Session.load(yield, state_dir: @state_dir)
    rescue ArgumentError
      nil
    end

    # A /continue yes (or bare /continue) from a parent agent's process.
    def parent_continue?(prompt) = TurnFlow.continue_yes?(prompt) && Guardrails::ParentApprovals.parent_process?

    # Whether +text+ may be a session command, which only its worker knows
    # (a bundle's too).
    def command_like?(text) = text.to_s.lstrip.start_with?("/", "!")

    # @return [Commands::Registry::Entry, nil] SessionCommands.ui_only_entry
    def local_command(text) = SessionCommands.ui_only_entry(text)

    # A UI-only command: nothing is sent (with --new, no session is created
    # either). /stats points at its model-free reader and names the session;
    # the others just say the worker doesn't run them. Exit 1, as other
    # refusals; with --wait --format json the line is the usual error object
    # (ParentWait's end-of-run line when the reply never comes).
    # @return [Integer] 1
    def refuse_local_command(entry, options)
      if options[:new]
        error_line("chi send: refused: #{local_refusal(entry.name, nil)}")
      elsif options[:wait]
        # --wait: the JSON line goes to stdout, @info is stderr; an unknown
        # or ambiguous id gets resolve's own error line.
        id = resolve(options[:ids].first) or return CLI::Exit::FAILED
        @stderr.puts("#{id[0, 8]}  refused: #{local_refusal(entry.name, id)}")
      else
        options[:ids].uniq.each do |given|
          id = resolve(given) or next
          @info.puts("#{id[0, 8]}  refused: #{local_refusal(entry.name, id)}")
        end
      end
      CLI::Exit::FAILED
    end

    def local_refusal(name, id) = SessionCommands.ui_only_refusal(name, id, runner: "chi send")

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
      # --cut asks the running turn for a cut (to an idle session an
      # ordinary message: nothing to cut). --queue always goes as a queue,
      # idle or not: the Bridge acks next_step to an idle worker and the
      # file still carries it, so a turn another client starts first never
      # merges it, and its turn and reply carry its enqueued_id (the
      # --wait's turn:); a worker older than queueing is refused.
      delivery = if @queue then Delivery::QUEUE
                 elsif @cut && running then Delivery::CUT
                 end
      result = SessionManager.deliver_turn(id, prompt: prompt, client_id: client_id_for(prompt), images: refs, state_dir: @state_dir,
                                               delivery: delivery)
      unless result[:status] == :accepted
        # A worker older than queueing would steer it: refused, not sent.
        word = result.dig(:ack, "error") == Delivery::QUEUE_UNAVAILABLE["error"] ? "refused" : "failed"
        @info.puts("#{short}  #{word}: #{result.dig(:ack, "detail") || "could not queue it"}")
        return false
      end

      @sent_command = command_ack?(result[:ack])
      if @sent_command
        @info.puts("#{short}  #{SENT_COMMAND}")
        return true
      end

      ack = result[:ack].is_a?(Hash) ? result[:ack] : {}
      @sent_input_file = !ack.key?("delivery")
      # What the worker applied, for --format json: its ack's delivery
      # (next_step for an idle session) and a cut's outcome.
      @sent_delivery = ack["delivery"] || delivery
      @sent_cut = ack["cut"]
      @sent_enqueued_id = (ack["enqueued_id"] || ack[:enqueued_id])&.to_s
      @info.puts("#{short}  sent#{with_images}#{delivery_note(ack, delivery: delivery, running: running, owner: owner)}")
      true
    rescue SessionManager::OwnedByTUI
      @info.puts("#{short}  refused: it is open in a chi REPL; messages need attached mode")
      false
    rescue StandardError => e
      @info.puts("#{short}  failed: #{e.message}")
      false
    end

    # What the line says became of the message: a plain one goes in at the
    # running turn's next step (nothing cuts by default); a --cut one names
    # the outcome from the ack (now, waits, off); a --queue one runs after
    # the turn (or now, when the turn ended before it went in); images keep
    # their own wording; an idle session's turn simply runs.
    # @param ack [Hash] the Bridge's 202 body ({} for the input file)
    # @return [String] "" or " (...)"
    def delivery_note(ack, delivery:, running:, owner:)
      return " (started its worker)" if owner.nil?
      return queue_note(ack, running: running) if Delivery.queue?(delivery)
      return "" unless running

      # A busy worker runs a message with images as its own next turn
      # rather than merging it into the running one.
      return " (runs after the current turn)" unless @images.empty?

      # The TUIs' words for a cut's outcome. No outcome: a plain message,
      # or the input file (the Bridge went away), which the next step's
      # drain takes.
      outcome = Delivery.cut?(delivery) ? ack["cut"].to_s : ""
      return " (goes in at the running turn's next step)" unless CUT_OUTCOMES.include?(outcome)

      " #{TerminalUI::Formatting.steer_cut_note(outcome.to_sym, ack["cut_after"])}"
    end

    # A --queue, worded from the Bridge's ack: queue when a turn ran as it
    # went in (one another client started too), next_step when none did
    # (it runs now). The input file (no Bridge) carries the queue to
    # whichever turn runs: worded from the session as chi read it.
    def queue_note(ack, running:)
      queued = ack.key?("delivery") ? ack["delivery"] == Delivery::QUEUE : running
      return " (queued: runs after the current turn)" if queued

      running ? " (the running turn had ended: it runs now)" : " (nothing running: it runs now)"
    end

    # More keys for --format json, with --cut or --queue only (the line is
    # unchanged otherwise): the delivery the worker applied (next_step to
    # an idle session) and a cut's outcome (now, waits, off). --cut --wait
    # is refused for a running turn, so its json line says next_step.
    def report_extra
      return {} unless @cut || @queue

      extra = { delivery: @sent_delivery || Delivery::NEXT_STEP }
      extra[:cut] = @sent_cut if @sent_cut
      extra
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
