# frozen_string_literal: true

require "json"
require "fileutils"

require_relative "client_id"
require_relative "iteration_limit"
require_relative "model_profile"
require_relative "turn_checkpoint"
require_relative "config"
require_relative "context_candidates"
require_relative "llm/errors"
require_relative "host_registry"
require_relative "session"
require_relative "owner_lock"
require_relative "empty_answer_error"
require_relative "bridge/card_store"
require_relative "bridge/turn_accumulator"
require_relative "bridge/turn_drawings"
require_relative "bridge/pending_card"
require_relative "engine"
require_relative "turn_flow"
require_relative "session_commands"
require_relative "composer_route"
require_relative "degrade"
require_relative "terminal_ui/formatting"
require_relative "terminal_ui/image_input"
require_relative "terminal_ui/plain_surface"
require_relative "terminal_ui/one_shot_sink"
require_relative "terminal_ui/question_prompt"
require_relative "log"

module Samagotchi
  # Loaded on first use: this autoload keeps SessionManager and its ~80
  # files unloaded until the delegate/session path needs them.
  autoload :SessionManager, File.expand_path("session_manager", __dir__)

  # The one-shot host: `chi -p TEXT --non-interactive` (`chi scratch`'s and
  # `--resume ID`'s too) runs that one turn in this process, its answer
  # alone on stdout, and exits. It owns the session for the turn (an
  # OwnerLock of kind "tui") and its Engine. Every interactive terminal is
  # the attached one (TerminalUI::AttachLauncher, AttachedLoop), a client
  # of the session's worker; the namespace keeps the terminal's parts.
  class TerminalUI
    include Formatting

    # Raised when another process (a worker or another chi) owns the session
    # this run was asked to use.
    class SessionBusy < StandardError; end

    # The session's Engine.
    # @return [Engine]
    attr_reader :engine

    def self.system_prompt_for(profile)
      Engine.system_prompt_for(profile)
    end

    # @param prompt [String, nil] the turn's prompt (-p); nil: nothing runs
    # @param scratch [Boolean] `chi scratch`: a new session that is deleted
    #   however the run ends, saves no memories and writes no recap
    # @param llm_context [Hash{Symbol => String}] --llm-context* as typed
    #   (LLMContextOverride.update): set on the new or resumed session
    # @param thinking [String, nil] --thinking as typed: the new or resumed
    #   session's own level (default unsets it)
    # @param appended_prompt_files [Array<String>] --append-system-prompt's
    #   files (absolute): a new session saves them; a resumed one's own come
    #   first, and the merge goes only to the Engine (as --memory's does)
    # @param toolkit [Toolkit, nil] --toolkit/--tool/--no-tool: a new
    #   session's toolkit (config's toolkit.default without); a resumed one
    #   keeps its own, with a line naming +toolkit_flags+ (the flags given)
    # @param settings [SessionConfig::Settings, nil] --set's values:
    #   a new session's own; a resumed one keeps its own (--set is in
    #   +toolkit_flags+ then)
    # @param parent_answers [String, nil] --parent-answers: a new session's
    #   own guardrails.parent_answers; a resumed one keeps its own (named in
    #   +toolkit_flags+ then)
    # @param surface [#commit, nil] where the answer goes (stdout by default)
    def initialize(prompt: nil, client: nil, host_registry: nil, profile: nil, session_id: nil, model_name: nil,
                   memories: [], muted_memories: [], surface: nil, scratch: false, llm_context: {}, thinking: nil,
                   appended_prompt_files: [], toolkit: nil, toolkit_flags: [], settings: nil, parent_answers: nil)
      @scratch        = scratch
      @parent_answers = parent_answers
      @toolkit        = toolkit
      @toolkit_flags  = toolkit_flags
      @session_settings = settings
      @thinking_word  = thinking
      @prompt         = prompt
      @llm_context_words = llm_context
      @default_model_name = ModelProfile.default_model_name
      # As typed: the Engine applies an alias where it resolves the model.
      flag_model_name = model_name.to_s.strip.empty? ? nil : ModelProfile.required_model_name(model_name)
      @effective_model_name = flag_model_name || @default_model_name
      # Taken once (as the Engine's); a client (specs) goes on a registry of
      # its own, never the shared one.
      @host_registry = host_registry || (client ? Samagotchi::HostRegistry.new : Samagotchi::HostRegistry.current)
      # An injected client (specs) stands in for every host's client.
      @host_registry.client_override = client if client
      @client = @host_registry.resolve(@effective_model_name).client
      # Own the session before loading it, so a worker can't write a turn
      # between the load and the lock that this run would later save over.
      # An unknown id is refused before the claim, which would leave an
      # empty session dir behind.
      raise Session::NotFound, session_id if session_id && !Session.exist?(session_id)

      claim_session!(session_id) if session_id
      @resume_session = session_id ? Session.load(session_id) : nil
      drop_dead_question(@resume_session) if @resume_session
      if @resume_session
        # --model overrides resumed session's model (runtime only, default unchanged)
        if flag_model_name
          @effective_model_name = flag_model_name
        else
          @effective_model_name = @resume_session.model_name.to_s.strip.empty? ? @default_model_name : @resume_session.model_name
          @resumed_model_typed = @resume_session.model_typed
        end
        # Re-resolve client after resume may change effective model
        @client = @host_registry.resolve(@effective_model_name).client
      end
      # No --model, no session model and no default: nothing to run.
      raise ModelProfile::MissingModel, ModelProfile.missing_model_message if @effective_model_name.to_s.strip.empty?

      # With no config default the Engine starts on the model it runs.
      no_default = @default_model_name.nil?

      # The model it starts on names a configured host (a bad default.model
      # doesn't matter when --model or the session picks another).
      ModelProfile.check_host!(@effective_model_name, hosts: @host_registry.entries)
      # --memory and --mute, with a resumed session's own lists first: a
      # session started attached with mutes keeps them here.
      @requested_memories = Array(memories)
      @muted_memory_names = Array(muted_memories)
      @appended_prompt_files = Array(appended_prompt_files)
      if @resume_session
        @requested_memories = (@resume_session.preloaded_memory_names + @requested_memories).uniq
        @muted_memory_names = (@resume_session.muted_memory_names + @muted_memory_names).uniq
        @appended_prompt_files = (@resume_session.appended_prompt_files + @appended_prompt_files).uniq
      end
      @surface = surface || PlainSurface.new
      @engine = Engine.new(
        client: client,
        host_registry: @host_registry,
        profile: profile,
        session_id: session_id,
        no_interrupt: true,
        # nil: the config default, unchecked here (the model the run starts
        # on is checked above, and --model may make the default moot). With
        # no default, the model it runs (the switch below is then skipped).
        model_name: no_default ? @effective_model_name : nil,
        model_typed: no_default ? @resumed_model_typed : nil,
        memories: @requested_memories,
        muted_memories: @muted_memory_names,
        appended_prompt_files: @appended_prompt_files,
        scratch: scratch
      )
      # No one is there to answer: an approval denies.
      @engine.interface = :non_interactive
      # The run exits after its turn: no turn-end warm-up.
      @engine.next_turn_waiting = -> { true }
      @turn_flow = TurnFlow.new(engine: @engine)
      @engine.recap_awaiting_continue = -> { @turn_flow.awaiting_continue? }
      @commands = SessionCommands.new(engine: @engine, turn_flow: @turn_flow, default_model: @default_model_name,
                                      registry: @engine.command_registry)
      # Runtime --model flag or resumed session: switch the Engine (client,
      # kernel profile) without persisting the default. Skipped when there's
      # no config default (the Engine was built on the session model).
      @engine.switch_model!(@effective_model_name, typed: @resumed_model_typed) if !no_default && @effective_model_name != @default_model_name
      # ask_user_question in the turn: no one can answer it here.
      @engine.set_question_sync_handler do |pending|
        dismiss_unaskable_question(QuestionPrompt.new(pending))
        nil
      end
    end

    # The setup a new one-shot session starts with (a resumed one keeps
    # its own; #run lays --llm-context* and --thinking over it). It is made
    # with Session.new_session, not spawn_session, so config's default
    # toolkit is filled in here.
    # @return [SessionSetup]
    def new_session_setup
      llm_context = LLMContextOverride.update(nil, @llm_context_words) unless @llm_context_words.empty?
      setup = SessionSetup.from_request(memories: @requested_memories, muted: @muted_memory_names,
                                        llm_context: llm_context, thinking: @thinking_word,
                                        appended_prompt_files: @appended_prompt_files, toolkit: @toolkit,
                                        settings: @session_settings, parent_answers: @parent_answers)
      @toolkit ? setup : setup.with(toolkit: Toolkit.configured, toolkit_origin: "default")
    end

    # Run the -p prompt as one turn (a session command as that command),
    # then return; with no prompt, nothing (no session is made).
    # @return [Symbol, nil] :turn_failed when the turn failed or the command
    #   was refused, :empty_answer when the turn ended with no answer,
    #   :iteration_limit when the iteration limit cut it short (bin/chi exits
    #   1 on all three), :interrupted when Ctrl-C cancelled it (bin/chi
    #   exits 130)
    def run
      return if @prompt.nil?
      # A UI-only command (/stats, /exit …) isn't run without a terminal,
      # and isn't a prompt either: refused as chi send refuses it, before
      # any session is made (bin/chi exits 1).
      return refuse_one_shot_ui_command if SessionCommandCatalog.ui_only_entry(@prompt)

      session = @resume_session || @engine.store_model!(Session.new_session(
        mode: "assist",
        model_name: @effective_model_name,
        working_directory: Dir.pwd,
        scratch: @scratch,
        setup: new_session_setup
      ))
      # --llm-context* and --thinking on a resumed one: the session's own
      # values, over its own (a new one's are in its setup). Saved at once:
      # leaving before a turn keeps them.
      if @resume_session && !(@llm_context_words.empty? && @thinking_word.nil?)
        session.llm_context = LLMContextOverride.update(session.llm_context, @llm_context_words) unless @llm_context_words.empty?
        session.thinking = Thinking.session_level(@thinking_word) if @thinking_word
        session.save
      end
      warn_toolkit_flags_ignored(session) if @resume_session
      claim_session!(session.id) unless @owner_lock
      # A turn a worker died in (TurnCheckpoint): ended as canceled, with its
      # note, before this run's turn appends after it.
      session.save if @resume_session && TurnCheckpoint.settle(session, session_dir: Session.session_dir(session.id))
      keep_cards(session)
      # Saved at once, so a process killed before its turn leaves a file
      # the sweep knows to delete.
      session.save if @scratch
      # Attach before building the prompt so it can name the session id.
      @engine.session = session
      banner_for(session)

      # A session command (/models, !ls) runs as the command, not as a turn.
      return run_one_shot_command(session) if command_registry.command?(@prompt)

      run_one_shot_turn(session)
    ensure
      # However it ends (the early returns too; the Engine was built in
      # #initialize): the anytime commands finish, the plugins' services
      # stop (a server process). Nothing resolves an open card any more, so
      # its pending_card.json goes (a scratch session's folder is deleted
      # below anyway; the others stay).
      clear_pending_card
      @engine&.shutdown
      # A scratch session goes on every way out: the turn's end, an error,
      # SIGTERM or SIGHUP (Ruby raises those here). Only kill -9 leaves it
      # to the sweep.
      delete_scratch(session) if @scratch && session
    end

    private

    def command_registry = @commands.registry

    # The turn: its answer on stdout, the retry lines and hook notices on
    # stderr (OneShotSink).
    def run_one_shot_turn(session)
      # A /cut TEXT / /queue TEXT prompt runs its text as the turn's prompt,
      # as an idle attached terminal does (ComposerRoute.steer_choice); a
      # bare /cut / /queue (no text) is refused above as a UI command, so
      # only the text here. The images are the text's, not the words'.
      prompt =
        if (choice = ComposerRoute.steer_choice(@prompt)) && !choice.last.empty?
          choice.last
        else
          @prompt
        end
      ArchiveStore.user_input(session.id, state_dir: Session.default_state_dir)
      sink = OneShotSink.new
      # The turn's drawing, as a worker's Bridge writes it: this process is
      # the session's owner (OwnerLock), the file's one writer meanwhile.
      drawings = Bridge::TurnDrawings.new(path: File.join(Session.session_dir(session.id), Bridge::TurnDrawings::FILE),
                                          messages: -> { session.messages })
      accumulator = Bridge::TurnAccumulator.new(on_turn_end: drawings.method(:append))
      events = lambda do |event|
        sink.call(event)
        accumulator.call(event)
      end
      save_before_first_turn(session)
      attach_mentioned_context(session, prompt)
      max_iterations = IterationLimit.for(no_interrupt: true)
      begin
        result = @engine.run_turn(session, prompt, on_event: events, max_iterations: max_iterations,
                                                   cancel_controller: nil, images: ImageInput.extract(prompt))
      rescue LLM::ProviderError, ImageStore::Error => e
        return one_shot_failed(session, e)
      rescue Interrupt
        return one_shot_interrupted(session)
      end
      # No answer (the empty-answer retries used up): no text, or the chat
      # loop's placeholder (LLM::ModelResult#empty_answer?).
      if result.empty_answer?
        # Nothing to print: say so on stderr and fail (bin/chi exits 1),
        # so a script that pipes the answer doesn't take the silence for one.
        session.save
        warn EMPTY_ANSWER_ERROR
        sink.flush
        return :empty_answer
      end
      @surface.commit(result.output)
      session.save
      # The after_turn hooks' notices, after the answer.
      sink.flush
      # The limit cut the turn short: what came so far is no answer, so say
      # so and fail (bin/chi exits 1).
      one_shot_exhausted(session, max_iterations) if result.resumable?
    end

    # The session is over for this process (its exits and #run's ensure):
    # nothing will resolve the open card any more, so its pending_card.json
    # goes.
    def clear_pending_card
      return unless @pending_card_handle

      @pending_card_handle.observer.clear
      @pending_card_handle = nil
    end

    # A turn that failed (bin/chi exits 1): the error, then how to go on.
    # The Engine saved the failed turn with its prompt, so the session is
    # kept and `chi --resume` takes it up again.
    # @return [Symbol] :turn_failed
    def one_shot_failed(session, error)
      warn "Error: #{@engine.failure_summary(error)}"
      if !@scratch && Session.exist?(session.id)
        warn "chi: the session is kept with your prompt; continue it with: chi --resume #{session.id}"
      end
      :turn_failed
    end

    # A turn the iteration limit cut short: a line on stderr, with how to go
    # on unless the session goes with this run.
    # @return [Symbol] :iteration_limit
    def one_shot_exhausted(session, max_iterations)
      line = "chi: the iteration limit (#{max_iterations}) was reached before the turn finished"
      line += "; continue it with: chi --resume #{session.id}" unless @scratch
      warn line
      :iteration_limit
    end

    # `chi -p "/models" --non-interactive`: the command's output; a refused
    # one fails the run (bin/chi exits 1). The session is saved only when
    # the command changed it. Nobody is there to answer a confirm: a
    # costly /thinking or /reasoning-history applies at once.
    # @return [Symbol, nil] :turn_failed when the command was refused
    def run_one_shot_command(session)
      line = @prompt.strip
      result = begin
        @commands.run(line, confirm: false)
      rescue StandardError => e # degrade-ok: the command's error is its output, and the run fails
        SessionCommands::Result.new(status: :error, output: "#{line.split.first}: #{e.message}", changed: [])
      end
      @surface.commit(result.output) unless result.output.to_s.empty?
      session.save unless Array(result.changed).empty?
      :turn_failed if result.status == :error
    end

    # `chi -p /stats --non-interactive`: why it doesn't run, on stderr.
    # @return [Symbol] :turn_failed
    def refuse_one_shot_ui_command
      name = SessionCommandCatalog.ui_only_entry(@prompt).name
      warn "chi: refused: #{SessionCommandCatalog.ui_only_refusal(name, @resume_session&.id, runner: "--non-interactive")}"
      :turn_failed
    end

    # Ctrl-C in the turn: the Engine kept the prompt and a cancel note in
    # the session (it saves only a failed turn), so save it here: `chi
    # --resume` takes it up again. A scratch session goes in #run's ensure,
    # so there is nothing to keep.
    # @return [Symbol] :interrupted
    def one_shot_interrupted(session)
      return :interrupted if @scratch

      session.save
      warn "chi: canceled (Ctrl-C); the session is kept: continue it with chi --resume #{session.id}"
      :interrupted
    end

    # Delete the scratch session, the last thing the run does.
    def delete_scratch(session)
      @owner_lock&.release
      @owner_lock = nil
      SessionManager.delete_session(session.id)
    rescue StandardError => e # degrade-ok: the line says how to delete it by hand
      warn "Scratch session #{session.id} was not deleted (#{e.message}): chi sessions delete #{session.id}"
    end

    # The session's cards.json and pending_card.json, kept as a worker's
    # Bridge keeps them (it owns the session as a worker would): this run's
    # turn goes on the same turn log, so a card an earlier worker showed keeps
    # its place above the turns after it, and its own cards and notices are
    # saved for the next; an open card with actions is on disk, where
    # `chi web`'s session hub reads it to mark the session as waiting.
    def keep_cards(session)
      path = File.join(Session.session_dir(session.id), Bridge::CardStore::FILE)
      @cards_handle ||= @engine.subscribe(observer: Bridge::CardStore.new(path: path, messages: -> { @engine.session&.messages }))
      keep_pending_card(session)
    end

    # A card a worker that died left isn't open: the file goes before the
    # observer takes over, as Bridge#start does.
    def keep_pending_card(session)
      return if @pending_card_handle

      pending = Bridge::PendingCard.new(Session.session_dir(session.id))
      pending.clear
      @pending_card_handle = @engine.subscribe(observer: pending)
    end

    # A question the session's last owner saved and died with (a worker's):
    # this run owns the session now, so nobody waits on it. Dropped and
    # saved, as the worker does (Worker#drop_dead_question).
    def drop_dead_question(session)
      id = session.drop_dead_question
      return unless id

      Log.info(:turn, "dead_question_dropped", id: id)
      session.save
    end

    # Take the session's OwnerLock for this process's lifetime: the run has
    # its own Engine, so no worker may run the session meanwhile.
    # @raise [SessionBusy] when a worker or another chi owns it
    def claim_session!(session_id)
      session_dir = Session.session_dir(session_id)
      @owner_lock = OwnerLock.acquire(session_dir, kind: "tui", wait: 1.0)
      return @owner_lock if @owner_lock

      owner = OwnerLock.owner(session_dir)
      where = owner&.tui? ? "another chi" : "a `chi web` worker"
      raise SessionBusy, "Session #{session_id} is open in #{where} (pid #{owner&.pid || "unknown"}). " \
                         "Close it there first."
    end

    # Which session this is, and a resumed one's recap, before the turn: on
    # stderr, as stdout is the answer's alone (a script or a parent agent
    # reads it).
    def banner_for(session)
      if @resume_session
        banner("Resumed session: #{session.id}")
        saved = @engine.saved_recap
        banner(recap_block(saved[:text], turns_since: saved[:turns_since], at: saved[:created_at])) if saved
      elsif @scratch
        banner("Scratch session: nothing is kept, it is deleted when you leave.")
      else
        banner("Session: #{session.id}")
      end
    end

    def banner(text)
      $stderr.puts(text)
      $stderr.flush
    end

    # A fresh session reaches the disk before its first turn: a tool in that
    # turn reads it from there (delegate loads its parent to start a child,
    # "no session …" otherwise).
    def save_before_first_turn(session)
      session.save unless Session.exist?(session.id)
    end

    # A candidate the prompt mentions (ContextCandidates) is attached and
    # fetched, and its note added before the turn, as a worker does. Ctrl-C
    # stops the wait, not the turn.
    def attach_mentioned_context(session, prompt)
      ContextCandidates.before_turn(session: session, prompt: prompt, author: nil, state_dir: Session.default_state_dir)
      ContextCandidates.deliver_notes(@engine, session, state_dir: Session.default_state_dir)
    rescue Interrupt
      nil
    rescue StandardError => e
      Log.warn(:context, "candidates_one_shot_failed", error: e.class.name, msg: e.message.to_s[0, 200])
    end

    # The toolkit flags are a new session's: a resumed one keeps its own
    # toolkit (as attached mode says it, AttachLauncher).
    def warn_toolkit_flags_ignored(session)
      return if @toolkit_flags.empty?

      names = @toolkit_flags.size > 1 ? "#{@toolkit_flags[0..-2].join(", ")} and #{@toolkit_flags.last}" : @toolkit_flags.first
      warn "(#{names} #{@toolkit_flags.size == 1 ? "applies" : "apply"} to a new session; #{session.id} keeps its own)"
    end

    # No one is here to ask (as for an approval or a hook's question): the
    # question is dismissed at once, as an empty answer would be, and the
    # model finishes its reply. Never a read of stdin: a pipe its writer
    # keeps open would block it forever. Its one line goes to stderr. The
    # model is told no one could answer (QuestionDesk::UNANSWERABLE_NOTE),
    # not that the user dismissed it.
    def dismiss_unaskable_question(prompt)
      Degrade.call(:turn, "question_dismiss_failed") { @engine.cancel_question(QuestionDesk::UNANSWERABLE_REASON) }
      banner(prompt.summary(QuestionPrompt::UNANSWERABLE_TEXT, paint: method(:paint)))
      false
    end
  end
end
