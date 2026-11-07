# frozen_string_literal: true

module Samagotchi
  class Engine
    # The attached-context candidate judge (ContextJudge): its pass at an
    # owner turn's start and for a late candidate, the asks it starts, and
    # the cards it shows after the turn. Reads @context_cards_after_turn
    # under @context_cards_mutex, @side_judgments, @host_registry, @session.
    module ContextJudgePart
      private

      # The candidate judge (ContextJudge) at an owner turn's start, after
      # the toolkit's ask settled: the session's candidates' status changes
      # are logged (ContextCandidatesLog#look) and, unless
      # context.candidates.mode is off, the proposed candidates due an ask
      # are asked about the owner's prompts so far, this one included. Never
      # a participant's turn, a review session or a Continue (no new prompt).
      def start_context_judge(turn)
        session = turn.session
        return unless turn.prompt.is_a?(String) && OwnerPrompt.turn?(session: session, author: turn.origin.author)

        context_judge_pass(session, ContextCandidates.owner_texts(session.messages) + [turn.prompt], phase: "turn")
      end
      private :start_context_judge

      # A late proposal no owner prompt mentions (Plugin::Host
      # #candidate_proposed: github-pr's init task runs beside the first
      # turn): judged on the owner's prompts so far, the running turn's too.
      def judge_late_candidates
        session = @session
        return if session.nil? || session.review?

        texts = ContextCandidates.owner_texts(plugin_messages)
        context_judge_pass(session, texts, phase: "late") unless texts.empty?
      end
      private :judge_late_candidates

      # One look at +session+'s candidates; the asks go to SideJudgments'
      # :context kind, one thread asking each due candidate in turn.
      def context_judge_pass(session, texts, phase:)
        return if session.id.nil? || session.scratch

        rows = ContextCandidates.with_status(session.id, project_root: session.project_root, state_dir: session_state_dir)
        return if rows.empty?

        log = ContextCandidatesLog.log_for(session_state_dir)
        records = ContextCandidatesLog.records_for(log, session.id)
        ContextCandidatesLog.look(log, session.id, rows, records) if phase == "turn"
        settings = ContextJudge::Settings.from_config
        return if settings.mode == "off"

        jobs = ContextJudge.jobs(rows, records, session_id: session.id, texts: texts, settings: settings, phase: phase,
                                                parent_attached: context_parent_attached(session))
        return if jobs.empty?

        client = system_one_recording(SystemOne::Client.from_config(host_registry: @host_registry, mode: "on", tag: :context),
                                      ContextJudge::JUDGMENT, session, mode: settings.mode)
        return unless client

        start_context_asks(client, jobs, log, settings, context_choice(session, log, settings))
      rescue StandardError => e
        ContextJudge.warn(e)
      end
      private :context_judge_pass

      # @return [Thread, nil] the asks' thread, nil when none started
      def start_context_asks(client, jobs, log, settings, choice)
        if @side_judgments.in_flight?(:context)
          Log.info(:context, "context_judge_in_flight_skipped", session_id: jobs.first.session_id)
          return nil
        end

        @side_judgments.start(:context, warn: ContextJudge.method(:warn)) do
          jobs.each { |job| choice.call(job, ContextJudge.ask(client: client, job: job, log: log, settings: settings)) }
        end
      end
      private :start_context_asks

      # What an answer does on the asks' thread (ContextCandidateChoice
      # #after_judged: on mode attaches or cards; audit nothing). Taken on
      # the caller's thread. The attach only writes the session's folder: its
      # note comes with the next between-turn delivery, never into a running
      # turn. A card shows only while this Engine is still on that session,
      # and not in a running turn (it isn't the turn's: no "waiting for you"
      # on it), but once it has ended.
      # @return [#call] (job, fields)
      def context_choice(session, log, settings)
        session_id = session.id
        project_root = session.project_root
        state_dir = session_state_dir
        show = lambda do |**card|
          current = @session
          next nil unless current.nil? || current.id == session_id

          @context_cards_mutex.synchronize do
            next @context_cards_after_turn << card if turn_running?

            show_card(**card)
          end
        end
        lambda do |job, fields|
          ContextCandidateChoice.after_judged(job: job, fields: fields, settings: settings, project_root: project_root,
                                              state_dir: state_dir, log: log, show_card: show)
        end
      end
      private :context_choice

      # The cards #context_choice held while a turn ran (#run_turn's ensure,
      # after the turn flag is released).
      def show_context_cards_after_turn
        cards = @context_cards_mutex.synchronize { @context_cards_after_turn.slice!(0..) }
        cards.each { |card| show_card(**card) }
      rescue StandardError => e
        ContextJudge.warn(e)
      end
      private :show_context_cards_after_turn

      # A delegate child's parent's sources, by title (else name): the
      # judge's started_from. nil for any other session (a chi send --new
      # session has no parent; a fork isn't a delegate).
      def context_parent_attached(session)
        return nil unless session.delegate? && session.parent_id

        parent_root = if Session.exist?(session.parent_id, state_dir: session_state_dir)
                        Session.load(session.parent_id, state_dir: session_state_dir).project_root
                      else
                        session.project_root
                      end
        ContextSources.attached(session.parent_id, project_root: parent_root, state_dir: session_state_dir)
                      .map { |attached| attached.source.title || attached.name }
      rescue StandardError => e
        Log.warn(:context, "context_parent_attached_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        []
      end
      private :context_parent_attached
    end
  end
end
