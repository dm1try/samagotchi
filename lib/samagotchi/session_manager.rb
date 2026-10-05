# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "securerandom"
require "rbconfig"
require_relative "atomic_file"
require_relative "config"

require_relative "session"
require_relative "session_inbox"
require_relative "session_metrics"
require_relative "utf8_default"
require_relative "turn_note"
require_relative "owner_lock"
require_relative "bridge_client"
require_relative "worker_sidecar"
require_relative "log"
require_relative "log_path"
require_relative "model_profile"
require_relative "installed_gem"
require_relative "installed_versions"
require_relative "recap_store"
require_relative "archive_store"
require_relative "continue_offer"
require_relative "image_store"
require_relative "plugin_session_state"
require_relative "context_sources"
require_relative "terminal_ui"

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

  class SessionManager
    # Origin of the synthetic turn queued when reminders are due.
    REMINDER_CLIENT_ID = "system:reminder"

    # Raised when the interactive TUI owns the session: it runs its own Engine
    # and reads no input files, so a worker must not be spawned or signalled.
    class OwnedByTUI < StandardError
      # @return [String] the session the REPL owns (a delegate's, when an
      #   archive met one)
      attr_reader :session_id

      def initialize(session_id)
        @session_id = session_id
        super("session #{session_id} is owned by an interactive TUI")
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
    # @param title [String, nil] what the lists show before the first turn
    #   (the prompt's preview by default, else the seed's first user message)
    # @return [Session] with #seed_images_dropped: refs whose file was gone,
    #   and #model_warning: an id its host's saved list doesn't have
    def self.spawn_session(prompt:, mode: "assist", working_directory: nil, model_name: nil, state_dir: nil,
                           memories: [], muted_memories: [], parent_id: nil, messages: [], images_from: nil,
                           title: nil, delegate: false)
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
        delegate: delegate
      )
      session.model_warning = model_warning
      # With no prompt there is no first turn to run (an attaching UI sends
      # the prompts), so the session starts idle.
      session.status = prompt.to_s.strip.empty? ? Session::STATUS_IDLE : Session::STATUS_RUNNING
      session.last_prompt = prompt
      # The worker takes last_prompt and clears it, and messages are saved at
      # the turn's end: until then this is the only preview a list has.
      session.first_preview = Session.preview_of(title.to_s.strip.empty? ? prompt : title)
      session_dir = Session.session_dir(session.id, state_dir: sd)
      unless session.messages.empty?
        session.messages, dropped = ImageStore.copy_refs(session.messages, from: images_from, to: session_dir)
        session.seed_images_dropped = dropped
      end
      setup_session_directory(session_dir, session, state_dir: sd)
      spawn_worker_for_session(session, state_dir: sd)
      session
    end

    # Build the opts hash passed to Process.spawn for a forked worker. The
    # child inherits this process's ENV and reads config.yml itself (as it
    # is when the worker starts); opts[:env] adds to it (merged, not
    # replaced) what it can't read there: this `chi`'s CLI settings
    # (Config.cli_env), the hosts and the absolute log file. It unsets
    # SAMAGOTCHI_GUARDRAILS_*. XDG_CONFIG_HOME passes: whoever starts or
    # wakes the worker picks which config.yml it reads (docs/guardrails.md).
    private_class_method def self.spawn_options(session)
      # Own process group: workers outlive `chi web`, and a Ctrl-C in its
      # terminal must not reach them.
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
      # Propagate hosts config for multi-host routing
      begin
        require_relative "config"
        hosts_json = ConfigFile.hosts_json_for_env
        child_env["SAMAGOTCHI_HOSTS_JSON"] = hosts_json if hosts_json && !hosts_json.strip.empty?
      rescue StandardError
        nil
      end
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
      # The spawner's environment must not reach the worker's guardrails (a
      # parent agent starting or waking a session): Process.spawn unsets a
      # key mapped to nil. config.yml no longer reads them; this keeps an
      # older or future env-exposed one out as well.
      ENV.each_key { |key| child_env[key] = nil if key.start_with?(GUARDRAILS_ENV_PREFIX) }
      # A smoke's fake "newest installed" is for this process's notices only.
      child_env[InstalledVersions::ENV_KEY] = nil
      # A gem-mode worker activates the newest installed chi itself: under
      # `bundle exec` (a Gemfile that has samagotchi) Bundler's RUBYOPT would
      # hold it to the bundle's version, and its badge would never clear.
      child_env.merge!(unbundled_env_changes) if InstalledGem.spec
      opts[:env] = child_env unless child_env.empty?
      opts
    end

    # What Bundler changed in ENV (RUBYOPT, BUNDLE_*), mapped back to the
    # values from before it (nil: unset); {} outside Bundler.
    private_class_method def self.unbundled_env_changes(env = ENV.to_h)
      return {} unless defined?(::Bundler) && ::Bundler.respond_to?(:unbundled_env)

      clean = ::Bundler.unbundled_env
      (env.keys | clean.keys).each_with_object({}) { |key, changes| changes[key] = clean[key] unless clean[key] == env[key] }
    end

    GUARDRAILS_ENV_PREFIX = "SAMAGOTCHI_GUARDRAILS_"

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
    #   updated_at:, status:, live:, busy:, owner:, recap:, parent_id:,
    #   parent_short_id:, archived:, scratch:, test_run:, waiting:, waiting_id:, stopped_by:}; busy = live with
    #   a turn running, recap = the saved recap's first sentence, project =
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
      summaries = Session.list(state_dir: sd, sort: sort || "updated_at", order: order || "desc", project_root: project_root,
                               include_archived: include_archived).lazy
                         .reject { |s| (!include_tests && s.test_run) || s.id == exclude }
                         .select { |s| root.nil? || in_folder?(s.working_directory, root) }
                         .filter_map do |s|
        owner = session_owner(s.id, state_dir: sd)
        owned = !!owner&.worker?
        next if live && !owned

        { id: s.id, short_id: s.id[0, 8], desc: summary_desc(s), preview: summary_preview(s), cwd: s.working_directory,
          project: s.project_root(cache: roots), updated_at: s.updated_at, status: s.status, live: owned, busy: owned && s.status == Session::STATUS_RUNNING,
          owner: owner&.kind, recap: RecapStore.preview(Session.session_dir(s.id, state_dir: sd)),
          ctx_pct: SessionMetrics.saved_context_pct(Session.session_dir(s.id, state_dir: sd))&.round(1),
          parent_id: s.parent_id, parent_short_id: s.parent_id&.[](0, 8), archived: s.archived,
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
    def self.archive_session(id_or_prefix, state_dir: nil, wait: 5)
      sd = state_dir || Session.default_state_dir
      id = archive_target(id_or_prefix, sd)
      raise ArchiveRefused.new(id, :scratch) if Session.load(id, state_dir: sd).scratch

      tree = [id, *descendant_ids(id, sd)]
      owners = tree.to_h { |sid| [sid, session_owner(sid, state_dir: sd)] }
      tree.each do |sid|
        refusal = archive_refusal(sid, owners[sid], sd)
        raise ArchiveRefused.new(id, sid == id ? refusal : :"#{refusal}_child", busy_id: sid) if refusal
      end

      stopped = tree.select { |sid| owners[sid] }
      stopped.each { |sid| stop_session(sid, state_dir: sd, wait: wait) }
      archived, discarded = tree.partition { |sid| ArchiveStore.archive(sid, state_dir: sd) }
      { id: id, archived: archived, stopped: stopped, discarded: discarded }
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
    # further today, a plugin's fork may.
    private_class_method def self.descendant_ids(id, state_dir)
      seen = [id]
      queue = [id]
      until queue.empty?
        children_of(queue.shift, state_dir: state_dir).each do |child|
          next if seen.include?(child[:id])

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

    private_class_method def self.summary_preview(session)
      cut(summary_text(session), SUMMARY_PREVIEW_LIMIT)
    end

    # A session as one line of text for the lists: its last prompt, else the
    # first message it was started with (a session command like `/model x`,
    # or a first turn not saved yet).
    def self.summary_text(session)
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

      Session.clear_stopped(session.id, state_dir: sd)
      session.status = Session::STATUS_IDLE
      session.save(state_dir: sd)
      spawn_worker_for_session(session, state_dir: sd)
      session
    end

    # A delegate child rang a parent that has no worker (ChildRing): start
    # one, which runs a turn for the report. Not for a parent that is gone,
    # stopped, archived, a scratch session, or open in a chi REPL: the ring
    # waits on disk for whoever runs it next (#resume_session itself would
    # clear the stop). A stop landing between the check and the resume is
    # a small window, left as is.
    # @return [Symbol] :woken, or why not (:gone, :stopped, :archived,
    #   :scratch, :owned)
    def self.wake_for_report(session_id, state_dir: nil)
      sd = state_dir || Session.default_state_dir
      return :gone unless Session.exist?(session_id, state_dir: sd)
      return :owned if session_owner(session_id, state_dir: sd)
      return :stopped if Session.stopped_marker?(session_id, state_dir: sd)
      return :archived if ArchiveStore.archived?(Session.session_dir(session_id, state_dir: sd))

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
    WORKER_START_GRACE = 30.0

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
    # or :failed (the worker answered something else).
    class RestartRefused < StandardError
      attr_reader :session_id, :reason, :version

      def initialize(session_id, reason, version: nil)
        @session_id = session_id
        @reason = reason.to_sym
        @version = version
        super(RestartRefused.words(session_id, @reason, version))
      end

      HOLDS = {
        starting: "its worker is still starting",
        turn_running: "a turn is running",
        input_queued: "a prompt is queued",
        continue_offered: "the step-limit question waits for an answer",
        question_pending: "a question or approval waits for an answer",
        reminders: "it has reminders, which a restart would drop",
        command_running: "a /btw (or another command) is still running",
        relays_open: "a delegate's approval relayed here is open or just answered",
        background_tasks: "background tasks it started are still running"
      }.freeze

      # What the CLI and the web say.
      def self.words(session_id, reason, version = nil)
        case reason
        when :not_running
          "session #{session_id} has no running worker; the next prompt starts one on the newest chi"
        when :unsupported
          "session #{session_id}'s worker runs chi #{version || "(older)"}, which can't restart: " \
            "chi sessions stop #{session_id}, then any prompt starts it on the newest chi"
        when :failed then "session #{session_id}'s worker didn't take the restart"
        else "not now: #{HOLDS.fetch(reason, reason.to_s.tr("_", " "))}"
        end
      end
    end

    # What a restart did: the worker's version before and after (nil when
    # the new worker hadn't published its Bridge within the wait).
    Restarted = Struct.new(:session_id, :from_version, :version, keyword_init: true)

    RESTART_WAIT = 10.0

    # Hand a session to a new worker on the newest chi installed: ask its
    # worker (POST /exit restart: true), which leaves only when nothing would
    # be lost and starts its successor (Worker#exit_request), then wait up to
    # +wait+ seconds for the successor's Bridge. Web tabs and attached
    # terminals reconnect to it.
    # @return [Restarted]
    # @raise [OwnedByTUI] a chi REPL owns the session
    # @raise [RestartRefused]
    # @raise [ArgumentError] no such session
    def self.restart_session(session_id, state_dir: nil, wait: RESTART_WAIT, client_id: "cli:restart")
      sd = state_dir || Session.default_state_dir
      Session.load(session_id, state_dir: sd) # ArgumentError for none
      owner = refuse_tui!(session_id, state_dir: sd)
      dir = Session.session_dir(session_id, state_dir: sd)
      sidecar = owner&.worker? && WorkerSidecar.live(dir, unlink: false)
      raise RestartRefused.new(session_id, :not_running) unless sidecar
      unless sidecar.features.include?("restart")
        raise RestartRefused.new(session_id, :unsupported, version: sidecar.version)
      end

      reply = BridgeClient.new(session_id: session_id, port: sidecar.port).request_exit(client_id: client_id, restart: true)
      raise RestartRefused.new(session_id, reply.json&.fetch("reason", nil) || :failed) if reply.status == 409
      raise RestartRefused.new(session_id, :failed) unless reply.status == 200

      Log.info(:worker, "restart", sid: session_id, from: sidecar.version, by: client_id)
      fresh = BridgeClient.poll(wait, interval: 0.1) do
        found = WorkerSidecar.live(dir, unlink: false)
        found if found && found.started_at != sidecar.started_at
      end
      Restarted.new(session_id: session_id, from_version: sidecar.version, version: fresh&.version)
    end

    # Stop a session by sending TERM to its process.
    # With +wait+ (seconds), also wait for the owner to let go of the session,
    # so a resume right after spawns a fresh worker instead of finding the
    # dying one.
    # A turn still running is canceled first (STOP_CANCEL_WAIT), as the
    # web's Cancel does: its Engine saves the prompt, which the TERM alone
    # would lose with the worker.
    # @return [Boolean, nil] with +wait+: whether the owner was gone in time
    # @raise [OwnedByTUI] when the interactive TUI owns the session
    def self.stop_session(session_id, state_dir: nil, wait: nil)
      sd = state_dir || Session.default_state_dir
      owner = refuse_tui!(session_id, state_dir: sd)

      cancel_running_turn(session_id, state_dir: sd)
      # Mark first: a worker that has not taken the lock yet sees it and exits.
      Session.mark_stopped(session_id, state_dir: sd)
      pid = owner&.pid.to_i
      begin
        Process.kill("TERM", pid) if pid && pid > 0
      rescue Errno::ESRCH
        nil # already exited
      end
      wait_for_owner_release(session_id, timeout: wait, state_dir: sd) if wait
    end

    STOP_CANCEL_WAIT = 3.0

    # Cancel the session's running turn over its Bridge and wait (up to
    # STOP_CANCEL_WAIT) for the worker to save it. Best effort: without a
    # live Bridge, or when it doesn't answer, the stop goes on as before.
    private_class_method def self.cancel_running_turn(session_id, state_dir:)
      return unless Session.load(session_id, state_dir: state_dir).status == Session::STATUS_RUNNING

      client = BridgeClient.discover(session_id, session_dir: Session.session_dir(session_id, state_dir: state_dir))
      return unless client && client.cancel(reason: "user").status == 202

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
    EMPTY_SKELETON_FILES = ["pid", "owner.lock", WorkerSidecar::FILE, "analytics.json"].freeze
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
        elsif name == "analytics.json"
          Array(JSON.parse(File.read(path))["turn_records"]).empty?
        # Cards and notices from before any turn (Bridge::CardStore).
        elsif name == "cards.json"
          JSON.parse(File.read(path))["turns"].to_i.zero?
        else
          EMPTY_SKELETON_FILES.include?(name)
        end
      end
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
    def self.delete_session(id_or_prefix, state_dir: nil, stop: false, wait: 10)
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
    # A stopped session's worker exits 0 and a crashed one 1, there.
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
      # Kept in a class ivar so the lock's File lives as long as the worker.
      @owner_lock = OwnerLock.acquire(session_dir, kind: "worker", wait: owner_wait)
      exit(0) unless @owner_lock
      # Set by the boot string when the newest installed chi didn't load.
      fallback = ENV.delete(BOOT_FALLBACK_ENV)
      Log.info(:worker, "start", cwd: Dir.pwd, version: VERSION)
      Log.warn(:worker, "boot_fallback", version: VERSION, error: fallback) if fallback
      worker = Worker.new(session_id: session_id, state_dir: sd, session_dir: session_dir,
                          idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
      result = begin
        worker.run
      rescue StandardError, ScriptError => e
        # The worker's stderr is /dev/null: the log is the only trace.
        Log.exception(:worker, "crashed", e)
        raise
      ensure
        @owner_lock.release
      end
      Log.info(:worker, "stop", reason: result)
      # A stopped session is left as it is: no resume for input that came
      # in, no discard.
      exit(0) if result == :stopped
      exit(1) if result == :crashed
      # Only after the release: a writer that still saw this worker as the
      # owner may have queued input since the last check. Either it finds no
      # owner after its write and wakes one, or this finds its input.
      # A restart starts its successor here, on the newest chi installed
      # (worker_command), once this one's lock is free.
      # Delegate reports that rang while it left wake one too.
      if result == :restart ||
         (%i[idle_exit exit_requested].include?(result) &&
          (!SessionInbox.find_new_input_files(session_dir).empty? || worker.wake_due?))
        resume_session(session_id, state_dir: sd)
      elsif worker.discard?
        discard_left_session(session_id, state_dir: sd, default_model: worker.default_model)
      end
      result
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

    def self.worker_command(session_id, state_dir:, gem_spec: InstalledGem.spec)
      boot = "require 'samagotchi/session_manager'; " \
             "Samagotchi::SessionManager.run_session_loop('#{session_id}', state_dir: #{state_dir.inspect})"
      return [RbConfig.ruby, "-I", File.expand_path("..", __dir__), "-e", boot] unless gem_spec

      activate = "begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                 "ENV['#{BOOT_FALLBACK_ENV}'] = e.message; gem 'samagotchi', '= #{gem_spec.version}'; end"
      [RbConfig.ruby, "-e", "#{activate}; #{boot}"]
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
                          exit_discards: nil)
      require_relative "bridge"
      Samagotchi::Bridge.new(
        engine: engine, state_dir: state_dir, session_id: session_id, input_format: SessionInbox::INPUT_FORMAT,
        on_input: on_input, on_command: on_command, on_exit_request: on_exit_request, exit_discards: exit_discards
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
    # @param images [Array<Hash>] image refs ({file:, name:}) in the
    #   session's images/
    # @return [String, false] the input file's path, or false.
    def self.write_turn_input(session_id, prompt:, client_id: nil, enqueued_id: nil, no_interrupt: false, state_dir: nil,
                              images: [])
      session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
      SessionInbox.write_input(session_dir, prompt: prompt, client_id: client_id, enqueued_id: enqueued_id,
                                            no_interrupt: no_interrupt, images: images)
    end

    # How long a turn waits for the Bridge of a worker a resume just spawned.
    TURN_BRIDGE_WAIT = 5.0

    # Hand a user message to the session the way a UI does, for the web
    # composer and `chi send` alike: wakes the worker when none runs, posts
    # through its Bridge so every live UI sees :turn_enqueued, and falls back
    # to the input file when the Bridge is gone (a worker closing it on idle
    # exit). Race-safe against a TUI taking the session, or the worker
    # exiting, between the resume and the write.
    # @param images [Array<Hash>] refs ({file:, name:}) already in images/
    # @param manager [#resume_session, #write_turn_input] this class, or a
    #   stand-in (the web's specs); #session_owner is optional
    # @param bridge [#call, nil] returns the BridgeClient or nil; defaults to
    #   the session's sidecar, waiting TURN_BRIDGE_WAIT for a new worker's
    # @return [Hash] {status: :accepted, ack: Hash} (the Bridge's reply, or
    #   {status:, enqueued_id:, session_id:} for a file), {status: :refused,
    #   code:, ack:} when the Bridge refused the images, {status: :timeout,
    #   ack:} when it took the request but never answered (no file then), or
    #   {status: :failed} when the input file couldn't be written
    # @raise [OwnedByTUI] a chi REPL owns the session
    # @raise [ArgumentError] no such session
    def self.deliver_turn(session_id, prompt:, client_id: nil, images: [], state_dir: nil, manager: self, bridge: nil)
      session_dir = Session.session_dir(session_id, state_dir: state_dir || Session.default_state_dir)
      bridge ||= -> { BridgeClient.wait_for(session_id, session_dir: session_dir, timeout: TURN_BRIDGE_WAIT) }
      manager.resume_session(session_id, state_dir: state_dir)
      if (client = bridge.call)
        begin
          options = { prompt: prompt, client_id: client_id }
          options[:images] = images unless images.empty?
          reply = client.post_turn(**options)
          ack = reply.json
          return { status: :accepted, ack: ack } if reply.status == 202 && ack.is_a?(Hash)
          if ack.is_a?(Hash) && ack["error"] == "bad_images"
            return { status: :refused, code: reply.status, ack: ack }
          end
          # Read after its deadline and dropped: a file would run it after all.
          return turn_timeout if ack.is_a?(Hash) && ack["error"] == "deadline_passed"
        rescue Errno::ETIMEDOUT
          # The Bridge drops a turn it reads after the request's deadline
          # (BridgeClient#post_turn), so a worker that wakes later won't run
          # it; a file would.
          return turn_timeout
        rescue SystemCallError, IOError
          nil # the worker closed its Bridge on the way out: queue the file
        end
      end
      enqueued_id = SecureRandom.uuid
      input = { prompt: prompt, client_id: client_id, enqueued_id: enqueued_id, state_dir: state_dir }
      input[:images] = images unless images.empty?
      path = manager.write_turn_input(session_id, **input)
      return { status: :failed } unless path

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
      { status: :accepted, ack: { status: "accepted", enqueued_id: enqueued_id, session_id: session_id } }
    end

    private_class_method def self.turn_timeout
      { status: :timeout, ack: { "error" => "worker_timeout",
                                 "detail" => "the session's worker did not answer, so the message was not sent" } }
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

    # A worker owns the session now: the one rule for whether a saved
    # pending question waits for anyone (Session#waiting_question's live:).
    # A chi REPL's question is its own (nothing else can answer it), and one
    # a dead worker saved waits for no one.
    # @return [Boolean]
    def self.worker_live?(session_id, state_dir: nil)
      !!session_owner(session_id, state_dir: state_dir)&.worker?
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
