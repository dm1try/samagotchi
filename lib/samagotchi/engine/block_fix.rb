# frozen_string_literal: true

require_relative "../answer_display"
require_relative "../answer_tail"
require_relative "../block_fix"
require_relative "../bridge/turn_drawings"
require_relative "../log"

module Samagotchi
  class Engine
    # A failed block asked for again (docs/internals/block-renderers.md, A
    # failed block is asked for again). #fix_block answers the Bridge's
    # route and starts the side request; its result waits in
    # @block_fix_ready until the worker's loop, between turns, calls
    # #apply_block_fixes, which writes the conversation: the answer's text
    # when no turn started since the ask and it is still the newest answer,
    # else its display only, or nothing when the answer is gone.
    # Writes @block_fix_running, @block_fix_ready, @block_fix_turns (under
    # @block_fix_mutex; the counter on the turn thread), reads @session,
    # @side_judgments, @session_observer.
    module BlockFixPart
      # What a pending result knows of its answer: its place in the
      # conversation, its digest then (Bridge::TurnDrawings.digest), and the
      # turn counter then (nil: a turn was running as it was asked).
      Anchor = Data.define(:index, :digest, :turns)
      # A finished ask: +fixed+ (the new source) or +reason+ (why not).
      Result = Data.define(:turn_id, :lang, :key, :source, :fixed, :reason, :anchor, :started) do
        def fixed? = !fixed.nil?
      end

      # The worker's wake (Waker#wake), called once a result waits: an idle
      # worker applies it at once. nil (the default): nothing is woken.
      def block_fix_ready=(callback)
        @block_fix_wake = callback
      end

      # The Bridge's POST blocks/fix: whether +source+, a +lang+ block of
      # +turn_id+'s answer, is asked for again.
      # @return [Array(Integer, Hash)] the status and the body: 200
      #   {state: "fixed" | "failed", reason:} (asked before), 202
      #   {state: "running"}, or an error ({error:, detail:}: 409
      #   fix_unavailable / block_not_found, 413 block_too_large, 429 fix_busy)
      def fix_block(turn_id:, lang:, source:, reason:)
        session = @session
        return block_fix_refused(409, :fix_unavailable) if session.nil? || session.scratch || !BlockFix.available?
        return block_fix_refused(413, :block_too_large) if source.to_s.bytesize > BlockFix::MAX_SOURCE_BYTES

        # The counter before the running flag: a turn sets the flag, then
        # counts (#note_block_fix_turn), so one starting between the reads
        # still shows as a change. The running turn ending with this answer
        # (the page asks on its end event, before its hooks are done) is no
        # turn since; any other running turn is.
        turns = @block_fix_turns
        turns = nil if turn_running? && turn_context&.id.to_s != turn_id.to_s
        messages = session.messages
        answer = AnswerTail.find(messages, turn_id: turn_id)
        index = answer && messages.index { |message| message.equal?(answer) }
        return block_fix_refused(409, :block_not_found) unless index && BlockFix.locate(block_fix_shown(answer), lang: lang, source: source)

        key = BlockFix.key(lang, source)
        @block_fix_mutex.synchronize do
          known = BlockFix.stamp_for(answer, key)
          return [200, block_fix_known(known, key)] if known
          return [202, { state: "running" }] if @block_fix_running.include?(key) || @block_fix_ready.any? { |r| r.key == key }
          return block_fix_refused(429, :fix_busy) if @block_fix_running.size >= BlockFix::MAX_RUNNING

          @block_fix_running << key
        end
        anchor = Anchor.new(index: index, digest: Bridge::TurnDrawings.digest(answer), turns: turns)
        conversation = AnswerDisplay.strip_all(messages[0..index])
        Log.info(:model, "block_fix_asked", lang: lang, key: key, bytes: source.to_s.bytesize)
        start_block_fix(conversation, turn_id: turn_id.to_s, lang: lang.to_s, key: key, source: source.to_s,
                                      reason: reason.to_s, anchor: anchor)
        [202, { state: "running" }]
      end

      # The results waiting, applied: on the worker's loop, between turns
      # (a running turn holds its own copy of the conversation and writes it
      # back at its end). The caller saves the session when this is > 0.
      # @return [Integer] how many changed the conversation
      def apply_block_fixes
        return 0 if turn_running? || @session.nil?

        ready = @block_fix_mutex.synchronize { @block_fix_ready.slice!(0..) }
        return 0 if ready.empty?

        synchronize_events { ready.count { |result| apply_block_fix(@session, result) } }
      end

      # The block fix's keys still asked for (specs).
      def block_fixes_running = @block_fix_mutex.synchronize { @block_fix_running.dup }

      private

      def init_block_fix
        @block_fix_mutex = Mutex.new
        @block_fix_running = []
        @block_fix_ready = []
        @block_fix_turns = 0
        @block_fix_wake = nil
      end

      # A turn takes its messages (#turn_messages): a fix asked before it
      # lands in the answer's display only.
      def note_block_fix_turn
        @block_fix_turns += 1
      end

      def block_fix_refused(status, code)
        [status, { error: code.to_s, detail: BlockFix::REFUSALS.fetch(code) }]
      end

      # A block the answer's stamp knows: asked before. A block that is the
      # fix of an earlier one fails again: failed, whatever that fix was.
      def block_fix_known(entry, key)
        return { state: "failed", reason: "it failed again after a fix" } if entry[:fixed_key] == key && entry[:key] != key

        { state: entry[:state].to_s, reason: entry[:reason] }.compact
      end

      # The text the page draws an answer from.
      def block_fix_shown(message)
        (message[AnswerDisplay::KEY] || message[AnswerDisplay::KEY.to_s] || message[:content] || message["content"]).to_s
      end

      def start_block_fix(conversation, **job)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        warn = ->(error) { Log.warn(:model, "block_fix_thread_failed", error: error.class.name, msg: error.message.to_s[0, 200]) }
        @side_judgments.aside(warn: warn) do
          result = begin
            ask_block_fix(conversation, **job, started: started)
          rescue StandardError => e
            Result.new(**job.except(:reason), started: started, fixed: nil,
                                              reason: e.message.to_s.lines.first.to_s.strip[0, 200])
          end
          @block_fix_mutex.synchronize do
            @block_fix_running.delete(job[:key])
            @block_fix_ready << result
          end
          @block_fix_wake&.call
        end
      end

      def ask_block_fix(conversation, turn_id:, lang:, key:, source:, reason:, anchor:, started:)
        request = BlockFix.request(messages: conversation, lang: lang, source: source, reason: reason)
        answer = ask_side_model(request, timeout: BlockFix::TIMEOUT_SECONDS, max_tokens: BlockFix::MAX_TOKENS,
                                         cancel_controller: nil, source: BlockFix::SOURCE, whole: true)
        extracted = BlockFix.extract(answer.text, cut_off: answer.cut_off, failed: source)
        refusal = extracted.refusal || BlockFix.check(lang: lang, source: extracted.source)
        Result.new(turn_id: turn_id, lang: lang, key: key, source: source, anchor: anchor, started: started,
                   fixed: refusal ? nil : extracted.source, reason: refusal)
      end

      # One result, under the event lock.
      # @return [Boolean] whether the conversation changed
      def apply_block_fix(session, result)
        messages = session.messages
        answer = messages[result.anchor.index]
        place = answer && block_fix_anchored?(messages, answer, result) &&
                BlockFix.locate(block_fix_shown(answer), lang: result.lang, source: result.source)
        return block_fix_dropped(result, "the answer changed") unless place

        copy, landed = block_fix_patched(messages, answer, result)
        return block_fix_dropped(result, "the fix is too long") unless copy

        list = messages.dup
        list[result.anchor.index] = copy
        replace_session_messages(session, list)
        block_fix_announce(result, state: result.fixed? ? "fixed" : "failed", landed: landed,
                                   was_digest: result.anchor.digest, digest: Bridge::TurnDrawings.digest(copy))
        true
      end

      # Still the message asked about: the same digest, and still the one
      # the turn id names (a reminder turn's id names no prompt, so it falls
      # back to the newest answer, which a later turn's answer becomes).
      def block_fix_anchored?(messages, answer, result)
        Bridge::TurnDrawings.digest(answer) == result.anchor.digest &&
          AnswerTail.find(messages, turn_id: result.turn_id).equal?(answer)
      end

      # The answer's copy with the fix (or, for a failed ask, only the stamp)
      # and where it landed ("answer", "display", nil); nil copy: refused.
      def block_fix_patched(messages, answer, result)
        unless result.fixed?
          entry = BlockFix.entry(key: result.key, state: "failed", reason: result.reason)
          return [BlockFix.with_stamp(answer, entry), nil]
        end

        copy, landed = if result.anchor.turns == @block_fix_turns && AnswerTail.find(messages).equal?(answer)
                         block_fix_in_answer(answer, result)
                       else
                         block_fix_in_display(answer, result)
                       end
        return [nil, nil] unless copy

        entry = BlockFix.entry(key: result.key, fixed_key: BlockFix.key(result.lang, result.fixed), state: "fixed")
        [BlockFix.with_stamp(copy, entry), landed]
      end

      # No turn since, the newest answer: its text (and its display, and
      # on api: anthropic its saved blocks) holds the fix.
      def block_fix_in_answer(answer, result)
        content = answer[:content].to_s
        place = BlockFix.locate(content, lang: result.lang, source: result.source)
        return block_fix_in_display(answer, result) unless place

        copy = answer.merge(content: BlockFix.replace(content, place, result.fixed))
        if (display = answer[AnswerDisplay::KEY])
          shown = BlockFix.locate(display, lang: result.lang, source: result.source)
          copy[AnswerDisplay::KEY] = BlockFix.replace(display, shown, result.fixed) if shown
        end
        [block_fix_blocks(copy, result), "answer"]
      end

      # A turn since: only what the page renders (`display`), never what a
      # model was sent.
      def block_fix_in_display(answer, result)
        shown = block_fix_shown(answer)
        place = BlockFix.locate(shown, lang: result.lang, source: result.source)
        return [nil, nil] unless place

        text = BlockFix.replace(shown, place, result.fixed)
        return [nil, nil] if text.length > AnswerDisplay::MAX_CHARS

        [answer.merge(AnswerDisplay::KEY => text), "display"]
      end

      # The saved Messages-API blocks (anthropic_content), which
      # AnthropicWire sends as they are: the text block holding the fix
      # patched, or the blocks dropped (the answer goes as its text) when
      # no one text block holds it whole. A thinking block is never touched.
      def block_fix_blocks(copy, result)
        blocks = copy[:anthropic_content]
        return copy unless blocks.is_a?(Array) && !blocks.empty?

        found = false
        patched = blocks.map do |block|
          next block if found || !block.is_a?(Hash) || (block["type"] || block[:type]).to_s != "text"

          text_key = block.key?("text") ? "text" : :text
          place = BlockFix.locate(block[text_key].to_s, lang: result.lang, source: result.source)
          next block unless place

          found = true
          block.merge(text_key => BlockFix.replace(block[text_key].to_s, place, result.fixed))
        end
        found ? copy.merge(anthropic_content: patched) : copy.except(:anthropic_content)
      end

      def block_fix_dropped(result, why)
        block_fix_announce(result, state: "dropped", landed: nil, reason: why)
        false
      end

      def block_fix_announce(result, state:, landed:, reason: result.reason, was_digest: nil, digest: nil)
        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - result.started) * 1000).round
        Log.info(:model, "block_fix_#{state}", lang: result.lang, key: result.key, bytes: result.fixed.to_s.bytesize,
                                               ms: ms, landed: landed, reason: reason)
        @session_observer.notify({ type: :block_fix, turn_id: result.turn_id, key: result.key, lang: result.lang,
                                   state: state, landed: landed, reason: reason, was_digest: was_digest,
                                   digest: digest }.compact)
      end
    end
  end
end
