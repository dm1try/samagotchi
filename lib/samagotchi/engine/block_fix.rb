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
    # @side_judgments, @event_log.
    module BlockFixPart
      # What a pending result knows of its answer: its place in the
      # conversation, its digest then (Bridge::TurnDrawings.digest), and the
      # turn counter then (nil: a turn was running as it was asked).
      Anchor = Data.define(:index, :digest, :turns)
      MOVED_DIGEST_LIMIT = 64
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
      #   fix_unavailable / block_not_found, 413 block_too_large, 429
      #   fix_limit (BlockFix::PER_ANSWER) / fix_busy)
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
        return block_fix_refused(409, :block_not_found) unless index

        key = BlockFix.key(lang, source)
        shown = !BlockFix.locate(block_fix_shown(answer), lang: lang, source: source).nil?
        # The stamp before the text: a page that drew the answer before its
        # fix (a second tab) asks for a block no longer in it, and is told
        # fixed (it reads the answer again).
        known = BlockFix.stamp_for(answer, key)
        return [200, block_fix_known(known, key, shown: shown)] if known
        return block_fix_refused(409, :block_not_found) unless shown

        # In flight per answer and block: the same block in a newer answer
        # is that answer's own ask (its result lands in it, its event names it).
        asking = [index, key]
        @block_fix_mutex.synchronize do
          return [202, { state: "running", key: key }] if block_fix_pending?(asking)
          return block_fix_refused(429, :fix_limit) if block_fix_asked(answer, index) >= BlockFix::PER_ANSWER
          return block_fix_refused(429, :fix_busy) if @block_fix_running.size >= BlockFix::MAX_RUNNING

          @block_fix_running << asking
        end
        anchor = Anchor.new(index: index, digest: Bridge::TurnDrawings.digest(answer), turns: turns)
        conversation = AnswerDisplay.strip_all(messages[0..index])
        Log.info(:model, "block_fix_asked", lang: lang, key: key, bytes: source.to_s.bytesize)
        start_block_fix(conversation, turn_id: turn_id.to_s, lang: lang.to_s, key: key, source: source.to_s,
                                      reason: reason.to_s, anchor: anchor)
        [202, { state: "running", key: key }]
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

      # The block fix's [answer index, key] pairs still asked for (specs).
      def block_fixes_running = @block_fix_mutex.synchronize { @block_fix_running.dup }

      private

      def init_block_fix
        @block_fix_mutex = Mutex.new
        @block_fix_running = []
        @block_fix_ready = []
        @block_fix_turns = 0
        @block_fix_wake = nil
        # An answer's digest before a fix in its text => after (on the loop
        # thread): the other block of the same answer, asked before that fix
        # landed, still knows its answer.
        @block_fix_moved = {}
      end

      # A turn takes its messages (#turn_messages): a fix asked before it
      # lands in the answer's display only.
      def note_block_fix_turn
        @block_fix_turns += 1
      end

      # Whether [answer index, key] is asked for or its result waits (under
      # @block_fix_mutex).
      def block_fix_pending?(asking)
        @block_fix_running.include?(asking) || @block_fix_ready.any? { |r| [r.anchor.index, r.key] == asking }
      end

      # How many blocks of the answer at +index+ were asked for: its stamp's
      # and those in flight or waiting (under @block_fix_mutex). The stamp
      # is on the message, so the count holds across a page's reload.
      def block_fix_asked(answer, index)
        keys = BlockFix.stamps(answer).map { |entry| entry[:key] }
        keys += @block_fix_running.filter_map { |at, key| key if at == index }
        keys += @block_fix_ready.filter_map { |r| r.key if r.anchor.index == index }
        keys.uniq.size
      end

      def block_fix_refused(status, code)
        [status, { error: code.to_s, detail: BlockFix::REFUSALS.fetch(code) }]
      end

      # A block the answer's stamp knows: asked before. A block that is the
      # fix of an earlier one fails again: failed, whatever that fix was. A
      # fixed block still +shown+ (a copy the fix couldn't reach) is failed
      # too: "fixed" would have the page read the answer again, draw the
      # copy, fail it and ask again, with no end.
      def block_fix_known(entry, key, shown:)
        return { state: "failed", reason: "it failed again after a fix" } if entry[:fixed_key] == key && entry[:key] != key
        return { state: "failed", reason: "a copy of it is still in the answer" } if entry[:state].to_s == "fixed" && shown

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
            @block_fix_running.delete([job[:anchor].index, job[:key]])
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
      # A fix that can't land in an answer still there (its shown text lost
      # the block, or the fix would pass the display's size) stamps it
      # failed with the reason, so a reload doesn't ask again; only a gone
      # or changed answer is dropped, with no stamp.
      def apply_block_fix(session, result)
        messages = session.messages
        answer = messages[result.anchor.index]
        return block_fix_dropped(result, "the answer changed") unless answer && block_fix_anchored?(messages, answer, result)

        unless BlockFix.locate(block_fix_shown(answer), lang: result.lang, source: result.source)
          result = result.with(fixed: nil, reason: "the answer changed")
        end
        copy, landed = block_fix_patched(messages, answer, result)
        unless copy
          result = result.with(fixed: nil, reason: "the fix is too long")
          copy, landed = block_fix_patched(messages, answer, result)
        end

        list = messages.dup
        list[result.anchor.index] = copy
        replace_session_messages(session, list)
        was = Bridge::TurnDrawings.digest(answer)
        now = Bridge::TurnDrawings.digest(copy)
        if was != now
          @block_fix_moved.delete(was)
          @block_fix_moved[was] = now
          @block_fix_moved.shift while @block_fix_moved.size > MOVED_DIGEST_LIMIT
        end
        block_fix_announce(result, state: result.fixed? ? "fixed" : "failed", landed: landed, was_digest: was, digest: now)
        true
      end

      # Still the message asked about: the same digest, and still the one
      # the turn id names (a reminder turn's id names no prompt, so it falls
      # back to the newest answer, which a later turn's answer becomes).
      def block_fix_anchored?(messages, answer, result)
        Bridge::TurnDrawings.digest(answer) == block_fix_digest_now(result.anchor.digest) &&
          AnswerTail.find(messages, turn_id: result.turn_id).equal?(answer)
      end

      # +digest+ after the fixes that landed in its answer's text since.
      def block_fix_digest_now(digest)
        seen = []
        while (moved = @block_fix_moved[digest]) && !seen.include?(digest)
          seen << digest
          digest = moved
        end
        digest
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
      # on api: anthropic its saved blocks) holds the fix, in every copy of
      # the block; nil copy: the display would pass its size.
      def block_fix_in_answer(answer, result)
        content = answer[:content].to_s
        places = BlockFix.locate_all(content, lang: result.lang, source: result.source)
        return block_fix_in_display(answer, result) if places.empty?

        copy = answer.merge(content: BlockFix.replace_all(content, places, result.fixed))
        if (display = answer[AnswerDisplay::KEY])
          shown = BlockFix.locate_all(display, lang: result.lang, source: result.source)
          text = shown.empty? ? display : BlockFix.replace_all(display, shown, result.fixed)
          # The display's own cap (AnswerDisplay::MAX_CHARS), as #block_fix_in_display keeps it.
          return [nil, nil] if text.length > AnswerDisplay::MAX_CHARS

          copy[AnswerDisplay::KEY] = text
        end
        [block_fix_blocks(copy, result, places.size), "answer"]
      end

      # A turn since: only what the page renders (`display`), never what a
      # model was sent.
      def block_fix_in_display(answer, result)
        shown = block_fix_shown(answer)
        places = BlockFix.locate_all(shown, lang: result.lang, source: result.source)
        return [nil, nil] if places.empty?

        text = BlockFix.replace_all(shown, places, result.fixed)
        return [nil, nil] if text.length > AnswerDisplay::MAX_CHARS

        [answer.merge(AnswerDisplay::KEY => text), "display"]
      end

      # The saved Messages-API blocks (anthropic_content), which
      # AnthropicWire sends as they are: the text blocks holding the
      # +copies+ the text had patched, or the blocks dropped (the answer goes
      # as its text) when they don't hold every copy whole. A thinking block
      # is never touched.
      def block_fix_blocks(copy, result, copies)
        blocks = copy[:anthropic_content]
        return copy unless blocks.is_a?(Array) && !blocks.empty?

        found = 0
        patched = blocks.map do |block|
          next block if !block.is_a?(Hash) || (block["type"] || block[:type]).to_s != "text"

          text_key = block.key?("text") ? "text" : :text
          places = BlockFix.locate_all(block[text_key].to_s, lang: result.lang, source: result.source)
          next block if places.empty?

          found += places.size
          block.merge(text_key => BlockFix.replace_all(block[text_key].to_s, places, result.fixed))
        end
        found == copies ? copy.merge(anthropic_content: patched) : copy.except(:anthropic_content)
      end

      def block_fix_dropped(result, why)
        block_fix_announce(result, state: "dropped", landed: nil, reason: why)
        false
      end

      def block_fix_announce(result, state:, landed:, reason: result.reason, was_digest: nil, digest: nil)
        ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - result.started) * 1000).round
        Log.info(:model, "block_fix_#{state}", lang: result.lang, key: result.key, bytes: result.fixed.to_s.bytesize,
                                               ms: ms, landed: landed, reason: reason)
        @event_log.notify({ type: :block_fix, turn_id: result.turn_id, key: result.key, lang: result.lang,
                            state: state, landed: landed, reason: reason, was_digest: was_digest,
                            digest: digest }.compact)
      end
    end
  end
end
