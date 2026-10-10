# frozen_string_literal: true

require "fileutils"
require_relative "session"
require_relative "session_setup"
require_relative "session_inbox"
require_relative "session_chain"
require_relative "child_move"
require_relative "archive_store"
require_relative "recap_store"
require_relative "bridge_client"
require_relative "model_profile"
require_relative "log"
require_relative "session_manager"

module Samagotchi
  # The next link of a session chain (chi send --new --continues, web
  # Continue →): SessionManager.continue_session runs .run. The archive,
  # spawn, stop and wake it builds on are SessionManager's.
  module SessionContinue
    # A continue that can't happen (#run). reason: :continued
    # (another session continues it already: +ids+ names it), :open_children
    # (open children it can't move to the new link: on an older chi's
    # worker or open in a chi REPL; +ids+ names them) or :folder_gone (its
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
    LOCK = "continue.lock"
    # How often a last:<id> continue looks again when another continue
    # moved the chain's end while it waited for the lock.
    TRIES = 3

    # Start the next link of a chain: a new session that continues
    # +id_or_ref+ (Session#continues) in its folder, on its model (the name
    # it was typed as, so an alias holds) and with its own setup (SessionSetup),
    # starting with a context note from chi: the link and the previous
    # link's recap (SessionChain.note_text). The previous link is archived
    # first, with its finished delegates (archive_session's rules: a turn
    # running, a prompt queued or the step-limit question refuse; an idle
    # worker is stopped), so a refusal starts nothing. Its open delegates
    # (running, waiting, live, an unreported reply, at any depth below them)
    # move to the new link instead (ChildMove): their reports reach it.
    # Before that its live worker is asked for a recap and given up to
    # +recap_wait+ seconds to write it.
    # One continue of a session at a time (a lock in its folder): a double
    # click finds the first one's link and is refused; a last:<id> one
    # follows the chain to its new end instead.
    # @param id_or_ref [String] an id, a prefix, or last:<id> (SessionChain.resolve)
    # @param prompt [String, nil] its first message (nil: it starts idle)
    # @param title [String, nil] what the lists show before the first turn;
    #   by default the prompt, else the previous link's preview
    # @return [Session] the new link (#model_warning as spawn_session's,
    #   #moved_children: the delegates it took over)
    # @raise [ArgumentError] no such session (Session::AmbiguousId for a prefix of several)
    # @raise [Refused] continued already, delegates open that can't
    #   move, or its folder is gone
    # @raise [ArchiveRefused, OwnedByTUI] as archive_session
    def self.run(id_or_ref, prompt: nil, title: nil, state_dir: nil, recap_wait: RECAP_WAIT, archive_wait: 5)
      sd = state_dir || Session.default_state_dir
      TRIES.times do |try|
        id = SessionChain.resolve(id_or_ref, state_dir: sd)
        result = with_lock(id, sd) do
          follow = id_or_ref.to_s.strip.start_with?(SessionChain::LAST_PREFIX) && try < TRIES - 1
          next :moved if follow && SessionChain.next_of(id, state_dir: sd)

          run_locked(id, prompt: prompt, title: title, state_dir: sd, recap_wait: recap_wait,
                         archive_wait: archive_wait)
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

    private_class_method def self.run_locked(id, prompt:, title:, state_dir:, recap_wait:, archive_wait:)
      previous = Session.load(id, state_dir: state_dir)
      plan = check!(previous, state_dir)
      # archive_session's refusals that can be known now, before the wait.
      SessionManager.archivable!(id, state_dir, except: plan.move)
      recap_before_archive(id, state_dir, wait: recap_wait)
      # Again: a turn sent to it during the wait may have delegated (they
      # move too), or a delegate finished.
      plan = move_plan!(id, state_dir)
      already = [id, *SessionManager.descendant_ids(id, state_dir, except: plan.move)].select do |sid|
        ArchiveStore.archived?(Session.session_dir(sid, state_dir: state_dir))
      end
      archive = SessionManager.archive_session(id, state_dir: state_dir, wait: archive_wait, except: plan.move)
      archived = archive[:archived] - already
      begin
        spawn_continuation(previous, prompt: prompt, title: title, state_dir: state_dir, move: plan.move)
      rescue StandardError
        # Nothing started: the delegates go back, what this archived goes
        # back to the lists, and a new link saved before its worker failed
        # to spawn goes (left, it would hold the chain: "continued already",
        # last: to it).
        undo_move(id, state_dir, moved: plan.move)
        begin
          discard_failed_link(id, state_dir)
        ensure
          archived.each { |sid| ArchiveStore.unarchive(sid, state_dir: state_dir) }
          wake_for_rings(id, state_dir) unless plan.move.empty?
        end
        raise
      end
    end

    # The delegates a failed #run moved, or began to (its
    # intent names them), go back to +id+.
    private_class_method def self.undo_move(id, state_dir, moved:)
      link = SessionChain.next_of(id, state_dir: state_dir) or return
      ids = ChildMove.read_intent(link, state_dir: state_dir)&.ids || moved
      ChildMove.apply(ids, from: link, to: id, state_dir: state_dir, undo: true)
      ChildMove.clear_intent(link, state_dir: state_dir)
    rescue StandardError => e
      Log.warn(:worker, "continue_undo_move_failed", sid: id, error: e.class.name, msg: e.message)
    end

    # The link a failed #run saved (no other continues +id+:
    # check! made sure under the lock): its worker stopped if one
    # started, then the rings a moved delegate wrote into it just before
    # the undo go back to +id+, then the link goes. A worker that outlives
    # the stop is raised (SessionManager::DeleteRefused): the link stays,
    # and the caller hears it.
    private_class_method def self.discard_failed_link(id, state_dir)
      orphan = SessionChain.next_of(id, state_dir: state_dir) or return
      if SessionManager.refuse_tui!(orphan, state_dir: state_dir) &&
         !SessionManager.stop_session(orphan, state_dir: state_dir, wait: 10)
        raise SessionManager::DeleteRefused.new(orphan, :still_stopping)
      end

      ChildMove.return_rings(from: orphan, to: id, state_dir: state_dir)
      SessionManager.delete_session(orphan, state_dir: state_dir)
    rescue SessionManager::DeleteRefused
      raise
    rescue StandardError => e
      Log.warn(:worker, "continue_cleanup_failed", sid: id, error: e.class.name, msg: e.message)
    end

    # A failed continue's previous link, back in the lists, with rings that
    # came in meanwhile: wake it for them, as the ring's own wake would have.
    private_class_method def self.wake_for_rings(id, state_dir)
      return if SessionInbox.find_ring_files(Session.session_dir(id, state_dir: state_dir)).empty?

      SessionManager.wake_for_report(id, state_dir: state_dir)
    rescue StandardError => e
      Log.warn(:worker, "continue_wake_failed", sid: id, error: e.class.name, msg: e.message)
    end

    # The new link, holding off any worker but its own (ChildMove.starting?)
    # while +move+ goes to it.
    private_class_method def self.spawn_continuation(previous, prompt:, title:, state_dir:, move:)
      recap = RecapStore.read(Session.session_dir(previous.id, state_dir: state_dir))
      start = prompt.to_s.strip.empty? ? nil : prompt
      title = previous.first_preview if title.to_s.strip.empty? && start.nil?
      before_spawn = lambda do |link|
        ChildMove.mark_starting(link.id, state_dir: state_dir)
        ChildMove.apply(move, from: previous.id, to: link.id, state_dir: state_dir)
      end
      link = SessionManager.spawn_session(
        prompt: start, title: title, working_directory: previous.working_directory,
        model_name: previous.model_typed || previous.model_name, setup: SessionSetup.of(previous),
        continues: previous.id, note: SessionChain.note_text(previous, recap: recap),
        note_source: SessionChain::NOTE_SOURCE, state_dir: state_dir, before_spawn: before_spawn
      )
      link.moved_children = move
      link
    end

    # The refusals that come before anything changes: continued already (no
    # forks in a chain), an open delegate that can't move to the new link
    # (ChildMove.plan), the folder gone (the worker would run elsewhere), a
    # model whose host config.yml no longer has.
    # @return [ChildMove::Plan]
    # @raise [Refused, ModelProfile::MissingModel]
    private_class_method def self.check!(previous, state_dir)
      if (following = SessionChain.next_of(previous.id, state_dir: state_dir))
        raise Refused.new(previous.id, :continued, ids: [following])
      end

      plan = move_plan!(previous.id, state_dir)
      # Its model's host, as SessionManager.spawn_session checks it: before
      # the archive stops the previous link's worker.
      ModelProfile.check_host!(ModelProfile.required_model_name(previous.model_typed || previous.model_name))
      dir = previous.working_directory.to_s
      raise Refused.new(previous.id, :folder_gone, detail: dir) unless File.directory?(dir)

      plan
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
    # answers at once. Best effort: the continue goes on without.
    private_class_method def self.recap_before_archive(id, state_dir, wait:)
      return unless SessionManager.worker_live?(id, state_dir: state_dir)

      dir = Session.session_dir(id, state_dir: state_dir)
      client = BridgeClient.discover(id, session_dir: dir) or return
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
