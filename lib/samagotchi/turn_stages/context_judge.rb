# frozen_string_literal: true

require_relative "../config"
require_relative "../context_candidate_choice"
require_relative "../context_candidates"
require_relative "../context_candidates_log"
require_relative "../context_judge"
require_relative "../context_sources"
require_relative "../log"
require_relative "../owner_prompt"
require_relative "../session"
require_relative "../side_judgments"
require_relative "../system_one/client"

module Samagotchi
  module TurnStages
    # The attached-context candidate judge's stage (Samagotchi::ContextJudge
    # is the judge itself; inside this class the bare name is this stage):
    # its pass at an owner turn's start and for a late candidate, the asks it
    # starts, and the cards an answer brought while a turn ran, shown once it
    # has ended. Its state is those held cards, under their mutex.
    class ContextJudge
      # @param side_judgments [SideJudgments] the Engine's side asks (:context kind)
      # @param host_registry [HostRegistry] System 1's client resolves its host here
      # @param state_dir [#call] the sessions dir
      # @param recording [#call] (client, judgment, session, mode:) → the client saving its runs
      # @param session [#call] the session the Engine is on now (nil: none)
      # @param messages [#call] the owner's conversation so far (Engine#plugin_messages)
      # @param turn_running [#call] whether a turn runs now
      # @param show_card [#call] (**card) shows a card (Engine#show_card)
      def initialize(side_judgments:, host_registry:, state_dir:, recording:, session:, messages:, turn_running:, show_card:)
        @side_judgments = side_judgments
        @host_registry = host_registry
        @state_dir = state_dir
        @recording = recording
        @session = session
        @messages = messages
        @turn_running = turn_running
        @show_card = show_card
        # On mode's cards an answer brought while a turn ran: shown once it
        # has ended (#show_cards_after_turn).
        @cards_after_turn = []
        @cards_mutex = Mutex.new
      end

      # For specs: the asks' thread (SideJudgments' :context kind), nil before any.
      def asks_thread = @side_judgments.thread(:context)

      # The candidate judge at an owner turn's start, after the toolkit's
      # ask settled: the session's candidates' status changes are logged
      # (ContextCandidatesLog#look) and, unless context.candidates.mode is
      # off, the proposed candidates due an ask are asked about the owner's
      # prompts so far, this one included. Never a participant's turn, a
      # review session or a Continue (no new prompt).
      def start(turn)
        session = turn.session
        return unless turn.prompt.is_a?(String) && OwnerPrompt.turn?(session: session, author: turn.origin.author)

        pass(session, ContextCandidates.owner_texts(session.messages) + [turn.prompt], phase: "turn")
      end

      # A late proposal no owner prompt mentions (Plugin::Host
      # #candidate_proposed: github-pr's init task runs beside the first
      # turn): judged on the owner's prompts so far, the running turn's too.
      def late_candidates
        session = @session.call
        return if session.nil? || session.review?

        texts = ContextCandidates.owner_texts(@messages.call)
        pass(session, texts, phase: "late") unless texts.empty?
      end

      # The cards #choice held while a turn ran (Engine#run_turn's ensure,
      # after the turn flag is released).
      def show_cards_after_turn
        cards = @cards_mutex.synchronize { @cards_after_turn.slice!(0..) }
        cards.each { |card| @show_card.call(**card) }
      rescue StandardError => e
        Samagotchi::ContextJudge.warn(e)
      end

      private

      # One look at +session+'s candidates; the asks go to SideJudgments'
      # :context kind, one thread asking each due candidate in turn.
      def pass(session, texts, phase:)
        return if session.id.nil? || session.scratch

        rows = ContextCandidates.with_status(session.id, project_root: session.project_root, state_dir: @state_dir.call)
        return if rows.empty?

        log = ContextCandidatesLog.log_for(@state_dir.call)
        records = ContextCandidatesLog.records_for(log, session.id)
        ContextCandidatesLog.look(log, session.id, rows, records) if phase == "turn"
        settings = Samagotchi::ContextJudge::Settings.from_config
        return if settings.mode == "off"

        jobs = Samagotchi::ContextJudge.jobs(rows, records, session_id: session.id, texts: texts, settings: settings,
                                                            phase: phase, parent_attached: parent_attached(session))
        return if jobs.empty?

        client = @recording.call(SystemOne::Client.from_config(host_registry: @host_registry, mode: "on", tag: :context),
                                 Samagotchi::ContextJudge::JUDGMENT, session, mode: settings.mode)
        return unless client

        start_asks(client, jobs, log, settings, choice(session, log, settings))
      rescue StandardError => e
        Samagotchi::ContextJudge.warn(e)
      end

      # @return [Thread, nil] the asks' thread, nil when none started
      def start_asks(client, jobs, log, settings, choice)
        if @side_judgments.in_flight?(:context)
          Log.info(:context, "context_judge_in_flight_skipped", session_id: jobs.first.session_id)
          return nil
        end

        @side_judgments.start(:context, warn: Samagotchi::ContextJudge.method(:warn)) do
          jobs.each { |job| choice.call(job, Samagotchi::ContextJudge.ask(client: client, job: job, log: log, settings: settings)) }
        end
      end

      # What an answer does on the asks' thread (ContextCandidateChoice
      # #after_judged: on mode attaches or cards; audit nothing). Taken on
      # the caller's thread. The attach only writes the session's folder: its
      # note comes with the next between-turn delivery, never into a running
      # turn. A card shows only while the Engine is still on that session,
      # and not in a running turn (it isn't the turn's: no "waiting for you"
      # on it), but once it has ended.
      # @return [#call] (job, fields)
      def choice(session, log, settings)
        session_id = session.id
        project_root = session.project_root
        state_dir = @state_dir.call
        show = lambda do |**card|
          current = @session.call
          next nil unless current.nil? || current.id == session_id

          @cards_mutex.synchronize do
            next @cards_after_turn << card if @turn_running.call

            @show_card.call(**card)
          end
        end
        lambda do |job, fields|
          ContextCandidateChoice.after_judged(job: job, fields: fields, settings: settings, project_root: project_root,
                                              state_dir: state_dir, log: log, show_card: show)
        end
      end

      # A delegate child's parent's sources, by title (else name): the
      # judge's started_from. nil for any other session (a chi send --new
      # session has no parent; a fork isn't a delegate).
      def parent_attached(session)
        return nil unless session.delegate? && session.parent_id

        parent_root = if Session.exist?(session.parent_id, state_dir: @state_dir.call)
                        Session.load(session.parent_id, state_dir: @state_dir.call).project_root
                      else
                        session.project_root
                      end
        ContextSources.attached(session.parent_id, project_root: parent_root, state_dir: @state_dir.call)
                      .map { |attached| attached.source.title || attached.name }
      rescue StandardError => e
        Log.warn(:context, "context_parent_attached_failed", error: e.class.name, msg: e.message.to_s[0, 200])
        []
      end
    end
  end
end
