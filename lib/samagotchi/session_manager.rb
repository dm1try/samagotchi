# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "securerandom"
require "rbconfig"
require_relative "chi_home"
require_relative "child_env"
require_relative "client_id"
require_relative "analytics_file"
require_relative "atomic_file"
require_relative "config"
require_relative "delivery"
require_relative "steer"
require_relative "participant_messages"

require_relative "session"
require_relative "session_inbox"
require_relative "session_metrics"
require_relative "llm_context_strategy"
require_relative "session_setup"
require_relative "host_registry"
require_relative "utf8_default"
require_relative "turn_note"
require_relative "owner_lock"
require_relative "process_group"
require_relative "bridge_client"
require_relative "worker_sidecar"
require_relative "worker_link"
require_relative "worker_idle_exit"
require_relative "worker_signals"
require_relative "chi_invocation"
require_relative "log"
require_relative "log_path"
require_relative "paths"
require_relative "model_profile"
require_relative "installed_gem"
require_relative "installed_versions"
require_relative "recap_store"
require_relative "reminder_carry"
require_relative "archive_store"
require_relative "continue_offer"
require_relative "image_store"
require_relative "plugin_session_state"
require_relative "context_sources"
require_relative "session_chain"
require_relative "child_move"
require_relative "tools/task_runtime"

