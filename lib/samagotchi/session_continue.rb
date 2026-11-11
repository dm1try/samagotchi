# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require_relative "atomic_file"
require_relative "session"
require_relative "session_setup"
require_relative "session_inbox"
require_relative "session_chain"
require_relative "objectives"
require_relative "child_move"
require_relative "starting_marker"
require_relative "context_move"
require_relative "note_move"
require_relative "archive_store"
require_relative "continue_intent"
require_relative "recap_store"
require_relative "bridge_client"
require_relative "worker_link"
require_relative "model_profile"
require_relative "log"
require_relative "session_manager"

module Samagotchi
  # The next link of a session chain: chi send --new --continues and web
  # Continue → run .run. The archive, spawn, stop and wake it builds on are
  # SessionManager's.
  module SessionContinue
    # A continue that can't happen (#run). reason: :continued
    # (another session continues it already: +ids+ names it), :open_children
    # (open children it can't move to the new link: on an older chi's
    # worker or open in a one-turn chi run; +ids+ names them) or :folder_gone (its
    # folder isn't there).
    class Refused < StandardError
      attr_reader :session_id, :reason, :ids

      def initialize(session_id, reason, ids: [], detail: nil)
        @session_id = session_id
        @reason = reason
        @ids = ids
        super(continue_refused_message(detail))
      end

      private

      def continue_refused_message(detail)
        short = @session_id[0, 8]
        case @reason
        when :continued then "#{short} is continued already, by #{@ids.first[0, 8]}; continue that one (or last:#{short})"
        when :open_children
          "#{short} has delegates still open that can't move to the next link: #{detail}; " \
          "then continue (or wait for them, stop them or archive them)"
        else "#{short}'s folder #{detail} is gone"
        end
      end
    end

    # How long #run waits for the previous link's worker to write its
    # recap (IdleRecap's own request timeout).
    RECAP_WAIT = 30.0
    # In the previous link's folder: one continue of a session at a time.
    LOCK = ContinueIntent::LOCK
    # A durable record in the previous link's folder, written before archive
    # (a send in flight reads it: ContinueIntent.in_flight).
    CONTINUE_INTENT = ContinueIntent::FILE
    # How often a last:<id> continue looks again when another continue
    # moved the chain's end while it waited for the lock.
    TRIES = 3

    # One thing a continue carries from the previous link to the new one.
    # +carry+ names the method run in spawn_session's before_spawn (once the
    # link and its chain note are saved, before its worker spawns): it takes
    # a CarryContext and returns what the step carried, kept in #run's
    # +carried+ under +name+. +undo+ maps an UNDO_PHASES phase to the method
    # (taking an UndoContext) that gives it back when the continue fails;
    # empty when there is nothing to undo (CARRY's comment says why).
    # +store+ is the SessionManager::SESSION_STATE_STORES store it carries.
    CarryStep = Data.define(:name, :store, :carry, :undo)
    # What a carry step works on: the previous link (a Session), the new
    # link's id, the delegates moving (ChildMove::Plan#move).
    CarryContext = Data.define(:previous, :to, :state_dir, :move)
    # What an undo works on: the previous link's id, the failed link (nil in
    # :moved_back, which looks it up itself), the delegates the plan moved,
    # and what the forward carry kept (#run's +carried+, by step name).
    UndoContext = Data.define(:from, :link, :state_dir, :moved, :carried)

    # When a failed continue undoes each step, in time order: :moved_back
    # while the failed link's worker may still run (before
    # #discard_failed_link), :link_stopped once its worker is stopped,
    # :link_unlinked once its session file is gone (out of the chain: a note
    # to the previous link stays there), :link_deleted once its folder is
    # gone. Within a phase, the steps undo in reverse CARRY order.
    UNDO_PHASES = %i[moved_back link_stopped link_unlinked link_deleted].freeze

    # What a continue carries, in order (the forward carry runs them first
    # to last, in the new link's before_spawn). A new per-session store a
    # continue should carry is added here, with its undo.
    CARRY = [
      # Its open delegates (ChildMove): given back to the previous link
      # first, then the rings one rang the link with just before the undo.
      CarryStep.new(name: :children, store: :session_files, carry: :carry_children,
                    undo: { moved_back: :undo_move, link_stopped: :return_rings }),
      # Its movable context too, with a note saying what moved and stayed.
      # No undo: ContextSources.move copies (the previous link keeps its
      # sources), and the link's copies go with its delete (remove_files).
      CarryStep.new(name: :context, store: :context_sources, carry: :carry_context, undo: {}),
      # Its objectives: the list reads as the latest word. No undo: a note
      # written into the link only (NoteMove::CONTINUE_SOURCES: never given
      # back), which goes with its delete.
      CarryStep.new(name: :objectives, store: :session_files, carry: :carry_objectives, undo: {}),
      # Its waiting notes last: the carry above read a pending /objectives
      # edit from them first. They keep their names, so they still sort
      # ahead of the link's own notes. A note sent to the previous link
      # from here on goes to this one (SessionInbox::Head), and a
      # straggler is adopted by its worker (NoteMove.adoption). Given back
      # once the link is out of the chain, and again for a note an older chi
      # wrote after its folder went.
      CarryStep.new(name: :notes, store: :session_files, carry: :carry_notes,
                    undo: { link_unlinked: :give_back_notes, link_deleted: :give_back_strays })
    ].freeze

    # The SessionManager::SESSION_STATE_STORES a continue deliberately
    # leaves with the previous link, and why: every store is in CARRY or here.
    NOT_CARRIED = {
      plugin_session_state: "a bundle's per-session state (ctx.session_dir) stays with the archived link",
      participants: "the archive ends the previous link's review (D8); a continue copies no grants",
      system_one_runs: "System 1's saved runs record the previous link's own turns",
      context_candidates_log: "the candidates log records the previous link's own turns"
    }.freeze

    # The model a new link runs on (#model_for): the name to spawn it with,
    # and why it isn't the previous link's (nil when it is, or was given).
    ModelChoice = Data.define(:model, :warning)
    # What #check! decided before anything changes: the delegates to move
    # (ChildMove::Plan) and the new link's model (ModelChoice).
    Checked = Data.define(:plan, :choice)

    # Repair an interrupted continue before showing sessions or starting
    # another continue. An active continue holds LOCK, so its intent is left
    # alone; after a crash, an unsaved successor means the previous link is
    # unarchived.
    def self.repair_interrupted(state_dir:)
      return unless Dir.exist?(state_dir)

      paths = Dir.glob(File.join(state_dir, "*", CONTINUE_INTENT))
      return if paths.empty?

      sessions = Session.list(state_dir: state_dir, include_archived: true)
      by_id = sessions.to_h { |session| [session.id, session] }
      paths.each do |path|
        id = File.basename(File.dirname(path))
        session = by_id[id]
        if session
          repair_intent(session, state_dir, path, sessions)
        else
          quarantine_intent(path, id, message: "session file could not be loaded")
        end
      end
    end

    # Start the next link of a chain: a new session that continues
    # +id_or_ref+ (Session#continues) in its folder, on its model (the name
    # it was typed as, so an alias holds) and with its own setup (SessionSetup),
    # starting with a context note from chi: the link and the previous
    # link's recap and last answer (SessionChain.note_text), read after the
    # recap wait, so a turn that finished in it counts. +model+, when given, is the
    # new link's model instead; an inherited one whose host can't run it any
    # more (gone, disabled, an alias naming another host) falls back to the
    # default with a warning (#model_for). The previous link is archived
    # first, with its finished delegates (archive_session's rules: a turn
    # running, a prompt queued or the step-limit question refuse; an idle
    # worker is stopped), so a refusal starts nothing. Its open delegates
    # (running, waiting, live, an unreported reply, at any depth below them)
    # move to the new link instead (ChildMove): their reports reach it. So
    # does its movable attached context (ContextMove).
    # Before that its live worker is asked for a recap and given up to
    # +recap_wait+ seconds to write it.
    # One continue of a session at a time (a lock in its folder): a double
    # click finds the first one's link and is refused; a last:<id> one
    # follows the chain to its new end instead.
    # @param id_or_ref [String] an id, a prefix, or last:<id> (SessionChain.resolve)
    # @param prompt [String, nil] its first message (nil: it starts idle)
    # @param preview [String, nil] what the lists show before the first turn;
    #   by default the prompt, else the previous link's preview
    # @param client_id [String, nil] who sends +prompt+ when no person does
    #   (a schedule's chain firing: ClientId.schedule), the first turn's
    #   origin (spawn_session's client_id:)
    # @return [Session] the new link (#model_warning as spawn_session's,
    #   #moved_children: the delegates it took over, #moved_context: the
    #   attached context it took (ContextMove), #opener:
    #   SessionChain.opener_for the previous link)
    # @raise [ArgumentError] no such session (Session::AmbiguousId for a prefix of several)
    # @raise [Refused] continued already, delegates open that can't
    #   move, or its folder is gone
    # @raise [ArchiveRefused, OwnedByTUI] as archive_session
    def self.run(id_or_ref, prompt: nil, preview: nil, model: nil, state_dir: nil, recap_wait: RECAP_WAIT, archive_wait: 5,
                 client_id: nil)
      sd = state_dir || Session.default_state_dir
      repair_interrupted(state_dir: sd)
      TRIES.times do |try|
        id = SessionChain.resolve(id_or_ref, state_dir: sd)
        result = with_lock(id, sd) do
          follow = id_or_ref.to_s.strip.start_with?(SessionChain::LAST_PREFIX) && try < TRIES - 1
          next :moved if follow && SessionChain.next_of(id, state_dir: sd)

          run_locked(id, prompt: prompt, preview: preview, model: model, state_dir: sd, recap_wait: recap_wait,
                         archive_wait: archive_wait, client_id: client_id)
        end
        return result unless result == :moved
      end
    end

    private_class_method def self.with_lock(id, state_dir, &)
      dir = Session.session_dir(id, state_dir: state_dir)
      FileUtils.mkdir_p(dir)
      File.open(File.join(dir, LOCK), File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    private_class_method def self.run_locked(id, prompt:, preview:, model:, state_dir:, recap_wait:, archive_wait:, client_id:)
      previous = Session.load(id, state_dir: state_dir)
      checked = check!(previous, state_dir, model: model)
      plan = checked.plan
      # archive_session's refusals that can be known now, before the wait.
      SessionManager.archivable!(id, state_dir, except: plan.move)
      recap_before_archive(id, state_dir, wait: recap_wait)
      # Again: a turn sent to it during the wait may have delegated (they
      # move too), or a delegate finished.
      plan = move_plan!(id, state_dir)
      already = [id, *SessionManager.descendant_ids(id, state_dir, except: plan.move)].select do |sid|
        ArchiveStore.archived?(Session.session_dir(sid, state_dir: state_dir))
      end
      successor_id = SecureRandom.uuid
      intent_path = continue_intent_path(id, state_dir)
      ContinueIntent.write(intent_path, successor_id: successor_id, previously_archived: already)
      archive = SessionManager.archive_session(id, state_dir: state_dir, wait: archive_wait, except: plan.move)
      archived = archive.archived - already
      ContinueIntent.write(intent_path, successor_id: successor_id, previously_archived: already, archived_ids: archived)
      # What each CARRY step took to the new link, by name.
      carried = {}
      begin
        link = spawn_continuation(previous, prompt: prompt, preview: preview, choice: checked.choice, state_dir: state_dir,
                                  move: plan.move, client_id: client_id, carried: carried, session_id: successor_id)
      rescue StandardError, Interrupt
        # Nothing started: the delegates go back, what this archived goes
        # back to the lists, and a new link saved before its worker failed
        # to spawn goes (left, it would hold the chain: "continued already",
        # last: to it), its notes given back first.
        undo_failed_continue(id, state_dir, moved: plan.move, archived: archived, carried: carried) do
          discard_failed_link(id, state_dir, moved: plan.move, carried: carried)
        end
        FileUtils.rm_f(intent_path)
        raise
      else
        FileUtils.rm_f(intent_path)
        link
      end
    end

    private_class_method def self.continue_intent_path(id, state_dir)
      File.join(Session.session_dir(id, state_dir: state_dir), CONTINUE_INTENT)
    end

    private_class_method def self.repair_intent(session, state_dir, path, sessions)
      lock_path = File.join(Session.session_dir(session.id, state_dir: state_dir), LOCK)
      File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
        next unless lock.flock(File::LOCK_EX | File::LOCK_NB)
        next unless File.file?(path)

        intent = ContinueIntent.read(path)
        successor_path = Session.session_file(intent.successor_id, state_dir: state_dir) if intent.successor_id
        successor = JSON.parse(File.read(successor_path)) if successor_path && File.file?(successor_path)
        unless successor.is_a?(Hash) && successor["continues"] == session.id
          archived = intent.archived_ids || (archived_descendants(session.id, sessions, state_dir) - intent.previously_archived)
          undo_failed_continue(session.id, state_dir, moved: [], archived: archived)
        end
        FileUtils.rm_f(path)
      end
    rescue JSON::ParserError => e
      quarantine_intent(path, session.id, error: e)
    rescue Errno::ENOENT
      nil
    end

    private_class_method def self.quarantine_intent(path, session_id, error: nil, message: nil)
      File.rename(path, "#{path}.bad")
      Log.warn(:worker, "continue_repair_failed", sid: session_id, path: path,
                                                    error: error&.class&.name || "SessionUnavailable",
                                                    msg: (message || error.message).to_s[0, 200])
    rescue Errno::ENOENT
      nil
    end

    private_class_method def self.archived_descendants(id, sessions, state_dir)
      children = sessions.group_by(&:parent_id)
      queue = [id]
      descendants = []
      until queue.empty?
        children.fetch(queue.shift, []).each do |child|
          next if descendants.include?(child.id)

          descendants << child.id
          queue << child.id
        end
      end
      [id, *descendants].select do |session_id|
        ArchiveStore.archived?(Session.session_dir(session_id, state_dir: state_dir))
      end
    end

    private_class_method def self.undo_failed_continue(id, state_dir, moved:, archived:, carried: {})
      undo_carry(:moved_back, UndoContext.new(from: id, link: nil, state_dir: state_dir, moved: moved, carried: carried))
      begin
        yield if block_given?
      ensure
        archived.each { |sid| ArchiveStore.unarchive(sid, state_dir: state_dir) }
        wake_for_rings(id, state_dir) unless moved.empty?
      end
    end

    # The CARRY steps' undos for +phase+ (UNDO_PHASES), in reverse CARRY order.
    private_class_method def self.undo_carry(phase, ctx)
      CARRY.reverse_each do |step|
        method = step.undo[phase]
        send(method, ctx) if method
      end
    end

    # CARRY's forward steps (CarryContext).
    private_class_method def self.carry_children(ctx)
      ChildMove.apply(ctx.move, from: ctx.previous.id, to: ctx.to, state_dir: ctx.state_dir)
    end

    private_class_method def self.carry_context(ctx)
      ContextMove.call(from: ctx.previous.id, to: ctx.to, mode: :continue, state_dir: ctx.state_dir)
    end

    private_class_method def self.carry_objectives(ctx)
      Objectives.carry(ctx.previous, to: ctx.to, state_dir: ctx.state_dir)
    end

    # @return [Array<String>] the names of the notes moved to the link
    private_class_method def self.carry_notes(ctx)
      NoteMove.move(from: ctx.previous.id, to: ctx.to, state_dir: ctx.state_dir)
    end

    # The delegates a failed #run moved, or began to (its
    # intent names them), go back to the previous link.
    private_class_method def self.undo_move(ctx)
      id = ctx.from
      state_dir = ctx.state_dir
      link = SessionChain.next_of(id, state_dir: state_dir) or return
      ids = ChildMove.read_intent(link, state_dir: state_dir)&.ids || ctx.moved
      ChildMove.apply(ids, from: link, to: id, state_dir: state_dir, undo: true)
      ChildMove.clear_intent(link, state_dir: state_dir)
    rescue StandardError => e
      Log.warn(:worker, "continue_undo_move_failed", sid: id, error: e.class.name, msg: e.message)
    end

    # The rings a moved delegate wrote into the failed link just before the
    # undo go back to the previous link.
    private_class_method def self.return_rings(ctx)
      ChildMove.return_rings(from: ctx.link, to: ctx.from, state_dir: ctx.state_dir)
    end

    # The notes the link took (CARRY's :notes), with any sent to it meanwhile.
    private_class_method def self.give_back_notes(ctx)
      NoteMove.give_back(from: ctx.link, to: ctx.from, moved: Array(ctx.carried[:notes]), state_dir: ctx.state_dir)
    end

    # The link a failed #run saved (no other continues +id+:
    # check! made sure under the lock): its worker stopped if one
    # started, then the rings a moved delegate wrote into it just before
    # the undo go back to +id+ (CARRY's :link_stopped undos). Then its
    # session file goes first, so the link is out of the chain (a note to
    # +id+ stays there: SessionInbox::Head) and a writer that resolved it
    # before finds it gone, then the notes it moved there go back with any
    # sent to it meanwhile (:link_unlinked: NoteMove.give_back), then the
    # link's folder goes, and one last look gives back a note an older chi
    # wrote after the delete (:link_deleted; its write_note recreates the
    # folder). A worker that outlives the stop is raised
    # (SessionManager::DeleteRefused): the link stays, and the caller hears it.
    private_class_method def self.discard_failed_link(id, state_dir, moved:, carried:)
      orphan = SessionChain.next_of(id, state_dir: state_dir) or return
      if SessionManager.refuse_tui!(orphan, state_dir: state_dir) &&
         !SessionManager.stop_session(orphan, state_dir: state_dir, wait: SessionManager::STOP_WAIT)
        raise SessionManager::DeleteRefused.new(orphan, :still_stopping)
      end

      ctx = UndoContext.new(from: id, link: orphan, state_dir: state_dir, moved: moved, carried: carried)
      undo_carry(:link_stopped, ctx)
      FileUtils.rm_f(Session.session_file(orphan, state_dir: state_dir))
      undo_carry(:link_unlinked, ctx)
      SessionManager.delete_session(orphan, state_dir: state_dir, allow_scheduled: true)
      undo_carry(:link_deleted, ctx)
    rescue SessionManager::DeleteRefused
      raise
    rescue StandardError => e
      Log.warn(:worker, "continue_cleanup_failed", sid: id, error: e.class.name, msg: e.message)
    end

    # A failed link's folder an older chi's note brought back after its
    # delete: the note goes back to +id+, the folder goes again.
    private_class_method def self.give_back_strays(ctx)
      orphan = ctx.link
      state_dir = ctx.state_dir
      dir = Session.session_dir(orphan, state_dir: state_dir)
      return unless Dir.exist?(dir) && !Session.exist?(orphan, state_dir: state_dir)

      NoteMove.give_back(from: orphan, to: ctx.from, moved: [], state_dir: state_dir)
      FileUtils.rm_rf(dir)
    end

    # A failed continue's previous link, back in the lists, with rings that
    # came in meanwhile: wake it for them, as the ring's own wake would have.
    private_class_method def self.wake_for_rings(id, state_dir)
      return if SessionInbox.find_ring_files(Session.session_dir(id, state_dir: state_dir)).empty?

      SessionManager.wake_for_report(id, state_dir: state_dir)
    rescue StandardError => e
      Log.warn(:worker, "continue_wake_failed", sid: id, error: e.class.name, msg: e.message)
    end

    # The new link, holding off any worker but its own while +move+ goes to
    # it (spawn_session marks it starting before its file is saved:
    # StartingMarker.fresh?).
    # @param carried [Hash] gets what each CARRY step took to it, by name
    private_class_method def self.spawn_continuation(previous, prompt:, preview:, choice:, state_dir:, move:, carried:,
                                                     session_id:, client_id: nil)
      recap = RecapStore.read(Session.session_dir(previous.id, state_dir: state_dir))
      start = prompt.to_s.strip.empty? ? nil : prompt
      preview = previous.first_preview if preview.to_s.strip.empty? && start.nil?
      before_spawn = lambda do |link|
        ctx = CarryContext.new(previous: previous, to: link.id, state_dir: state_dir, move: move)
        CARRY.each { |step| carried[step.name] = send(step.carry, ctx) }
      end
      link = SessionManager.spawn_session(
        prompt: start, preview: preview, title: previous.title, working_directory: previous.working_directory,
        model_name: choice.model, setup: SessionSetup.of(previous), review: previous.review,
        continues: previous.id, note: SessionChain.note_text(previous, recap: recap, state_dir: state_dir),
        note_source: SessionChain::NOTE_SOURCE, state_dir: state_dir, before_spawn: before_spawn, client_id: client_id,
        session_id: session_id
      )
      link.moved_children = move
      link.moved_context = carried[:context]
      link.opener = SessionChain.opener_for(previous)
      # The fallback's warning first: spawn_session set its own.
      warnings = [choice.warning, link.model_warning].compact
      link.model_warning = warnings.join("; ") unless warnings.empty?
      link
    end

    # The model a new link of +previous+'s chain runs on: +given+ when
    # there is one (its host checked: ModelProfile::UnknownHost as for a new
    # session), else the previous link's, as typed (so an alias holds). An
    # inherited one whose host can't run it any more (gone from config.yml,
    # disabled, an alias naming another host: UnknownHost) falls back to the
    # default, with a warning naming why. `chi send --new --continues`
    # judges images by it before #run decides the same.
    # @param previous [Session]
    # @param given [String, nil] blank: inherit
    # @return [ModelChoice]
    # @raise [ModelProfile::MissingModel] a +given+ model it can't run, or
    #   a fallback with no default configured (or the default's host can't run it)
    def self.model_for(previous, given)
      unless given.to_s.strip.empty?
        return ModelChoice.new(model: ModelProfile.check_host!(ModelProfile.required_model_name(given.strip)),
                               warning: nil)
      end

      inherited = ModelProfile.required_model_name(previous.model_typed || previous.model_name)
      begin
        ModelChoice.new(model: ModelProfile.check_host!(inherited), warning: nil)
      rescue ModelProfile::UnknownHost => e
        default = ModelProfile.check_host!(ModelProfile.required_model_name(nil))
        ModelChoice.new(model: default, warning: "#{inherited} can't run (#{e.message}); started on #{default}")
      end
    end

    # The refusals that come before anything changes: continued already (no
    # forks in a chain), an open delegate that can't move to the new link
    # (ChildMove.plan), the folder gone (the worker would run elsewhere), a
    # given model whose host config.yml doesn't have, or an inherited one
    # that can't run with no default to fall back to (#model_for).
    # @return [Checked]
    # @raise [Refused, ModelProfile::MissingModel]
    private_class_method def self.check!(previous, state_dir, model: nil)
      if (following = SessionChain.next_of(previous.id, state_dir: state_dir))
        raise Refused.new(previous.id, :continued, ids: [following])
      end

      plan = move_plan!(previous.id, state_dir)
      # The new link's model, its host checked as SessionManager.spawn_session
      # checks it: before the archive stops the previous link's worker.
      choice = model_for(previous, model)
      dir = previous.working_directory.to_s
      raise Refused.new(previous.id, :folder_gone, detail: dir) unless File.directory?(dir)

      Checked.new(plan: plan, choice: choice)
    end

    # A child still open below a session (#open_children); why: running,
    # waiting, live, unreported reply, or why it can't move (ChildMove).
    OpenChild = Data.define(:id, :short_id, :why)

    # The delegates a continue of +id+ moves (ChildMove.plan).
    # @return [ChildMove::Plan]
    # @raise [Refused] for open ones it can't move
    private_class_method def self.move_plan!(id, state_dir)
      plan = ChildMove.plan(id, open: open_children(id, state_dir), state_dir: state_dir)
      return plan if plan.refuse.empty?

      raise Refused.new(id, :open_children, ids: plan.refuse.map(&:id),
                                                    detail: plan.refuse.map { |c| "#{c.short_id} (#{c.why})" }.join(", "))
    end

    # The unarchived children, at any depth (the archive's cascade), of the
    # session still running, waiting for an answer, with a live worker, or
    # (a delegate) with a reply its parent wasn't given (ChildrenStatus).
    # @return [Array<OpenChild>]
    def self.open_children(id, state_dir)
      require_relative "children_status"
      nodes = [id, *SessionManager.descendant_ids(id, state_dir)]
      nodes.flat_map { |node| ChildrenStatus.of(node, state_dir: state_dir) }.uniq(&:id).filter_map do |child|
        why = if %w[waiting running].include?(child.state) then child.state
              elsif child.live then "live"
              elsif child.delegate && child.last_reply && !child.reported then "unreported reply"
              end
        why && OpenChild.new(id: child.id, short_id: child.short_id, why: why)
      end
    end

    # Ask the session's live worker for a recap now (Bridge POST /recap:
    # IdleRecap#request_now) and wait, up to +wait+ seconds, for recap.json
    # to change. A worker that is gone wrote its recap when it left; one
    # that has nothing new to say, too short a conversation, or recaps off
    # answers at once. Best effort: the continue goes on without. A review
    # fork (ReviewStart) asks the same, with nothing archived after.
    def self.recap_before_archive(id, state_dir, wait:)
      dir = Session.session_dir(id, state_dir: state_dir)
      client = WorkerLink.client(id, session_dir: dir) or return
      before = RecapStore.read(dir)
      reply = client.request_recap
      asked = reply.status == 200 && reply.json.is_a?(Hash) ? reply.json["request"] : nil
      return unless %w[started in_flight].include?(asked)

      BridgeClient.poll(wait, interval: 0.2) { RecapStore.read(dir) != before }
    rescue StandardError => e
      Log.info(:worker, "continue_recap_failed", sid: id, error: e.class.name, msg: e.message)
      nil
    end
  end
end
