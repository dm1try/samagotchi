# frozen_string_literal: true

require_relative "grants"
require_relative "log"
require_relative "participant_name"
require_relative "participant_turn_mode"
require_relative "participants"
require_relative "steer"
require_relative "turn_checkpoint"
require_relative "verify_fresh"

module Samagotchi
  # The Worker's one seat for "may this participant act": a queued turn as
  # it starts (Worker#run_prompt), a line the running turn's drain would
  # merge (Worker#pending_input_drain), a running pair turn before each
  # generation (Engine#participant_stop, #turn_stop) and the owner's
  # Continue on a participant's offer (ContinueOffer's participant_refused).
  # It reads participants.json and the spend on each ask, and tells the
  # owner of a reached cap once per participant and cap.
  #
  # Threads: loop thread only. Every caller runs on the worker's loop (a
  # turn runs on it too); no Bridge, anytime, signal or scratch-watch thread
  # calls it, so it takes no lock (@cap_noticed is unguarded). A caller
  # from another thread needs a lock here first, and Engine#metrics' spend
  # would still not be safe from any thread. Worker#held_for_offer?, which
  # Bridge threads reach, is not here: it is stateless.
  class WorkerParticipantGate
    CAP_NOTICE = "%<name>s reached their $%<cap>.2f cap: their turns stop and are refused until you raise it " \
                 "(chi share cap %<session>s %<id>s AMOUNT)."
    # The reason a pair turn stopped at its participant's cap (the turn's
    # "stopped the turn: …" notice).
    CAP_STOP = "%<name>s reached their $%<cap>.2f cap"
    # The reason a pair turn stopped because its participant's link ended
    # (revoked, expired, or the session archived).
    REVOKED_STOP = "%<name>s's link was revoked or expired"

    # @param engine [Engine] announces (the cap notice, :turn_dequeued,
    #   #watch's :participants_changed) and its metrics' spend
    # @param session [Session] the worker's (its participants source, its
    #   Verify fresh)
    # @param hook [String] the cap notice's hook name (Engine::PARTICIPANTS_HOOK)
    def initialize(engine:, session:, session_id:, state_dir:, session_dir:, hook:)
      @engine = engine
      @session = session
      @session_id = session_id
      @state_dir = state_dir
      @session_dir = session_dir
      @hook = hook
      # [author, cap] pairs the owner was told about (#cap_notice).
      @cap_noticed = Set.new
    end

    # Why the participant +author+ ("p:<id>") may run no more turns, nil
    # while they may (and for the owner): by ParticipantTurnMode, "outdated"
    # for an older chi's read-only invite (an entry, or a Verify fresh child
    # saved, without "pair": this chi runs no read-only turn), "revoked" when
    # participants.json has no current entry for them (revoked, expired,
    # never invited) or they aren't invited to this (the owner's own Verify
    # fresh child), "cap_reached" once they spent their cap (its own,
    # else the config's; their turns and the side requests they caused,
    # Engine#metrics). The owner hears the cap once per cap (#cap_notice).
    def refusal(author)
      author = Steer.sender_author(author) or return nil

      entry = entry(author)
      case ParticipantTurnMode.of(entry: entry, session: @session, now: Time.now)
      when :outdated then return "outdated"
      when :revoked, :not_invited then return "revoked"
      end

      cap = cap(entry)
      return nil if spend(author) < cap

      cap_notice(author, entry, cap)
      "cap_reached"
    end

    # Why a participant's running pair turn stops (Engine#participant_stop,
    # asked before each of its generations): their link ended (revoked,
    # expired, the session archived) or their cap reached
    # (#refusal, which gives the owner the cap notice), else nil.
    def turn_stop(author)
      reason = refusal(author) or return nil

      entry = entry(author)
      name = label(author, entry&.name)
      return format(REVOKED_STOP, name: name) if %w[revoked outdated].include?(reason)

      format(CAP_STOP, name: name, cap: cap(entry))
    end

    # A participant's queued turn that may not start (#refusal):
    # taken off the queue (:turn_dequeued, so every UI drops its bubble)
    # and audited; it never runs. Its settled record (canceled, the reason)
    # ends the sender's wait on it (chi send --wait, chi web's /wait).
    # @param origin [TurnOrigin] a participant's
    # @return [nil]
    def refuse(origin, reason)
      TurnCheckpoint.record_refused(@session_dir, origin.enqueued_id, reason: reason, author: origin.participant_author)
      Participants.log(source_id, :turn, state_dir: @state_dir, participant: origin.participant_id,
                                         enqueued_id: origin.enqueued_id, status: "refused", reason: reason)
      @engine.announce(type: :turn_dequeued, enqueued_id: origin.enqueued_id, client_id: origin.client_id)
      nil
    end

    # A participant invited, revoked or expired since the last look: the
    # UIs hear it (Engine#announce_participants: :participants_changed).
    # Between turns, at most once a fallback tick; a failure only logs.
    def watch
      @engine.announce_participants
    rescue StandardError => e
      Log.warn(:worker, "participants_watch_failed", error: e.class.name)
    end

    private

    # +author+'s participants.json entry: this session's, a Verify fresh
    # child's parent's (Session#participants_source_id); nil for none.
    def entry(author)
      Participants.read(source_id, state_dir: @state_dir).find { |e| Steer.author_for(e.id) == author }
    end

    # The session whose participants.json and audit trail this session's
    # participants are in.
    def source_id = @session&.participants_source_id || @session_id

    # What +author+ spent against their cap: this session's metrics (live)
    # and, through Verify fresh, the parent's or the children's saved ones
    # (VerifyFresh.related_spend).
    def spend(author)
      @engine.metrics.spend(author) + VerifyFresh.related_spend(@session, author, state_dir: @state_dir)
    end

    # A participant's cap in dollars: their own, else the config's.
    def cap(entry) = entry&.cap.is_a?(Numeric) ? entry.cap.to_f : Grants.default_cap

    # A participant's cleaned name, else their id.
    def label(author, name)
      who = ParticipantName.clean(name)
      who.empty? ? Steer.participant_id(author) : who
    end

    # The owner's notice that a participant reached their cap: once per
    # participant and cap (a raised cap that is reached again says so again).
    def cap_notice(author, entry, cap)
      key = [author, cap]
      return if @cap_noticed.include?(key)

      @cap_noticed << key
      id = Steer.participant_id(author)
      @engine.announce(type: :hook_notice, hook: @hook, level: :warn, between_turns: true,
                       text: format(CAP_NOTICE, name: label(author, entry.name), cap: cap,
                                                session: source_id[0, 8], id: id))
    end
  end
end