module Samagotchi
  # SessionManager coordinates background session processes.
  #
  # Each session runs in its own forked Ruby process, communicating via
  # file-based IPC in the session directory.
  #
  # The session itself (messages + metadata) is always saved by Session at
  # <sessions dir>/<session_id>.json, for foreground chats too. A sibling
  # directory holds the owner lock (any owner, TUI included) and, for
  # background workers, their IPC files (input/, notes/ and output/ are
  # SessionInbox's):
  #   ~/.local/state/samagotchi/sessions/
  #   ├── <session_id>.json       # the session (Session#save)
  #   └── <session_id>/
  #       ├── owner.lock          # flock held by the session's one owner (OwnerLock)
  #       ├── input/              # clients (web/terminal UI) write messages here
  #       │   └── <timestamp>.json # one file per user message: {prompt, client_id,
  #       │                        # enqueued_id, no_interrupt?, images?}
  #       ├── notes/              # context notes: background text the worker adds to
  #       │   └── <ts>-<rand>.json # the conversation between turns, never a turn
  #       │                        # ({text, source, from_session?, from_cwd?, created_at})
  #       ├── output/             # agent writes responses here
  #       │   └── <timestamp>.txt # one file per agent response
  #       └── bridge.json         # Bridge sidecar (how clients reach the worker)
  # Needed only at call time (run_session_loop); worker.rb requires this file.
  autoload :Worker, File.expand_path("worker", __dir__)
  # session_retention requires this file.
  autoload :SessionRetention, File.expand_path("session_retention", __dir__)
  # session_continue requires this file.
  autoload :SessionContinue, File.expand_path("session_continue", __dir__)
  # Needed only on an archive or a delete (it loads Web::Grants).
  autoload :Participants, File.expand_path("participants", __dir__)

  class SessionManager
    # Raised when the interactive TUI owns the session: it runs its own Engine
    # and reads no input files, so a worker must not be spawned or signalled.
    class OwnedByTUI < StandardError
      # @return [String] the session the REPL owns (a delegate's, when an
      #   archive met one)
      attr_reader :session_id

      def initialize(session_id)
        @session_id = session_id
        super("session #{session_id} is open in a chi REPL; close it there first")
      end
    end

    # A delete that would pull the session from under its live worker.
    # reason: :worker_running (not asked to stop it) or :still_stopping
    # (stopped, but the worker outlived the wait).
    class DeleteRefused < StandardError
      attr_reader :session_id, :reason

      def initialize(session_id, reason)
        @session_id = session_id
        @reason = reason
        super(reason == :still_stopping ? "session #{session_id}'s worker is still shutting down" : "session #{session_id}'s worker is running")
      end
    end

    # An archive that can't happen now: a turn runs in the session or in one
    # of its children (+busy_id+ names which), or it is a scratch session.
    class ArchiveRefused < StandardError
      attr_reader :session_id, :reason, :busy_id

      def initialize(session_id, reason, busy_id: nil)
        @session_id = session_id
        @reason = reason
        @busy_id = busy_id
        super(archive_refused_message)
      end

      private

      def archive_refused_message
        case @reason
        when :scratch then "a scratch session is deleted when you leave; nothing to archive"
        when :busy_child then "its delegate #{@busy_id[0, 8]} is running a turn; wait for it or stop it first"
        when :queued then "a prompt is queued, which a resume would run; let it run first"
        when :queued_child then "its delegate #{@busy_id[0, 8]} has a prompt queued, which a resume would run; let it run first"
        when :offer then "the step-limit question waits for an answer; answer Continue or Stop first"
        when :offer_child then "its delegate #{@busy_id[0, 8]} waits for an answer to its step-limit question; answer it first"
        else "a turn is running; wait for it or cancel it first"
        end
      end
    end

    # Spawn a new background session that processes the given prompt (or,
    # with none, waits idle for input).
    #
    # Returns the session object with its ID. Every worker always starts its
    # per-session Bridge (the single live client transport), so external
    # clients can reach it once the sidecar is published.
    # @param memories [Array<String>] --memory: preloaded into the worker's prompt
    # @param muted_memories [Array<String>] --mute: hidden from the session
    #   (both are session fields, so a respawn keeps them)
    # @param parent_id [String, nil] the session that delegates this one (the
    #   `delegate` tool) or was forked from; a session field too
    # @param messages [Array<Hash>] a conversation to start from (a plugin's
    #   ctx.sessions.fork); its image refs are copied from +images_from+
    # @param images_from [String, nil] the session dir the seed's images are in
    # @param preview [String, nil] what the lists show before the first turn
    #   (the prompt's preview by default, else the seed's first user message)
    # @param title [String, nil] the session's own name (Session#title; a
    #   continue's link inherits its previous link's), saved before the
    #   worker starts: the worker owns the file from then on
    # @param setup [SessionSetup] the session's own settings (chi
    #   --llm-context; a fork and a continue copy their session's; a delegate
    #   child the toolkit its delegate call named); without a toolkit the
    #   session is stored on config's toolkit.default, a delegate child on
    #   toolkit.child (Toolkit.configured)
    # @param continues [String, nil] the session this one continues (a
    #   session field; SessionContinue)
    # @param note [String, nil] a context note the session starts with,
    #   from +note_source+: queued before its worker spawns, so its first
    #   turn sees it
    # @param review [SessionReview, nil] a review session's (ReviewStart; a
    #   continue keeps its previous link's)
    # @param verify_fresh [VerifyFreshOrigin, nil] a Verify fresh child's
    #   requester, rules and claim (VerifyFresh.start)
    # @param before_spawn [#call, nil] (session) runs once the session and
    #   its note are saved, before its worker spawns
    # @return [Session] with #seed_images_dropped: refs whose file was gone,
    #   and #model_warning: an id its host's saved list doesn't have
    def self.spawn_session(prompt:, mode: "assist", working_directory: nil, model_name: nil, state_dir: nil,
                           memories: [], muted_memories: [], parent_id: nil, messages: [], images_from: nil,
                           preview: nil, title: nil, delegate: false, setup: SessionSetup.new, continues: nil, note: nil,
                           note_source: "chi", before_spawn: nil, review: nil, verify_fresh: nil)
      sd = state_dir || Session.default_state_dir
      # The resolved ref is stored (a resumed session keeps its model when an
      # alias is retargeted), with the name as typed beside it. A wrong host
      # refuses here, before anything is saved or spawned; a model id the
      # host's saved list doesn't have (ModelListStore) only warns
      # (#model_warning on the session), as some hosts serve ids they don't
      # list.
      typed = Samagotchi::ModelProfile.check_host!(Samagotchi::ModelProfile.required_model_name(model_name))
      model_warning = Samagotchi::ModelProfile.model_warning(typed)
      ref = ConfigFile.model_ref(typed).ref
      session = Session.new_session(
        mode: mode,
        model_name: ref,
        model_typed: typed == ref ? nil : typed,
        working_directory: working_directory || Dir.pwd,
        preloaded_memory_names: memories,
        muted_memory_names: muted_memories,
        parent_id: parent_id,
        messages: messages,
        delegate: delegate,
        setup: setup,
        continues: continues,
        review: review
      )
      session.toolkit = Toolkit.configured(delegate: delegate) if session.toolkit.nil?
      session.toolkit_origin = setup.toolkit_origin || "default"
      # Saved before the worker starts: its first turn is already the requester's.
      session.verify_fresh = verify_fresh
      session.model_warning = model_warning
      # With no prompt there is no first turn to run (an attaching UI sends
      # the prompts), so the session starts idle.
      session.status = prompt.to_s.strip.empty? ? Session::STATUS_IDLE : Session::STATUS_RUNNING
      session.last_prompt = prompt
      # The first prompt's turn gets an id like a sent message's, so a wait
      # for it can name it (chi send --new --wait, chi web's create): the
      # worker runs it with that origin, and its reply file and last_turn
      # carry the id.
      session.first_turn_id = SecureRandom.uuid unless prompt.to_s.strip.empty?
      # The worker takes last_prompt and clears it, and messages are saved at
      # the turn's end: until then this is the only preview a list has.
      session.first_preview = Session.preview_of(preview.to_s.strip.empty? ? prompt : preview)
      session.title = title
      session_dir = Session.session_dir(session.id, state_dir: sd)
      unless session.messages.empty?
        session.messages, dropped = ImageStore.copy_refs(session.messages, from: images_from, to: session_dir)
        session.seed_images_dropped = dropped
      end
      setup_session_directory(session_dir, session, state_dir: sd)
      SessionInbox.write_note(session.id, text: note, source: note_source, state_dir: sd) if note
      before_spawn&.call(session)
      spawn_worker_for_session(session, state_dir: sd)
      session
    end

    # Start the next link of a chain (SessionContinue.run, which has the
    # rules and raises SessionContinue::Refused).
    def self.continue_session(...) = SessionContinue.run(...)

    # Build the opts hash passed to Process.spawn for a forked worker. The
    # child inherits this process's ENV and reads config.yml itself (as it
    # is when the worker starts); opts[:env] adds to it (merged, not
    # replaced) what it can't read there: this `chi`'s CLI settings
    # (Config.cli_env) and the absolute log file. It unsets
    # what ChildEnv lists (SAMAGOTCHI_GUARDRAILS_*, the session markers).
    # XDG_CONFIG_HOME passes: whoever starts or
    # wakes the worker picks which config.yml it reads (docs/guardrails.md).
    # XDG_STATE_HOME and XDG_CONFIG_HOME, when set, pass made absolute
    # (Paths): the worker starts in the session's directory.
    private_class_method def self.spawn_options(session)
      # Own process group: workers outlive `chi web`, and a Ctrl-C in its
      # terminal must not reach them (the worker then leaves the process
      # tree too: WORKER_DETACH_ENV).
      opts = { out: File::NULL, err: File::NULL, pgroup: true }
      # The worker's tools (and `!cmd`) run in the session's directory, not
      # in the cwd of whoever woke it (`chi web`, another terminal).
      dir = session.working_directory.to_s
      if !dir.empty? && File.directory?(dir)
        opts[:chdir] = dir
      else
        Log.warn(:worker, "cwd_gone", sid: session.id, dir: dir, cwd: Dir.pwd)
      end
      child_env = {}
      # A worker gets no CLI args: --model, --thinking, --log-level and the
      # other flags this chi was started with.
      child_env.merge!(Config.cli_env)
      child_env[ModelProfile::MODEL_FROM_CLI_ENV] = "1" if child_env.key?(ModelProfile::MODEL_ENV)
      # And the spawner's debug log, absolute: a relative log.file would
      # otherwise land in the worker's (the session's) directory.
      log_path = begin LogPath.resolve rescue nil end
      if log_path
        child_env["SAMAGOTCHI_LOG_FILE"] = log_path
      else
        child_env["SAMAGOTCHI_LOG_DISABLE"] = "true"
      end
      # And the spawner's XDG dirs, absolute: a relative XDG_STATE_HOME or
      # XDG_CONFIG_HOME would otherwise be read from the session's directory.
      child_env.merge!(Paths.absolute_xdg)
      # Unset (Process.spawn unsets a key mapped to nil) what no child chi
      # takes from its spawner (ChildEnv): the spawner's guardrails settings
      # (a parent agent starting or waking a session; config.yml no longer
      # reads them, this keeps an older or future env-exposed one out as
      # well); the session markers, a session's own (a worker started from
      # its commands, chi send, is another session: its execute and tasks
      # set its own; nothing else it runs has one); and a smoke's fake
      # "newest installed", for this process's notices only.
      child_env.merge!(ChildEnv.unset)
      # A worker process: run_session_loop traps signals, and leaves this
      # process's tree.
      child_env[WORKER_PROCESS_ENV] = "1"
      child_env[WORKER_DETACH_ENV] = "1"
      # A gem-mode worker activates the newest installed chi itself: under
      # `bundle exec` (a Gemfile that has samagotchi) Bundler's RUBYOPT would
      # hold it to the bundle's version, and its badge would never clear.
      child_env.merge!(ChildEnv.unbundled)
      opts[:env] = child_env unless child_env.empty?
      opts
    end

    # List all sessions, reading status from persisted session.json files.
    # +project_root+: only that project's sessions (nil: every session).
    # +include_archived+: archived sessions too (Session#archived says which).
    def self.list_sessions(state_dir: nil, sort: "updated_at", order: "desc", limit: nil, offset: 0, project_root: nil,
                           include_archived: false)
      Session.list(state_dir: state_dir || Session.default_state_dir, sort: sort, order: order, limit: limit,
                   offset: offset, project_root: project_root, include_archived: include_archived)
    end

    SUMMARY_DESC_LIMIT = 60

    # Short summaries of sessions, newest first: the picker behind
    # `chi sessions list --live --format json|tsv` (chi note from a script)
    # and the agent's list_sessions tool; both pass the current project as
    # +project_root+ unless asked for every project.
    # @param live [Boolean] only sessions a worker owns now (the owner lock,
    #   not the saved status, which a dead worker leaves at "running"); a
    #   REPL-owned session is left out: it can't take notes
    # @param cwd [String, nil] only sessions in this folder or below it
    # @param project_root [String, nil] only this project's sessions
    #   (Session#project_root)
    # @param limit [Integer, nil] taken after the filters
    # @param include_tests [Boolean] false leaves out test runs
    # @param exclude [String, nil] a session id to leave out (the asker)
    # @param include_archived [Boolean] archived sessions too
    # @return [Array<Hash>] {id:, short_id:, desc:, preview:, cwd:, project:,
    #   updated_at:, status:, live:, busy:, owner:, recap:, auto_title:, parent_id:,
    #   parent_short_id:, continues:, continues_short_id:, delegate:, archived:, scratch:, test_run:, waiting:,
    #   waiting_id:, stopped_by:}; busy =
    #   live with a turn running, delegate = started by the delegate tool
    #   (Session#delegate?; a fork has a parent_id but isn't one), continues = the session it continues (the
    #   previous link of its chain, Session#continues), recap = the saved recap's first sentence, auto_title =
    #   the auto title its reply led with (RecapTitle) or nil, project =
    #   Session#project_root, waiting = the kind of question it waits on
    #   ("question", "approval", "hook"; Session#waiting_question) or nil,
    #   waiting_id = that question's id or nil, relayed_to = the parent
    #   whose card it waits in too (the approval relay), its short id, or nil,
    #   stopped_by = the hook that stopped the last turn (Session#stopped_by)
    def self.session_summaries(live: false, cwd: nil, limit: nil, include_tests: true, exclude: nil, state_dir: nil,
                               project_root: nil, include_archived: false, sort: nil, order: nil)
      sd = state_dir || Session.default_state_dir
      root = cwd && folder_path(cwd)
      roots = {}
      # One registry per listing, built only when a row has a saved context
      # to count: its session's llm_context budget is what ctx_pct counts
      # against (SessionMetrics.saved_context_pct).
      budgets = listing_budgets
      summaries = Session.list(state_dir: sd, sort: sort || "updated_at", order: order || "desc", project_root: project_root,
                               include_archived: include_archived).lazy
                         .reject { |s| (!include_tests && s.test_run) || s.id == exclude }
                         .select { |s| root.nil? || in_folder?(s.working_directory, root) }
                         .filter_map do |s|
        owner = session_owner(s.id, state_dir: sd)
        owned = !!owner&.worker?
        next if live && !owned

        { id: s.id, short_id: s.id[0, 8], desc: summary_desc(s), preview: summary_preview(s), title: s.title, cwd: s.working_directory,
          project: s.project_root(cache: roots), updated_at: s.updated_at, status: s.status, live: owned, busy: owned && s.status == Session::STATUS_RUNNING,
          owner: owner&.kind, **recap_fields(Session.session_dir(s.id, state_dir: sd)),
          ctx_pct: SessionMetrics.saved_context_pct(Session.session_dir(s.id, state_dir: sd),
                                                    budget_tokens: -> { budgets.call(s) })&.round(1),
          parent_id: s.parent_id, parent_short_id: s.parent_id&.[](0, 8), continues: s.continues,
          continues_short_id: s.continues&.[](0, 8), delegate: s.delegate?, archived: s.archived,
          scratch: s.scratch, test_run: s.test_run, stopped_by: s.stopped_by }.merge(waiting_fields(s.waiting_question(live: owned)))
      end
      (limit ? summaries.first(limit) : summaries.to_a)
    end

    # waiting: the question's kind, waiting_id: its id (what chi answer
    # --question takes); both nil with none.
    def self.waiting_fields(waiting)
      { waiting: waiting&.dig(:kind), waiting_id: waiting&.dig(:id), relayed_to: waiting&.dig(:relayed_to) }
    end
    private_class_method :waiting_fields

    # One HostRegistry for a whole listing, built on the first row that
    # needs it (a saved context to count) and kept for the rest: resolving a
    # session's llm_context budget reads config.yml (mtime-cached), so not
    # one registry per row.
    # @return [#call] (session) -> the session's budget in tokens or nil
    def self.listing_budgets
      registry = nil
      ->(session) { LLMContextStrategy.session_budget(session, registry: registry ||= HostRegistry.new) }
    end
    private_class_method :listing_budgets

    # The sessions delegated by +parent_id+ (the `delegate` tool), newest
    # first, as .session_summaries rows. A running one (busy) counts against
    # session.max_children. Archived ones too.
    def self.children_of(parent_id, state_dir: nil)
      return [] if parent_id.to_s.empty?

      session_summaries(state_dir: state_dir, include_tests: true, include_archived: true)
        .select { |s| s[:parent_id] == parent_id.to_s }
    end

    # Archive a session and its delegated children (ArchiveStore): hidden
    # from every list, kept by the retention sweep. A live idle worker is
    # stopped first; the marker is written even while it shuts down.
    # @return [Hash] {id:, archived: [ids], stopped: [ids], discarded: [ids]};
    #   discarded: empty sessions their stopping worker deleted
    # @raise [ArgumentError] unknown id (Session::AmbiguousId for a prefix of several)
    # @raise [OwnedByTUI] a chi REPL owns it or one of its children
    # @raise [ArchiveRefused] a turn runs in it or in a child, a prompt is
    #   queued in one (a later resume would run it), a live one offers to
    #   continue past the step limit, or it is a scratch session
    # @param except [Array<String>] descendants left alone with their own
    #   subtrees (delegates a continue moves to the chain's new link)
    def self.archive_session(id_or_prefix, state_dir: nil, wait: 5, except: [])
      sd = state_dir || Session.default_state_dir
      id = archive_target(id_or_prefix, sd)
      tree, owners = archivable!(id, sd, except: except)
      stopped = tree.select { |sid| owners[sid] }
      stopped.each { |sid| stop_session(sid, state_dir: sd, wait: wait) }
      archived, discarded = tree.partition { |sid| ArchiveStore.archive(sid, state_dir: sd) }
      # A restart's reminders hand-off no successor took (the stop above
      # removes a live one's): archived sessions keep no reminders.
      archived.each { |sid| ReminderCarry.remove(Session.session_dir(sid, state_dir: sd)) }
      # D8: an archive ends the review (unarchiving doesn't restore it).
      Participants.end_sessions(archived, by: "archive", state_dir: sd)
      { id: id, archived: archived, stopped: stopped, discarded: discarded }
    end

    # The session and its descendants, with their owners, when they can be
    # archived now (#archive_refusal for each), else the refusal. Public for
    # SessionContinue, which checks before its recap wait.
    # @return [Array(Array<String>, Hash)] the ids, and id => OwnerLock::Owner or nil
    # @raise [ArchiveRefused, OwnedByTUI]
    def self.archivable!(id, state_dir, except: [])
      raise ArchiveRefused.new(id, :scratch) if Session.load(id, state_dir: state_dir).scratch

      tree = [id, *descendant_ids(id, state_dir, except: except)]
      owners = tree.to_h { |sid| [sid, session_owner(sid, state_dir: state_dir)] }
      tree.each do |sid|
        refusal = archive_refusal(sid, owners[sid], state_dir)
        raise ArchiveRefused.new(id, sid == id ? refusal : :"#{refusal}_child", busy_id: sid) if refusal
      end
      [tree, owners]
    end

    # What keeps +sid+ (in an archive's tree) from being archived: :busy (a
    # turn runs), :queued (input/ holds a prompt, which outlives the stop and
    # runs on a resume, live worker or not), :offer (a live worker's continue
    # offer, which the stop would drop), or nil.
    # @raise [OwnedByTUI] a chi REPL owns it
    def self.archive_refusal(sid, owner, state_dir)
      raise OwnedByTUI, sid if owner&.tui?

      session = owner && Session.load(sid, state_dir: state_dir)
      return :busy if session&.status == Session::STATUS_RUNNING
      return :queued unless SessionInbox.find_new_input_files(Session.session_dir(sid, state_dir: state_dir)).empty?

      :offer if session&.waiting_question(live: true)&.dig(:kind) == ContinueOffer::KIND
    end
    private_class_method :archive_refusal

    # Unarchive a session and its delegated children.
    # @return [Hash] {id:, unarchived: [ids that were archived]}
    # @raise [ArgumentError] unknown id
    def self.unarchive_session(id_or_prefix, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      id = archive_target(id_or_prefix, sd)
      unarchived = [id, *descendant_ids(id, sd)].select { |sid| ArchiveStore.unarchive(sid, state_dir: sd) }
      { id: id, unarchived: unarchived }
    end

    private_class_method def self.archive_target(id_or_prefix, state_dir)
      given = id_or_prefix.to_s
      raise ArgumentError, "no session #{given}" unless Session.valid_id?(given)

      id = Session.resolve_id(given, state_dir: state_dir)
      raise ArgumentError, "no session #{given}" unless Session.exist?(id, state_dir: state_dir)

      id
    end

    # Children, their children, …: a delegated session doesn't delegate
    # further today, a plugin's fork may. The walk doesn't enter +except+.
    def self.descendant_ids(id, state_dir, except: [])
      seen = [id]
      queue = [id]
      until queue.empty?
        children_of(queue.shift, state_dir: state_dir).each do |child|
          next if seen.include?(child[:id]) || except.include?(child[:id])

          seen << child[:id]
          queue << child[:id]
        end
      end
      seen.drop(1)
    end

    SUMMARY_PREVIEW_LIMIT = 120

    # "<cwd basename> · <last prompt, or the first preview>", one line.
    private_class_method def self.summary_desc(session)
      desc = [File.basename(session.working_directory.to_s), summary_text(session)].reject(&:empty?).join(" · ")
      cut(desc, SUMMARY_DESC_LIMIT)
    end

    # A session row's recap: and auto_title: (RecapStore.card, one read).
    private_class_method def self.recap_fields(session_dir)
      card = RecapStore.card(session_dir)
      { recap: card.preview, auto_title: card.title }
    end

    private_class_method def self.summary_preview(session)
      cut(summary_text(session), SUMMARY_PREVIEW_LIMIT)
    end

    # A session as one line of text for the lists: its title (/title), else
    # its last prompt, else the first message it was started with (a session
    # command like `/model x`, or a first turn not saved yet).
    def self.summary_text(session)
      return one_line(session.title) unless session.title.to_s.strip.empty?

      one_line(session.last_prompt.to_s.strip.empty? ? session.first_preview.to_s : session.last_prompt.to_s)
    end

    # A prompt as one line for a session list: whitespace collapsed, and a
    # quoted or annotated message (ContextQuote, the web's annotations)
    # without its "> " markers, so the words show.
    def self.one_line(text)
      text.to_s.gsub(/^[ \t]*(?:>[ \t]?)+/, "").gsub(/\s+/, " ").strip
    end

    private_class_method def self.cut(text, limit)
      text.length > limit ? "#{text[0, limit - 1]}…" : text
    end

    private_class_method def self.folder_path(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end

    private_class_method def self.in_folder?(dir, root)
      dir = dir.to_s.chomp("/")
      root = root.chomp("/")
      dir == root || dir.start_with?("#{root}/")
    end

    # The retention sweep (SessionRetention.sweep_if_due), here for the web
    # app and hub, which take this class as their manager.
    def self.retention_sweep_if_due(state_dir: nil) = SessionRetention.sweep_if_due(state_dir: state_dir)

    # Ensure an existing session has a live worker process.
    # Returns the loaded session after state reconciliation.
    # @raise [OwnedByTUI] when the interactive TUI owns the session
    def self.resume_session(session_id, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      session = Session.load(session_id, state_dir: sd)
      return session if refuse_tui!(session.id, state_dir: sd)

      # status is turn state, not liveness: a new worker runs no turn yet,
      # and must not find the session stopped (it would exit): neither the
      # marker nor a status field from before it.
      # One this process just spawned may not hold the lock yet (a slow
      # start, deliver_turn's second resume): it would only lose it.
      return session if still_starting?(session.id, state_dir: sd)
      # A continue moving delegates to it spawns its worker once they are
      # moved; one spawned now (a moved child's ring) would race the move.
      return session if ChildMove.starting?(session.id, state_dir: sd)

      Session.clear_stopped(session.id, state_dir: sd)
      session.status = Session::STATUS_IDLE
      session.save(state_dir: sd)
      spawn_worker_for_session(session, state_dir: sd)
      session
    end

    # A delegate child rang a parent that has no worker (ChildRing): start
    # one, which runs a turn for the report. Not for a parent that is gone,
    # stopped, archived, a scratch session, open in a chi REPL, or a
    # continue's new link still taking its delegates (its own spawn comes):
    # the ring waits on disk for whoever runs it next (#resume_session
    # itself would clear the stop). A stop landing between the check and
    # the resume is a small window, left as is. An archived parent with a
    # later link in its chain wakes that link instead: a ring a moved child
    # wrote just as the continue moved it reaches the new link that way
    # (ChildReports reads its predecessor's rings).
    # @return [Symbol] :woken, or why not (:gone, :stopped, :archived,
    #   :scratch, :owned, :starting)
    def self.wake_for_report(session_id, state_dir: nil, forward: true)
      sd = state_dir || Session.default_state_dir
      return :gone unless Session.exist?(session_id, state_dir: sd)
      return :owned if session_owner(session_id, state_dir: sd)
      return :stopped if Session.stopped_marker?(session_id, state_dir: sd)

      if ArchiveStore.archived?(Session.session_dir(session_id, state_dir: sd))
        following = forward && SessionChain.next_of(session_id, state_dir: sd)
        return following ? wake_for_report(following, state_dir: sd, forward: false) : :archived
      end
      return :starting if ChildMove.starting?(session_id, state_dir: sd)

      session = Session.load(session_id, state_dir: sd)
      return :stopped if session.status == Session::STATUS_STOPPED
      return :scratch if session.scratch

      resume_session(session_id, state_dir: sd)
      Log.info(:worker, "delegate_woke_parent", parent: session_id[0, 8])
      :woken
    rescue OwnedByTUI
      :owned
    end

    # How long after a spawn a resume trusts that worker to take the
    # session, while it runs (and the session wasn't stopped since).
    WORKER_START_GRACE = WorkerLink::START_LIMIT

    @spawns = {}
    @spawns_mutex = Mutex.new

    # A worker this process spawned for the session within
    # WORKER_START_GRACE is still running, and no stop came since.
    private_class_method def self.still_starting?(session_id, state_dir:)
      return false if Session.stopped_marker?(session_id, state_dir: state_dir)

      at, waiter = @spawns_mutex.synchronize { @spawns[[state_dir, session_id]] }
      return false unless at && waiter.respond_to?(:alive?) && waiter.alive?

      Process.clock_gettime(Process::CLOCK_MONOTONIC) - at < WORKER_START_GRACE
    end

    private_class_method def self.note_spawn(session_id, state_dir:, waiter:)
      @spawns_mutex.synchronize do
        @spawns.delete_if { |_, (_, w)| !(w.respond_to?(:alive?) && w.alive?) }
        @spawns[[state_dir, session_id]] = [Process.clock_gettime(Process::CLOCK_MONOTONIC), waiter]
      end
    end

    # Forget the spawns #still_starting? remembers (specs).
    def self.forget_spawns
      @spawns_mutex.synchronize { @spawns.clear }
    end

    # Starter processes are children of chi web, unlike the detached workers
    # they launch; the web restart adopts these pids before replacing itself.
    def self.live_spawn_pids
      @spawns_mutex.synchronize do
        @spawns.delete_if { |_, (_, waiter)| !(waiter.respond_to?(:alive?) && waiter.alive?) }
        @spawns.values.filter_map do |_, waiter|
          waiter.pid if waiter.respond_to?(:pid) && waiter.alive?
        end.uniq.sort
      end
    end

    # Read any new output files from a session directory.
    # Optionally filters to only files newer than `since_time`.
    def self.read_responses(session_id, since_time: nil, state_dir: nil)
      SessionInbox.read_outputs(Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir),
                                since_time: since_time)
    end

    # A restart that can't happen now. reason: :not_running (no live worker:
    # the next prompt starts one on the newest chi anyway), :unsupported (a
    # worker from before restarts, running +version+: stop it instead), a
    # WorkerIdleExit#hold_for_restart hold (:turn_running, :reminders, ...),
    # :fallback_held (disk-visible work blocks an unresponsive-worker restart),
    # :stopped (its worker, +pid+, is SIGSTOPped: neither the ask nor a TERM
    # reaches it until it is continued), or :failed (the worker answered something else or didn't release).
    class RestartRefused < StandardError
      attr_reader :session_id, :reason, :version, :holds, :pid

      def initialize(session_id, reason, version: nil, holds: [], pid: nil, via: ChiInvocation::HERE)
        @session_id = session_id
        @reason = reason.to_sym
        @version = version
        @holds = Array(holds).map(&:to_sym).freeze
        @pid = pid
        super(RestartRefused.words(session_id, @reason, version, @holds, pid: pid, via: via))
      end

      HOLDS = {
        starting: "its worker is still starting",
        turn_running: "a turn is running",
        input_queued: "a prompt is queued",
        continue_offered: "the step-limit question waits for an answer",
        question_pending: "a question or approval waits for an answer",
        # Only a worker from before ReminderCarry still holds a restart for its reminders.
        reminders: "it has reminders, which its worker's older chi can't carry over a restart",
        command_running: "a /btw (or another command) is still running",
        relays_open: "a delegate's approval relayed here is open or just answered",
        background_tasks: "background tasks it started are still running"
      }.merge(WorkerIdleExit::LEAVING_WORDS).freeze

      # What the CLI and the web say.
      def self.words(session_id, reason, version = nil, holds = [], pid: nil, via: ChiInvocation::HERE)
        stop = via.command("sessions stop #{session_id}")
        case reason
        when :stopped
          where = via.remote? ? " on #{via.remote}" : ""
          "session #{session_id}'s worker#{" (pid #{pid})" if pid} is stopped (SIGSTOP or Ctrl-Z) and can't take " \
            "a restart: continue it#{" with `kill -CONT #{pid}`" if pid}#{where}, then restart again"
        when :not_running
          "session #{session_id} has no running worker; the next prompt starts one on the newest chi"
        when :unsupported
          "session #{session_id}'s worker runs chi #{version || "(older)"}, which can't restart: " \
            "#{stop}, then any prompt starts it on the newest chi"
        when :fallback_held
          why = holds.map { |hold| HOLDS.fetch(hold, hold.to_s.tr("_", " ")) }.join("; ")
          "session #{session_id} has disk-visible work that a restart might lose#{": #{why}" unless why.empty?}; " \
            "run `#{stop}`, then any prompt starts it on the newest chi"
        when :failed then "session #{session_id}'s worker didn't take the restart"
        else "not now: #{HOLDS.fetch(reason, reason.to_s.tr("_", " "))}"
        end
      end
    end

    # What a restart did: the worker's version before and after (nil when
    # the new worker hadn't published its Bridge within the wait).
    Restarted = Struct.new(:session_id, :from_version, :version, keyword_init: true)

    RESTART_WAIT = 10.0
    # A TERMed worker writes its recap on leave (an LLM call) while it still
    # holds the lock: STOP_WAIT plus the recap's own wait (SessionContinue::RECAP_WAIT).
    FALLBACK_STOP_WAIT = 40

    # Hand a session to a new worker on the newest chi installed: ask its
    # worker (POST /exit restart: true), which leaves only when nothing would
    # be lost and starts its successor. If the worker cannot be asked, stop
    # it without a stop marker and resume only when disk shows no work to lose.
    # @return [Restarted]
    # @raise [OwnedByTUI] a chi REPL owns the session
    # @raise [RestartRefused]
    # @raise [ArgumentError] no such session
    def self.restart_session(session_id, state_dir: nil, wait: RESTART_WAIT, client_id: ClientId::CLI_RESTART)
      sd = state_dir || Session.default_state_dir
      Session.load(session_id, state_dir: sd) # ArgumentError for none
      owner = refuse_tui!(session_id, state_dir: sd)
      # A stopped worker answers neither the ask (READ_TIMEOUT) nor the
      # fallback's TERM (FALLBACK_STOP_WAIT): say so now, not after ~70 s.
      raise RestartRefused.new(session_id, :stopped, pid: owner.pid) if owner&.worker? && ProcessGroup.stopped?(owner.pid)

      dir = Session.session_dir(session_id, state_dir: sd)
      link = WorkerLink.resolve(dir, unlink: false, owner: owner)
      if link.is_a?(WorkerLink::Skew)
        return restart_fallback(session_id, owner: owner, sidecar: link.sidecar, state_dir: sd, wait: wait, why: :skew)
      end

      if link.is_a?(WorkerLink::Starting)
        return restart_fallback(session_id, owner: owner, sidecar: nil, state_dir: sd, wait: wait, why: :starting_stuck) if link.stuck

        raise RestartRefused.new(session_id, :starting)
      end
      raise RestartRefused.new(session_id, :not_running) unless link.live?

      sidecar = link.sidecar
      unless sidecar.features.include?("restart")
        raise RestartRefused.new(session_id, :unsupported, version: sidecar.version)
      end

      begin
        reply = BridgeClient.for_sidecar(session_id, sidecar).request_exit(client_id: client_id, restart: true)
      rescue SystemCallError, IOError => e
        return restart_fallback(session_id, owner: owner, sidecar: sidecar, state_dir: sd, wait: wait, why: :unreachable,
                                                                        error: e)
      end
      raise RestartRefused.new(session_id, reply.json&.fetch("reason", nil) || :failed) if reply.status == 409
      if reply.secret_refused?
        return restart_fallback(session_id, owner: owner, sidecar: sidecar, state_dir: sd, wait: wait, why: :bridge_secret)
      end
      raise RestartRefused.new(session_id, :failed) unless reply.status == 200

      Log.info(:worker, "restart", sid: session_id, from: sidecar.version, by: client_id)
      fresh = WorkerLink.await(session_id, session_dir: dir, timeout: wait, unlink: false, interval: 0.1,
                               until: ->(live) { live.epoch != sidecar.epoch || live.started_at != sidecar.started_at })
      # Timed out: the last outcome, the old worker's Live too, is no successor.
      changed = fresh.live? && (fresh.epoch != sidecar.epoch || fresh.started_at != sidecar.started_at)
      version = fresh.version if changed
      Restarted.new(session_id: session_id, from_version: sidecar.version, version: version)
    end

    def self.restart_fallback(session_id, owner:, sidecar:, state_dir:, wait:, why:, error: nil)
      Log.info(:worker, "restart_fallback", sid: session_id, why: why, error: error&.class&.name, msg: error&.message)
      dir = Session.session_dir(session_id, state_dir: state_dir)
      session = Session.load(session_id, state_dir: state_dir)
      holds = restart_fallback_holds(session, dir)
      raise RestartRefused.new(session_id, :fallback_held, holds: holds) unless holds.empty?
      raise RestartRefused.new(session_id, :failed, version: sidecar&.version) unless (owner&.pid || 0).to_i.positive?

      # The ask may have taken READ_TIMEOUT: TERM only the owner read at the
      # start; a successor that took the lock meanwhile is awaited, not killed.
      current = session_owner(session_id, state_dir: state_dir)
      if current.nil?
        resume_session(session_id, state_dir: state_dir)
      elsif current.pid == owner.pid && current.started_at == owner.started_at
        begin
          Process.kill("TERM", owner.pid)
        rescue Errno::ESRCH
          nil
        rescue SystemCallError => e
          Log.warn(:worker, "restart_fallback_failed", sid: session_id, why: why, error: e.class.name, msg: e.message)
          raise RestartRefused.new(session_id, :failed, version: sidecar&.version)
        end
        unless wait_for_owner_release(session_id, timeout: FALLBACK_STOP_WAIT, state_dir: state_dir)
          raise RestartRefused.new(session_id, :failed, version: sidecar&.version)
        end

        resume_session(session_id, state_dir: state_dir)
      end
      previous_epoch = sidecar&.epoch
      previous_started_at = sidecar&.started_at
      fresh = WorkerLink.await(session_id, session_dir: dir, timeout: wait, unlink: false, interval: 0.1,
                               until: ->(live) { live.epoch != previous_epoch || live.started_at != previous_started_at })
      changed = fresh.live? && (fresh.epoch != previous_epoch || fresh.started_at != previous_started_at)
      Restarted.new(session_id: session_id, from_version: sidecar&.version, version: (fresh.version if changed))
    end
    private_class_method :restart_fallback

    def self.restart_fallback_holds(session, session_dir)
      holds = []
      holds << :turn_running if session.status == Session::STATUS_RUNNING
      holds << :question_pending if session.pending_question
      holds << :input_queued unless SessionInbox.find_new_input_files(session_dir).empty?
      holds << :background_tasks if running_created_task?(session)
      holds
    end
    private_class_method :restart_fallback_holds

    def self.running_created_task?(session)
      root = session.working_directory.to_s
      return false if root.empty?

      Tools::TaskRuntime.created_ids_in(session.messages).any? do |id|
        next false unless Tools::TaskRuntime::TASK_ID.match?(id)

        path = File.join(root, Tools::TaskRuntime::TASKS_DIR, id, Tools::TaskRuntime::METADATA_FILENAME)
        next false unless File.file?(path)

        Tools::TaskRecord.from_file(JSON.parse(File.read(path)))&.running?
      rescue JSON::ParserError, SystemCallError => e
        Log.warn(:worker, "restart_task_check_failed", sid: session.id, task_id: id,
                                                           error: e.class.name, msg: e.message)
        true
      end
    end
    private_class_method :running_created_task?

    # Stop a session by sending TERM (then CONT, for a stopped one) to its process.
    # With +wait+ (seconds), also wait for the owner to let go of the session,
    # so a resume right after spawns a fresh worker instead of finding the
    # dying one.
    # A turn still running is canceled first (STOP_CANCEL_WAIT), as the
    # web's Cancel does, with reason STOP_CANCEL_REASON: its worker saves it. The TERM stops (and saves)
    # what still runs (WorkerSignals), with a short grace after the marker.
    # @return [Boolean, nil] with +wait+: whether the owner was gone in time
    # @raise [OwnedByTUI] when the interactive TUI owns the session
    def self.stop_session(session_id, state_dir: nil, wait: nil)
      sd = state_dir || Session.default_state_dir
      owner = refuse_tui!(session_id, state_dir: sd)

      cancel_running_turn(session_id, state_dir: sd)
      # Mark first: a worker that has not taken the lock yet sees it and exits.
      Session.mark_stopped(session_id, state_dir: sd)
      # A stop drops the reminders: a restart's hand-off no successor took
      # yet must not bring them back on the next resume.
      ReminderCarry.remove(Session.session_dir(session_id, state_dir: sd))
      pid = owner&.pid.to_i
      begin
        Process.kill("TERM", pid) if pid && pid > 0
      rescue Errno::ESRCH
        nil # already exited
      end
      continue_stopped(pid)
      wait_for_owner_release(session_id, timeout: wait, state_dir: sd) if wait
    end

    # A stopped worker (SIGSTOP, Ctrl-Z) runs its TERM handler only once
    # continued: CONT it after the TERM (as ProcessGroup.stop does), so it
    # leaves now rather than outliving the stop's wait. Best effort: one the
    # TERM ended may be gone already.
    private_class_method def self.continue_stopped(pid)
      Process.kill("CONT", pid) if pid && pid > 0
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    STOP_CANCEL_WAIT = 3.0
    # How long a stop from the CLI (chi sessions stop, delete, a continue's
    # orphan) waits for the worker to let go of the session, here or
    # through chi web (POST …/stop's wait, capped at it).
    STOP_WAIT = 10
    # The cancel reason of a turn a session stop cancels (Bridge::CANCEL_REASONS):
    # not the user's Stop, which only ends the turn ("user").
    STOP_CANCEL_REASON = "session_stopped"

    # Cancel the session's running turn over its Bridge and wait (up to
    # STOP_CANCEL_WAIT) for the worker to save it. Best effort: without a
    # live Bridge, or when it doesn't answer, the stop goes on as before.
    private_class_method def self.cancel_running_turn(session_id, state_dir:)
      return unless Session.load(session_id, state_dir: state_dir).status == Session::STATUS_RUNNING

      client = WorkerLink.client(session_id, session_dir: Session.session_dir(session_id, state_dir: state_dir))
      return unless client && client.cancel(reason: STOP_CANCEL_REASON).status == 202

      BridgeClient.poll(STOP_CANCEL_WAIT) do
        Session.load(session_id, state_dir: state_dir).status != Session::STATUS_RUNNING
      end
    rescue StandardError => e
      Log.info(:worker, "stop_cancel_failed", sid: session_id, error: e.class.name, msg: e.message)
      nil
    end

    # What a session's directory holds before anything happened in it. Any
    # other entry (or a file in one of the EMPTY_DIRS) is something the
    # session keeps. "pid" is the pid file workers wrote until 2026-10-01:
    # nothing writes or reads it now, but a folder from before still has one
    # and is still empty.
    EMPTY_SKELETON_FILES = ["pid", "owner.lock", WorkerLink::FILE, AnalyticsFile::NAME].freeze
    EMPTY_DIRS = [SessionInbox::INPUT_DIR, SessionInbox::NOTES_DIR, "images"].freeze
    EMPTY_SKELETON_DIRS = (EMPTY_DIRS + [SessionInbox::OUTPUT_DIR]).freeze

    # session.keep_empty off: sessions left with nothing in them are deleted
    # (the worker as it exits, the TUI at /exit, the retention sweep).
    def self.discard_empty?
      Samagotchi::Config.get("session.keep_empty") != true
    rescue StandardError
      false
    end

    # Whether a session being left (or found left) is deleted: session.keep_empty
    # is off and nothing happened in it (#empty_session?). The worker as it
    # leaves, the REPL at /exit and the retention sweep all ask this.
    # @param default_model [String, nil] what a new session starts on
    # @param model_name [String, nil] the model its owner runs now (the REPL
    #   keeps /model in its Engine); the saved one is checked either way
    # @param used_memory_names [Array<String>] memory its owner's Engine used
    #   before any save
    # @param unsaved [Session, nil] the REPL's working copy, judged instead
    #   when the session was never saved
    def self.discardable?(session_id, default_model:, state_dir: nil, model_name: default_model, used_memory_names: [],
                          unsaved: nil)
      return false unless discard_empty? && same_model?(model_name, default_model) && Array(used_memory_names).empty?

      sd = state_dir || Session.default_state_dir
      if unsaved && !File.exist?(Session.session_file(session_id, state_dir: sd))
        return no_conversation?(unsaved.messages) && unsaved.last_prompt.to_s.strip.empty? &&
               empty_session_dir?(Session.session_dir(session_id, state_dir: sd))
      end

      empty_session?(session_id, state_dir: sd, default_model: default_model)
    end

    # A session nothing happened in: no conversation, no turn tried (a failed
    # one leaves no messages but a last_prompt and analytics turns), nothing
    # queued or attached, and the model and mode a new session gets. A
    # session prepared for later (/model, --model, a note, an image, memory)
    # is not empty. Anything unreadable or unknown counts as not empty.
    # @param default_model [String, nil] what a new session starts on
    def self.empty_session?(session_id, state_dir: nil, default_model: nil)
      sd = state_dir || Session.default_state_dir
      session = Session.load(session_id, state_dir: sd)
      return false unless no_conversation?(session.messages) && session.pending_question.nil? && session.used_memory_names.empty?
      return false unless session.last_prompt.to_s.strip.empty? && session.first_preview.to_s.strip.empty?
      return false unless session.mode.to_s == "assist" && !default_model.nil? && same_model?(session.model_name, default_model)

      empty_session_dir?(Session.session_dir(session_id, state_dir: sd))
    rescue ArgumentError, SystemCallError, JSON::ParserError
      false
    end

    # Whether two model names resolve to the same ref (ModelRef#ref): a
    # session stores the resolved ref, the default may be an alias.
    def self.same_model?(one, other)
      return true if one.to_s == other.to_s
      return false if one.nil? || other.nil?

      ConfigFile.model_ref(one).ref == ConfigFile.model_ref(other).ref
    rescue StandardError
      false
    end

    # Only the system prompt (the REPL seeds one, a saved session keeps
    # it); a context note is a system message too, but with its kind.
    # A turn note (the tail system message after a failed, cancelled or empty
    # turn) is not a conversation either: a session whose only turn failed
    # before any answer is still empty.
    def self.no_conversation?(messages)
      Array(messages).all? do |msg|
        (msg[:role] || msg["role"]).to_s == "system" &&
          ((msg[:kind] || msg["kind"]).nil? || TurnNote.note?(msg))
      end
    end

    # @return [Boolean] whether a session's directory holds only the skeleton
    def self.empty_session_dir?(dir)
      return true unless Dir.exist?(dir)

      Dir.children(dir).all? do |name|
        path = File.join(dir, name)
        if EMPTY_SKELETON_DIRS.include?(name)
          File.directory?(path) && (!EMPTY_DIRS.include?(name) || Dir.empty?(path))
        elsif name == AnalyticsFile::NAME
          analytics_empty?(path)
        # Cards and notices from before any turn (Bridge::CardStore).
        elsif name == "cards.json"
          cards_empty?(path)
        else
          EMPTY_SKELETON_FILES.include?(name)
        end
      end
    end

    # A folder's analytics.json is empty only when it is a JSON object with
    # an empty turn_records array. Anything unreadable, not JSON, not an
    # object, the wrong type, or turn_records the wrong shape reads as
    # "not empty": a broken analytics keeps the folder instead of crashing
    # the retention sweep (or of a wrong-shape one reading as empty).
    def self.analytics_empty?(path)
      data = read_json(path)
      turns = data.is_a?(Hash) ? data["turn_records"] : nil
      turns.is_a?(Array) && turns.empty?
    end

    # A folder's cards.json is empty only when it is a JSON object whose
    # turns is an integer zero. Anything unreadable, not JSON, not an
    # object, the wrong type, or turns not an integer reads as "not empty":
    # a broken or wrong-shape cards file keeps the folder instead of
    # raising (Array#/Hash#to_i) or reading as empty.
    def self.cards_empty?(path)
      data = read_json(path)
      turns = data.is_a?(Hash) ? data["turns"] : nil
      turns.is_a?(Integer) && turns.zero?
    end

    # A session-dir JSON file's contents, or nil when it is missing,
    # unreadable, not JSON or not an object (mirrors AnalyticsFile#read): a
    # broken file reads as none, so its folder is kept, not deleted.
    def self.read_json(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    # Delete one session: its <id>.json, the whole <id>/ directory
    # (history sidecars, input, output, notes, images) and its attached
    # context (ContextSources: its sources, subscriptions, mute markers). The CLI, the TUI's
    # /exit --delete and the web all come here.
    # @param id_or_prefix [String] a session id or a unique prefix of one
    # @param stop [Boolean] stop a live worker first (waits +wait+ seconds)
    # @return [Hash] {id:, removed: [paths], stopped: whether a worker was stopped}
    # @raise [ArgumentError] unknown id (Session::AmbiguousId for a prefix of several)
    # @raise [OwnedByTUI] a chi REPL owns it (never stopped from here)
    # @raise [DeleteRefused] a worker owns it and +stop+ is false, or it
    #   outlived the wait
    def self.delete_session(id_or_prefix, state_dir: nil, stop: false, wait: STOP_WAIT)
      sd = state_dir || Session.default_state_dir
      given = id_or_prefix.to_s
      # Only a plain id: anything else could name a path outside the state dir.
      raise ArgumentError, "no session #{given}" unless Session.valid_id?(given)

      id = Session.resolve_id(given, state_dir: sd)
      path = Session.session_file(id, state_dir: sd)
      dir = Session.session_dir(id, state_dir: sd)
      raise ArgumentError, "no session #{given}" unless File.exist?(path) || Dir.exist?(dir)

      owner = refuse_tui!(id, state_dir: sd)
      if owner
        raise DeleteRefused.new(id, :worker_running) unless stop
        raise DeleteRefused.new(id, :still_stopping) unless stop_session(id, state_dir: sd, wait: wait)
      end

      removed = []
      if File.exist?(path)
        FileUtils.rm_f(path)
        removed << path
      end
      if Dir.exist?(dir)
        FileUtils.rm_rf(dir)
        removed << dir
      end
      PluginSessionState.remove(id)
      removed.concat(ContextSources.remove_session(id, state_dir: sd))
      Participants.end_sessions([id], by: "delete", state_dir: sd)
      { id: id, removed: removed, stopped: !owner.nil? }
    end

    # @return [Boolean] whether the session had no owner within +timeout+ seconds
    def self.wait_for_owner_release(session_id, timeout:, state_dir:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
      while session_owner(session_id, state_dir: state_dir)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(OwnerLock::RETRY_INTERVAL)
      end
      true
    end

    # Run the session loop inside the forked process.
    # This is the entry point called by Process.spawn.
    #
    # Every worker starts its per-session Bridge (the single live client
    # transport) on a port bound to 127.0.0.1 before the loop and stops it on
    # exit. If the bridge fails to start the worker degrades: turns still flow
    # through the input-dir loop, but there is no live SSE or in-process
    # cancel/answer.
    #
    # The worker first takes the session's OwnerLock; when another owner holds
    # it (a racing resume spawned two workers, or the TUI has the session) it
    # exits quietly.
    #
    # A worker nobody uses returns once session.idle_exit_minutes have passed
    # (see WorkerIdleExit), and one a client asked to exit (Bridge POST /exit)
    # returns as soon as nothing keeps it. The next send wakes a new one.
    # @param idle_exit_minutes [Numeric, nil] nil: session.idle_exit_minutes
    # @param poll_interval [Numeric, nil] seconds between the loop's fallback
    #   ticks (nil: Worker::FALLBACK_TICK_SECONDS); queued turns wake it at once
    # A stopped session's worker exits 0 (a signalled one too) and a
    # crashed one 1, there.
    # @return [Symbol] :idle_exit, :exit_requested or :restart
    def self.run_session_loop(session_id, state_dir: nil, owner_wait: OwnerLock::DEFAULT_WAIT,
                              idle_exit_minutes: nil, poll_interval: nil)
      # A worker inherits chi's locale (LC_ALL=C too): read files as UTF-8.
      Utf8Default.apply!
      sd = state_dir || Session.default_state_dir
      # The spawner passed the file and level through ENV; a worker's stderr
      # is /dev/null, so warnings only reach the file.
      Log.configure(stderr: false)
      Log.session_id = session_id
      session_dir = Session.session_dir(session_id, state_dir: sd)
      # Read (and taken out of ENV, so nothing the worker runs inherits it)
      # before anything else: set by spawn_options for a spawned worker.
      spawned = ENV.delete(WORKER_PROCESS_ENV) == "1"
      # Out of the spawner's process tree before the lock (it records this
      # process's pid) and before any thread starts.
      detach_from_spawner(session_dir) if ENV.delete(WORKER_DETACH_ENV) == "1"
      # Kept in a class ivar so the lock's File lives as long as the worker.
      @owner_lock = OwnerLock.acquire(session_dir, kind: "worker", wait: owner_wait)
      exit(0) unless @owner_lock
      # Set by the boot string when the newest installed chi didn't load.
      fallback = ENV.delete(BOOT_FALLBACK_ENV)
      Log.info(:worker, "start", cwd: Dir.pwd, version: VERSION)
      Log.warn(:worker, "boot_fallback", version: VERSION, error: fallback) if fallback
      # A spawned worker stops its turn on TERM/HUP/INT and saves it; a
      # loop run in-process (specs) traps nothing.
      signals = spawned ? WorkerSignals.new.install! : WorkerSignals::NONE
      worker = Worker.new(session_id: session_id, state_dir: sd, session_dir: session_dir,
                          idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval, signals: signals,
                          owner_lock: @owner_lock)
      result = begin
        worker.run
      rescue StandardError, ScriptError => e
        # The worker's stderr is /dev/null: the log is the only trace.
        Log.exception(:worker, "crashed", e)
        raise
      ensure
        @owner_lock.release
        # A signal from here on ends the process as Ruby's default does.
        signals.restore!
      end
      Log.info(:worker, "stop", reason: result)
      # A stopped session is left as it is: no resume for input that came
      # in, no discard. One whose worker a signal stopped isn't discarded
      # either; input that came in (queued behind the turn it stopped)
      # wakes a new worker, as after an idle exit.
      exit(0) if result == :stopped
      if result == :signal
        resume_session(session_id, state_dir: sd) unless SessionInbox.find_new_input_files(session_dir).empty?
        exit(0)
      end
      exit(1) if result == :crashed
      # Only after the release: a writer that still saw this worker as the
      # owner may have queued input since the last check. Either it finds no
      # owner after its write and wakes one, or this finds its input.
      # A restart starts its successor here, on the newest chi installed
      # (worker_command), once this one's lock is free.
      # Delegate reports that rang while it left wake one too.
      if result == :restart && Session.stopped_marker?(session_id, state_dir: sd)
        # A stop landed as it left: no successor (resume_session would clear
        # the stop), and the reminders go with it.
        ReminderCarry.remove(session_dir)
        Log.info(:worker, "restart_dropped", why: :stopped)
      elsif result == :restart ||
            (%i[idle_exit exit_requested].include?(result) &&
          (!SessionInbox.find_new_input_files(session_dir).empty? || worker.wake_due?))
        resume_session(session_id, state_dir: sd)
      elsif worker.discard?
        discard_left_session(session_id, state_dir: sd, default_model: worker.default_model)
      end
      result
    end

    # A spawned worker leaves its spawner's process tree: a killer that
    # walks the tree by parent pid (a terminal closing, a tool's teardown
    # of a `chi send --wait` it ran in the background) no longer reaches it.
    # This process (the spawner's child, which its Process.detach waits on)
    # forks the worker, which starts a session of its own (setsid: no
    # controlling terminal, no SIGHUP from one) and returns to run the loop;
    # this one waits until the worker holds the session's OwnerLock, or has
    # exited, or WORKER_START_GRACE passed, and exits: the spawner's waiter
    # stays alive exactly while the worker starts (#still_starting?). The
    # worker is reparented to init (launchd), which reaps it.
    private_class_method def self.detach_from_spawner(session_dir)
      worker = Process.fork
      unless worker
        Process.setsid
        return
      end

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WORKER_START_GRACE
      until Process.waitpid(worker, Process::WNOHANG) || OwnerLock.owner(session_dir)&.pid == worker ||
            Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep(OwnerLock::RETRY_INTERVAL)
      end
      Process.exit!(0)
    end

    # Delete a session its worker left empty. Checked again now the lock is
    # free: a note or input may have come in since the worker looked, and a
    # worker woken meanwhile owns it (delete_session refuses). A `chi send`
    # landing between this check and the delete fails with "no session"
    # (a window of an empty session's last moments, left as is).
    private_class_method def self.discard_left_session(session_id, state_dir:, default_model:)
      return unless discardable?(session_id, state_dir: state_dir, default_model: default_model)

      delete_session(session_id, state_dir: state_dir)
      Log.info(:worker, "discarded_empty", sid: session_id)
    rescue DeleteRefused, OwnedByTUI, ArgumentError, SystemCallError => e
      Log.info(:worker, "kept_session", sid: session_id, error: e.class.name, msg: e.message)
    end

    def self.config_idle_exit_minutes
      Samagotchi::Config.get("session.idle_exit_minutes")
    rescue StandardError
      nil
    end

    private_class_method def self.setup_session_directory(session_dir, session, state_dir:)
      FileUtils.mkdir_p(session_dir)
      FileUtils.mkdir_p(File.join(session_dir, SessionInbox::INPUT_DIR))
      FileUtils.mkdir_p(File.join(session_dir, SessionInbox::OUTPUT_DIR))
      session.save(state_dir: state_dir)
    end

    # The worker's command line. Run from an installed gem, the worker
    # activates the newest installed samagotchi (`>= 0.a`, prereleases
    # count), whoever spawns it: an old chi web, chi send or --attach then
    # starts new workers on the newest chi rather than on its own. Activating
    # the gem also makes its dependencies resolve as its gemspec pins them
    # (reline ~> 0.6.3). Should that fail (a broken newest install), the
    # worker falls back to the spawner's own version and logs why.
    #
    # A source checkout (bin/chi, bundle exec; InstalledGem.spec is nil
    # there) keeps the plain -I lib: a worktree's bin/chi spawns its own code.
    #
    # CROSS-VERSION CONTRACT: this boot string, run_session_loop(id,
    # state_dir:), the env keys spawn_options sets and the input/ file
    # format are read by a NEWER chi than the one writing them. Change them
    # only additively (spec/worker_contract_spec.rb).
    BOOT_FALLBACK_ENV = "SAMAGOTCHI_BOOT_FALLBACK"
    # "1" in a worker spawn_options started: it traps signals (WorkerSignals).
    # run_session_loop deletes it from ENV as it reads it.
    WORKER_PROCESS_ENV = "SAMAGOTCHI_WORKER_PROCESS"
    # "1" in a worker spawn_options started: run_session_loop leaves the
    # spawner's process tree first (detach_from_spawner); deleted from ENV
    # as it is read, so an rspec run by the worker's execute never forks.
    WORKER_DETACH_ENV = "SAMAGOTCHI_WORKER_DETACH"

    # The boot string's rescue under a chi home: one line in the spawner's
    # log file (SAMAGOTCHI_LOG_FILE, set by spawn_options), LogLine's shape,
    # then exit. Single-quoted: the #{} run in the worker. SID is replaced.
    # rubocop:disable-next Lint/InterpolationCheck -- the worker interpolates these, not this process
    HOME_BOOT_FAILED = 'rescue LoadError, StandardError => e; f = ENV["SAMAGOTCHI_LOG_FILE"].to_s; begin; ' \
                       'File.open(f, "a") { |io| io.puts(Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%LZ") + ' \
                       '" ERROR worker pid=#{Process.pid} sid=SID boot_failed ruby=#{RbConfig.ruby.inspect} error=" + ' \
                       "e.message.lines.first.to_s.strip.inspect) } unless f.empty?; rescue SystemCallError; end; exit 1"

    def self.worker_command(session_id, state_dir:, gem_spec: InstalledGem.spec,
                            home: ChiHome.current(gem_spec: gem_spec))
      boot = "require 'samagotchi/session_manager'; " \
             "Samagotchi::SessionManager.run_session_loop('#{session_id}', state_dir: #{state_dir.inspect})"
      return [RbConfig.ruby, "-I", File.expand_path("..", __dir__), "-e", boot] unless gem_spec
      return home_worker_command(session_id, state_dir: state_dir, gem_spec: gem_spec, home: home) if home

      activate = "begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                 "ENV['#{BOOT_FALLBACK_ENV}'] = e.message; gem 'samagotchi', '= #{gem_spec.version}'; end"
      [RbConfig.ruby, "-e", "#{activate}; #{boot}"]
    end

    # With a chi home (ChiHome.current, docs/architecture.md "How chi
    # launches itself"): the home's ruby, `Gem.paths` set to its gems in the
    # boot string (no GEM_* in the worker's env), the newest chi there, else
    # the fallback pin (ChiHome.fallback_version). A home that still can't
    # load chi (a broken install) logs HOME_BOOT_FAILED and exits: never a
    # silent spawn timeout.
    private_class_method def self.home_worker_command(session_id, state_dir:, gem_spec:, home:)
      newest = home.newest_version
      if newest && newest < Gem::Version.new(gem_spec.version.to_s)
        ChiHome.warn_once(:older_than_spawner, home: newest.to_s, spawner: gem_spec.version.to_s)
      end
      fallback = ChiHome.fallback_version(home, gem_spec)
      activate = if fallback
                   "begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                     "ENV['#{BOOT_FALLBACK_ENV}'] = e.message; gem 'samagotchi', '= #{fallback}'; end"
                 else
                   "gem 'samagotchi', '>= 0.a'"
                 end
      home.boot_argv(run: "begin; #{activate}; require 'samagotchi/session_manager'; " \
                           "#{HOME_BOOT_FAILED.sub("SID", session_id)}; end; " \
                           "Samagotchi::SessionManager.run_session_loop('#{session_id}', state_dir: #{state_dir.inspect})")
    end

    private_class_method def self.spawn_worker_for_session(session, state_dir:)
      session_dir = Session.session_dir(session.id, state_dir: state_dir)
      FileUtils.mkdir_p(session_dir)
      FileUtils.mkdir_p(File.join(session_dir, SessionInbox::INPUT_DIR))
      FileUtils.mkdir_p(File.join(session_dir, SessionInbox::OUTPUT_DIR))

      opts = spawn_options(session)
      env = opts.delete(:env)
      command = worker_command(session.id, state_dir: state_dir)
      pid = env ? Process.spawn(env, *command, **opts) : Process.spawn(*command, **opts)
      # Reaped when it exits: a long-lived spawner (chi web) keeps no zombies.
      # +pid+ is the worker's starter, which exits once the worker it forked
      # holds the lock (detach_from_spawner): the lock's pid is the worker's.
      note_spawn(session.id, state_dir: state_dir, waiter: Process.detach(pid))
      Log.info(:worker, "spawn", sid: session.id, child_pid: pid)
      pid
    end

    # Start the in-process Bridge transport for this worker. The bridge is
    # the single live client transport, so every worker starts it. Bridge
    # creation happens *before* the loop so the capture observer is in place
    # for the whole session; the caller stops the returned instance on exit
    # (see Worker#run's ensure).
    #
    # @return [Samagotchi::Bridge, nil] nil when the transport failed to start
    #   (the worker degrades: turns still flow through the input-dir loop, but
    #   there is no live SSE or in-process cancel/answer).
    # @param on_input [#call, nil] called after the Bridge queues a turn
    def self.start_bridge(engine:, state_dir:, session_id:, on_input: nil, on_command: nil, on_exit_request: nil,
                          exit_discards: nil, exit_stopped: nil, on_holds: nil, on_holds_stop: nil)
      require_relative "bridge"
      Samagotchi::Bridge.new(
        engine: engine, state_dir: state_dir, session_id: session_id, input_format: SessionInbox::INPUT_FORMAT,
        on_input: on_input, on_command: on_command, on_exit_request: on_exit_request, exit_discards: exit_discards,
        exit_stopped: exit_stopped, on_holds: on_holds, on_holds_stop: on_holds_stop
      ).start
    rescue StandardError => e
      Log.error(:bridge, "start_failed", echo: "Bridge: failed to start for session #{session_id}: #{e.class}: #{e.message}", sid: session_id, error: e.class.name)
      nil
    end

    # Write a user turn into a session's input directory via the same file IPC
    # the worker polls. Reused by the bridge's POST surface so a turn is
    # fire-and-forget and never calls run_turn across the thread/process
    # boundary. The file is JSON carrying the sender's ids.
    # @param client_id [String, nil] the sending UI
    # @param enqueued_id [String, nil] the id its ACK / :turn_enqueued carry
    # @param delivery [String, nil] the wire value: "next_step" (default),
    #   "cut" or "queue"
    # @param images [Array<Hash>] image refs ({file:, name:}) in the
    #   session's images/
    # @return [String, false] the input file's path, or false.
    def self.write_turn_input(session_id, prompt:, client_id: nil, enqueued_id: nil, no_interrupt: false, state_dir: nil,
                              images: [], delivery: nil, author: nil, verify: nil)
      session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
      SessionInbox.write_input(session_dir, prompt: prompt, client_id: client_id, enqueued_id: enqueued_id,
                                            no_interrupt: no_interrupt, images: images, delivery: delivery, author: author, verify: verify)
    end

    # How long a turn waits for the Bridge of a worker a resume just spawned.
    TURN_BRIDGE_WAIT = 5.0

    # What #deliver_turn did with a message.
    # +status+ :accepted; :refused (the Bridge refused it, or a queue would
    # reach a worker that doesn't queue); :timeout (the Bridge took it and
    # never answered); :failed (the input file couldn't be written).
    # +via+ :bridge (the worker's Bridge answered) or :file (the input-file
    # fallback); nil when nothing went in.
    # +ack+ the Bridge's reply body, or the file's {"status", "enqueued_id",
    # "session_id"}: string keys either way, {} for none.
    # +code+ a refusal's HTTP status.
    DeliverResult = Data.define(:status, :via, :ack, :code) do
      def initialize(status:, via: nil, ack: {}, code: nil) = super(status:, via:, ack: ack || {}, code:)

      def accepted? = status == :accepted

      # Sent as an input file (no Bridge): its turn and outcome carry the
      # file's enqueued_id, which a wait follows (chi send --wait).
      def file? = via == :file

      # @return [String, nil] the id the message's turn will carry
      def enqueued_id
        id = ack["enqueued_id"].to_s
        id.empty? ? nil : id
      end

      # Whether the worker took the line as a session command (a POST /turn
      # answered with its command_id).
      def command? = !ack["command_id"].to_s.empty?

      def error = ack["error"]

      def detail = ack["detail"]

      # What the worker applied (a Bridge ack only): the delivery asked for,
      # or next_step for a --queue that found no turn running; nil from the
      # input file or a worker older than delivery.
      def delivery = ack["delivery"]

      # A --cut's outcome ("now", "waits", "off"), nil when nothing was cut.
      def cut = ack["cut"]

      # The steer cut-after seconds, with a cut that waits only.
      def cut_after = ack["cut_after"]
    end

    # Hand a user message to the session the way a UI does, for the web
    # composer and `chi send` alike: wakes the worker when none runs, posts
    # through its Bridge so every live UI sees :turn_enqueued, and falls back
    # to the input file when the Bridge is gone (a worker closing it on idle
    # exit). Race-safe against a TUI taking the session, or the worker
    # exiting, between the resume and the write.
    # @param images [Array<Hash>] refs ({file:, name:}) already in images/
    # @param delivery [String, nil] what the message asks the running turn
    #   for: "next_step" (default), "cut" or "queue"
    # @param no_interrupt [Boolean] the turn runs with the raised iteration
    #   limit (an attached TUI's --no-interrupt), through the Bridge or the
    #   file; sent only when true, so older callees see no new field
    # @param author [String, nil] who wrote it when it isn't the session's
    #   owner (Web::Principal#author: chi web stamps it, never the body);
    #   to the Bridge or the file only when given, so an owner's turn is
    #   sent and saved as before
    # @param pending_limit [Integer, nil] with +author+: how many of their
    #   turns may be running or waiting (the Bridge counts them; with no
    #   worker, their waiting files): :refused 429 too_many_turns past it
    # @param manager [#resume_session, #write_turn_input] this class, or a
    #   stand-in (the web's specs); #session_owner is optional
    # @param bridge [#call, nil] returns the BridgeClient or nil; defaults to
    #   the session's sidecar, waiting TURN_BRIDGE_WAIT for a new worker's
    # @return [DeliverResult] :accepted (via the Bridge or a file),
    #   :refused when the Bridge refused the request (any 4xx with an
    #   error: bad images, a delivery it doesn't run) or a queue would reach
    #   a worker that doesn't queue (no file then: it would steer), :timeout
    #   when it took the request but never answered (no file then), or
    #   :failed when the input file couldn't be written
    # @raise [OwnedByTUI] a chi REPL owns the session
    # @raise [ArgumentError] no such session
    def self.deliver_turn(session_id, prompt:, client_id: nil, images: [], delivery: nil, no_interrupt: false,
                          author: nil, pending_limit: nil, verify: nil, state_dir: nil, manager: self, bridge: nil)
      verify = VerifyAnchor.from(verify)
      session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
      bridge ||= lambda do
        link = WorkerLink.await(session_id, session_dir: session_dir, timeout: TURN_BRIDGE_WAIT)
        link.live? ? link.client(session_id) : nil
      end
      manager.resume_session(session_id, state_dir: state_dir)
      if (client = bridge.call)
        return verify_unavailable if verify && !worker_has?(client, VerifyAnchor::FEATURE)
        # A worker from before queueing (no "delivery" feature) ignores the
        # field or refuses it; either way a file would steer the running turn.
        return queue_unavailable if Delivery.queue?(delivery) && !worker_has?(client, Delivery::QUEUE_FEATURE)
        # A participant's turn only to a worker with the review boundary.
        return review_unavailable if Steer.participant_author?(author) && !worker_has?(client, Delivery::REVIEW_FEATURE)

        begin
          options = { prompt: prompt, client_id: client_id }
          options[:images] = images unless images.empty?
          # An old worker ignores the field: it cuts anyway (its own default).
          options[:delivery] = delivery unless Delivery.next_step?(delivery)
          options[:no_interrupt] = true if no_interrupt
          options[:author] = author if author
          options[:pending_limit] = pending_limit if author && pending_limit
          options[:verify] = verify if verify
          reply = client.post_turn(**options)
          ack = reply.json
          return DeliverResult.new(status: :accepted, via: :bridge, ack: ack) if reply.status == 202 && ack.is_a?(Hash)
          # Read after its deadline and dropped: a file would run it after all.
          return turn_timeout if ack.is_a?(Hash) && ack["error"] == "deadline_passed"
          # Any other 4xx with an error is a refusal (bad images, a delivery
          # it doesn't run, a client bug): a file would bypass it, and a
          # refused queue would steer. A 413 (a body over the Bridge's
          # limit, a big piped chi send) and a 5xx keep the file fallback
          # below, which carries the delivery (a queue too).
          if (400..499).cover?(reply.status) && reply.status != 413 && ack.is_a?(Hash) && ack["error"]
            return DeliverResult.new(status: :refused, via: :bridge, code: reply.status, ack: ack)
          end
        rescue Errno::ETIMEDOUT
          # The Bridge drops a turn it reads after the request's deadline
          # (BridgeClient#post_turn), so a worker that wakes later won't run
          # it; a file would.
          return turn_timeout
        rescue SystemCallError, IOError
          nil # the worker closed its Bridge on the way out: queue the file
        end
      end
      # A participant's file only for a worker started after it: a worker
      # still holding the session with its Bridge gone (exiting) may be an
      # older one, which would run it without the review boundary.
      # (A chi REPL holding it is refused as for anyone, below.)
      if Steer.participant_author?(author) && (holder = delivery_owner(manager, session_id, state_dir)) && !holder.tui?
        return DeliverResult.new(status: :timeout, via: :file,
                                 ack: { "error" => "worker_timeout",
                                        "detail" => "the session's worker is exiting, so the message was not sent; send it again" })
      end
      enqueued_id = SecureRandom.uuid
      input = { prompt: prompt, client_id: client_id, enqueued_id: enqueued_id, state_dir: state_dir }
      input[:images] = images unless images.empty?
      input[:delivery] = delivery unless Delivery.next_step?(delivery)
      input[:no_interrupt] = true if no_interrupt
      input[:author] = author if author
      input[:verify] = verify if verify
      path = participant_queue_lock(session_dir, author && pending_limit) do
        # No worker: the participant's waiting files are all their turns,
        # counted and written under one lock (the Bridge counts under its).
        next :too_many if author && pending_limit && pending_files(session_dir, author) >= pending_limit

        manager.write_turn_input(session_id, **input)
      end
      if path == :too_many
        return DeliverResult.new(status: :refused, code: 429,
                                 ack: { "error" => "too_many_turns", "detail" => ParticipantMessages::TOO_MANY_TURNS })
      end
      return DeliverResult.new(status: :failed) unless path

      owner = delivery_owner(manager, session_id, state_dir)
      # A TUI that took the session between the resume and the write never
      # reads input files; a later worker would replay this one.
      if owner&.tui?
        FileUtils.rm_f(path) if path.is_a?(String)
        raise OwnedByTUI, session_id
      end
      # A worker that idle-exited since the resume never reads it either:
      # wake a new one. (The exiting worker also looks for input it left;
      # one the first resume spawned that is still starting is left be.)
      manager.resume_session(session_id, state_dir: state_dir) if owner.nil?
      DeliverResult.new(status: :accepted, via: :file,
                        ack: { "status" => "accepted", "enqueued_id" => enqueued_id, "session_id" => session_id })
    end

    # Whether the worker +client+ talks to names +feature+: the features of
    # the sidecar the client was made from (the Live link WorkerLink.await
    # found), not a second read of bridge.json.
    private_class_method def self.worker_has?(client, feature) = client.features.include?(feature)

    # The unclaimed input files +author+ wrote.
    PARTICIPANT_QUEUE_LOCK = "participants.lock"

    # The block under the session's participant queue lock (a file lock:
    # chi web's threads, and another chi web), when +locked+; else as is.
    private_class_method def self.participant_queue_lock(session_dir, locked)
      return yield unless locked

      FileUtils.mkdir_p(session_dir)
      File.open(File.join(session_dir, PARTICIPANT_QUEUE_LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    private_class_method def self.pending_files(session_dir, author)
      SessionInbox.find_new_input_files(session_dir).count do |file|
        data = JSON.parse(File.read(file))
        data.is_a?(Hash) && data["author"] == author
      rescue JSON::ParserError, SystemCallError
        false
      end
    end

    private_class_method def self.queue_unavailable
      DeliverResult.new(status: :refused, code: 409, ack: Delivery::QUEUE_UNAVAILABLE)
    end

    private_class_method def self.review_unavailable
      DeliverResult.new(status: :refused, code: 409, ack: Delivery::REVIEW_UNAVAILABLE)
    end

    private_class_method def self.verify_unavailable
      DeliverResult.new(status: :refused, code: 409, ack: VerifyAnchor::UNAVAILABLE)
    end

    private_class_method def self.turn_timeout
      DeliverResult.new(status: :timeout, via: :bridge,
                        ack: { "error" => "worker_timeout",
                               "detail" => "the session's worker did not answer, so the message was not sent" })
    end

    private_class_method def self.delivery_owner(manager, session_id, state_dir)
      manager.session_owner(session_id, state_dir: state_dir)
    rescue StandardError
      nil
    end

    def self.stopped_on_disk?(session_id, state_dir:)
      Session.load(session_id, state_dir: state_dir).status == Session::STATUS_STOPPED
    rescue ArgumentError
      false
    end

    # The session's live owner: the OwnerLock holder. The pid file workers
    # once wrote is never read: a stale one whose pid the OS reused would
    # make a session look owned.
    # @return [OwnerLock::Owner, nil]
    def self.session_owner(session_id, state_dir: nil)
      OwnerLock.owner(Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir))
    end

    # The session's owner (#session_owner), unless it is the interactive
    # TUI, which nothing else may resume, stop or delete.
    # @return [OwnerLock::Owner, nil]
    # @raise [OwnedByTUI]
    def self.refuse_tui!(session_id, state_dir: nil)
      owner = session_owner(session_id, state_dir: state_dir)
      raise OwnedByTUI, session_id if owner&.tui?

      owner
    end
  end
end
