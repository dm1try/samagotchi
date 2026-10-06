# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "time"

require_relative "client_id"
require_relative "config"
require_relative "context_note"
require_relative "log"
require_relative "session"
require_relative "session_inbox"

module Samagotchi
  # What comes into a worker's session between turns, each kind with its
  # own save rule (the Worker runs the turns they start):
  #
  # - context notes (#absorb_notes): into the conversation, saved, then
  #   their files deleted;
  # - attached context (#absorb_context): once the conversation started,
  #   saved, then the subscriptions written; a source asking to wake may
  #   start a context wake turn (a ContextWake);
  # - the first prompt (#take_initial_prompt): taken once and saved
  #   cleared; as a command (#initial_command?) the session is saved idle;
  # - an input file (#take_input): a Prompt for a turn, whose own save is
  #   the turn's, or a command queued.
  class WorkerInbound
    # One context wake per source in this long (D5): later changes inside
    # it arrive as notes.
    CONTEXT_WAKE_WINDOW = 600

    # A prompt to run a turn for: an input file's, or the first prompt.
    # +no_interrupt+: an offer its turn makes keeps it for its continue
    # turn; +images+: its image refs ({file:, name:}).
    Prompt = Data.define(:text, :origin, :no_interrupt, :images) do
      def initialize(text:, origin: nil, no_interrupt: false, images: []) = super
    end

    # A context wake turn to run: the ContextAbsorber::Delivery that woke
    # it, whose wake note is already in the conversation as the start of
    # the turn +turn_id+.
    ContextWake = Data.define(:delivery, :turn_id) do
      def name = delivery.name
      def origin = { client_id: "#{ClientId::CONTEXT_PREFIX}#{name}" }
    end

    # A save between turns (the turn's own, a command's, the notes', the
    # first prompt's): what it saves is in memory, so one that fails (disk
    # full, permissions; the next save writes it) is logged and must not
    # take the worker down with it.
    # @param at [Symbol] which save, for the log
    # @return [Boolean] whether it saved
    def self.save_or_log(at)
      yield
      true
    rescue SystemCallError, IOError => e
      Log.exception(:worker, "save_failed", e, at: at)
      false
    end

    # @param wakes [WorkerWakes] the wake budget a context wake asks
    # @param awaiting_continue [#call] whether a continue offer waits
    # @param stopped [#call] whether the session was stopped on disk
    # @param queue_command [#call] (line, client_id) queues a session
    #   command for the loop's next pass
    def initialize(session:, state_dir:, session_dir:, engine:, context_absorber:, wakes:, awaiting_continue:,
                   stopped:, queue_command:)
      @session = session
      @state_dir = state_dir
      @session_dir = session_dir
      @engine = engine
      @context_absorber = context_absorber
      @wakes = wakes
      @awaiting_continue = awaiting_continue
      @stopped = stopped
      @queue_command = queue_command
      @initial_prompt_taken = false
    end

    # Add the queued context notes to the conversation (between turns only,
    # on the loop's thread), save, then delete their files: a crash before
    # the delete leaves them claimed, and Engine#add_context_note skips a
    # note the saved conversation already holds. A failed save keeps the
    # files too: the next pass claims them again, finds them in the
    # conversation and saves again. Not activity: a note alone neither
    # starts a turn nor keeps an idle worker up.
    def absorb_notes
      files = SessionInbox.find_new_note_files(@session_dir)
      return if files.empty? || @stopped.call

      claimed = files.filter_map { |file| SessionInbox.claim_note_file(file) }
      claimed.each do |file|
        note = SessionInbox.read_note(file)
        @engine.add_context_note(@session, note) if note
      end
      return unless save(:notes)

      claimed.each { |file| FileUtils.rm_f(file) }
    end

    # The attached context's notes (ContextAbsorber), between turns. Not
    # into a session with no turn yet (+before_turn+: one is about to
    # run): auto-attached context alone doesn't make a session worth
    # keeping. Saved, then the subscriptions written (a crash between the
    # two re-delivers; the note ids dedupe).
    # +wake+: the session is idle with nothing queued, so an update whose
    # source asked to wake may start a turn (#context_wake_for): its note
    # goes in as the turn's first message.
    # @return [ContextWake, nil] the wake turn to run now
    # @raise [SystemCallError, IOError] the caller logs it (context_failed)
    def absorb_context(before_turn: false, wake: false)
      return nil unless before_turn || conversation_started?
      return nil if @stopped.call

      batch = @context_absorber.pending
      return nil unless batch

      waking = wake ? context_wake_for(batch) : nil
      turn_id = SecureRandom.uuid if waking
      batch.deliveries.each do |delivery|
        next unless delivery.note

        note = delivery == waking ? delivery.wake_note.merge(turn_start: true, turn_id: turn_id) : delivery.note
        @engine.add_context_note(@session, note)
      end
      # Saved even when every note was there already: after a failed save
      # they are in memory only.
      return nil if batch.notes.any? && !save(:context)

      @context_absorber.commit(waking ? woken(batch, waking) : batch)
      waking && ContextWake.new(delivery: waking, turn_id: turn_id)
    end

    # A failed wake turn kept nothing but its note: the update goes back to
    # a plain note (no turn start, the background wording), so a reload
    # draws no empty turn for it.
    def unmark_wake(context_wake)
      messages = @engine.messages_checkpoint
      index = messages.index { |m| m[:turn_start] && m[:turn_id] == context_wake.turn_id }
      return unless index

      messages[index] = ContextNote.message(**context_wake.delivery.note)
      @engine.rollback_to(messages)
    end

    # spawn_session hands the first prompt over in last_prompt, but
    # last_prompt also records every later turn's prompt (and mark_error's
    # reason), so only a session with no conversation yet has one pending; a
    # resumed session must not replay its last turn. Taken once.
    # @return [String, nil]
    def take_initial_prompt
      return nil if @initial_prompt_taken

      @initial_prompt_taken = true
      # A context note may have come before the first prompt ran.
      return nil unless @session.messages.all? { |m| ContextNote.note?(m) } && !@session.last_prompt.to_s.strip.empty?

      prompt = @session.last_prompt
      @session.last_prompt = ""
      save(:initial_prompt)
      prompt
    end

    # The first prompt as a command (queued): the session was saved as
    # running for a turn that won't run.
    # @return [Boolean] whether it was one
    def initial_command?(prompt)
      return false unless queue_as_command(prompt, nil)

      @session.status = Session::STATUS_IDLE
      save(:initial_command, unless_stopped: true)
      true
    end

    # Claim +input_file+ and yield its Prompt (the turn runs in the block),
    # deleting the claimed file after. Nothing is yielded for a file
    # another reader claimed, an empty line or a command (queued).
    def take_input(input_file)
      claimed_file = SessionInbox.claim_input_file(input_file)
      return unless claimed_file

      begin
        message, origin, no_interrupt, images = SessionInbox.read_input(claimed_file)
        return if message.to_s.strip.empty?
        return if Array(images).empty? && queue_as_command(message, origin)

        yield Prompt.new(text: message, origin: origin, no_interrupt: !!no_interrupt, images: images || [])
      ensure
        FileUtils.rm_f(claimed_file)
      end
    end

    # Whether the session has had a turn: a user or assistant message.
    def conversation_started?
      Array(@session.messages).any? { |m| %w[user assistant model].include?((m[:role] || m["role"]).to_s) }
    end

    private

    # +unless_stopped+: not when the session was stopped meanwhile: the stop
    # (chi stop, from another process) saved its status, and this save
    # would write the worker's over it.
    def save(at, unless_stopped: false)
      self.class.save_or_log(at) do
        @session.save(state_dir: @state_dir) unless unless_stopped && @stopped.call
      end
    end

    # A session command sent as a message (chi send -m "/model x", a web
    # page's first message) runs as the command, as the Bridge does for a
    # POST /turn; an unknown /word stays a prompt. Queued: the loop's next
    # pass runs it.
    # @return [Boolean] whether +text+ was one
    def queue_as_command(text, origin)
      return false unless @engine.command_registry.command?(text.to_s)

      @queue_command.call(text, origin&.dig(:client_id))
      true
    end

    # The update in +batch+ that may start a wake turn now: its source
    # asked (wake: true), context.wake is on, the wake budget is open
    # (WorkerWakes#context_open?: no continue offer, not paused, under
    # session.max_wakes, past the start grace) and the source hasn't woken
    # the session in the last CONTEXT_WAKE_WINDOW. The others stay plain
    # notes. Within the start grace a change is a note: it came while the
    # session was away.
    def context_wake_for(batch, now: Time.now)
      candidates = batch.deliveries.select(&:wake_note)
      return nil if candidates.empty? || !context_wakes_on?
      return nil unless @wakes.context_open?(awaiting_continue: @awaiting_continue.call, names: candidates.map(&:name))

      candidates.find { |delivery| !woke_lately?(delivery.subscription, now) }
    end

    def context_wakes_on? = Config.get("context.wake") != false

    def woke_lately?(subscription, now)
      at = subscription&.wakes_at && Time.iso8601(subscription.wakes_at)
      at ? now - at < CONTEXT_WAKE_WINDOW : false
    rescue ArgumentError
      false
    end

    # +batch+ with +waking+'s subscription recording the wake (the 10-minute window).
    def woken(batch, waking)
      stamped = waking.with(subscription: waking.subscription.with(wakes_at: Time.now.iso8601))
      batch.with(deliveries: batch.deliveries.map { |delivery| delivery == waking ? stamped : delivery })
    end
  end
end
