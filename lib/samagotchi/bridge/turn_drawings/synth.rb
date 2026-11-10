# frozen_string_literal: true

require "digest"
require "json"
require_relative "../../context_note"
require_relative "../../degrade"
require_relative "../../message_parts"
require_relative "../../message_time"
require_relative "../../output_formatter"
require_relative "../../revise_anchor"
require_relative "../../steer"
require_relative "../../tool_activity"
require_relative "../../tool_row_fields"
require_relative "../../turn_note"
require_relative "../../verify_anchor"
require_relative "../turn_accumulator"
require_relative "../turn_drawings"
require_relative "../turn_notice"
require_relative "../turn_ranges"

module Samagotchi
  class Bridge
    class TurnDrawings
      # A drawing made from a finished turn's saved messages, for a turn no
      # live-written line covers (a turn from before drawings, a fork's, a
      # one-shot's, one past what was drawn): the events live would have
      # emitted for it, folded by a fresh TurnAccumulator, so every drawing
      # comes from the one fold (H3 step L). Pure: the messages, the turn's
      # range (TurnRanges), its turn record and tool records (the session's
      # timing: kind, durations, statuses) and CardStore's entries of the
      # turn (`of_turn`: its cards, hook notices, retries, steer cuts, ✂
      # rows and questions), each at the step it names.
      #
      # What the messages and records don't keep is lost (LOSSES); the drift
      # spec makes each :row event say whether it is synthesized or lost.
      module Synth
        # The :row events (Events::CLASSIFICATION) a synthesized drawing
        # makes again, from the messages, the records or CardStore.
        SYNTHESIZED = %i[turn_started generation_started generation_chunk tool_call_started tool_call_completed
                         pending_input_merged merged_input reminder_injected card hook_notice empty_answer_retry
                         steer_cut llm_context_edited question_requested question_answered question_cancelled
                         turn_completed turn_canceled turn_failed].freeze
        # What a synthesized drawing can't have (each with why), by the key
        # its absence shows in: the drawing's or a part's.
        # A :row event no synthesized drawing has goes here by its type
        # (events_drift_spec checks every :row is one or the other).
        LOSSES = {
          context_added: "a context note: no turn's row, the page draws it from the messages, drawing or not",
          origin: "who sent the prompt (TurnOrigin) is on the live event only",
          input_origins: "a merged line's senders (input_merged) are on the live event only",
          empty_step_thinking: "the thinking of a step that streamed nothing visible and was asked again " \
                               "(kept only on an empty answer's marker)",
          reminder_details: "a reminder's description and interval: the line shows its name",
          evicted_entries: "a card, hook notice or row CardStore pushed out (CAPACITY) or never saw",
          untimed: "a tool's duration and status with no tool record (its status read from its output)",
          tool_action: "a plugin tool's own action words (its label when saved, else 'calling tool')",
          wake_start: "a wake turn's start time when no message of its own is stamped: its note's, written before it began",
          failure_detail: "a failed turn's error message and class when its record keeps a summary (SessionMetrics#failure_fields)",
          repeated_turn_id: "a range whose turn id an earlier one has (…~N): no record, no CardStore entries (whose they are " \
                            "can't be told)",
          continued_steps: "a Continue's steps right after its turn read as that turn's (no message tells them apart): " \
                           "the turn's record and kind, the Continue's calls untimed, its own CardStore entries left out",
          unopened_turn: "a turn with no opening (a reminder's, a Continue's) has no id in the messages: a made-up one, " \
                         "and no record to pair by"
        }.freeze

        # A Synth line that couldn't be made (its minimal line stands in).
        class Error < StandardError; end

        # Lines by key, least recently used out first past +budget+ bytes
        # (each line's JSON size): a long session's turns, a few sessions.
        class Memo
          def initialize(budget:)
            @budget = budget
            @lines = {}
            @bytes = 0
            @mutex = Mutex.new
          end

          attr_reader :bytes

          def size = @mutex.synchronize { @lines.size }

          # The line for +key+, made by the block (outside the lock) when
          # not kept.
          def fetch(key)
            hit = @mutex.synchronize do
              entry = @lines.delete(key)
              @lines[key] = entry if entry
              entry
            end
            return hit[0] if hit

            line = yield
            store(key, line, JSON.generate(line.to_h).bytesize)
            line
          end

          def clear = @mutex.synchronize { @lines.clear.tap { @bytes = 0 } }

          private

          def store(key, line, bytes)
            @mutex.synchronize do
              old = @lines.delete(key)
              @bytes -= old[1] if old
              @lines[key] = [line, bytes]
              @bytes += bytes
              while @bytes > @budget && @lines.size > 1
                _, (_, gone) = @lines.shift
                @bytes -= gone
              end
            end
          end
        end

        # The synthesized lines chi web keeps (MEMO_BYTES of their JSON).
        MEMO_BYTES = 32 * 1024 * 1024
        MEMO = Memo.new(budget: MEMO_BYTES)

        module_function

        # @param messages [Array<Hash>] the session's messages (symbol or string keys)
        # @param range [TurnRanges::Range] the turn's
        # @param record [Hash, nil] its turn record (TurnRanges.records)
        # @param tools [Array<Hash>] the session's tool records (its own are taken by turn id)
        # @param entries [Array<Hash>] CardStore's listed entries (its own by of_turn)
        # @param cwd [String, nil] the session's working directory (tool titles)
        # @return [Line]
        def line(messages, range, record: nil, tools: [], entries: [], cwd: nil)
          list = Array(messages)
          record &&= TurnAccumulator.from_wire(record)
          own_tools = own_tool_records(tools, record, range)
          own_entries = own_entries(entries, range)
          events, untimed = Events.new(list, range, record, own_tools, own_entries, cwd).build
          turn, end_event = fold(events)
          untimed.each do |key|
            part = turn[:parts].find { |p| p[:kind] == "tool" && [p[:iteration], p[:call_index]] == key }
            part&.delete(:duration_ms)
          end
          line_of(list, range, turn, end_event, record)
        end

        # The line that stands in when #line raises: the turn's opening and
        # its end's kind, no parts. Logged once (turn_synth_failed).
        # @return [Line]
        def safe_line(messages, range, record: nil, tools: [], entries: [], cwd: nil)
          line(messages, range, record: record, tools: tools, entries: entries, cwd: cwd)
        rescue StandardError => e
          Degrade.note(:web, "turn_synth_failed", e, from: range.from, to: range.to)
          begin
            minimal(messages, range, record: record)
          rescue StandardError => again
            Degrade.note(:web, "turn_synth_minimal_failed", again, from: range.from, to: range.to)
            constant(messages, range)
          end
        end

        # The line that never fails: the range, its id, a completed end, no
        # parts, read from nothing but the range (its ends' digests, when
        # they can be made).
        # @return [Line]
        def constant(messages, range)
          list = Array(messages)
          digest = ->(message) { Degrade.call(:web, "turn_synth_digest_failed", fallback: "") { TurnDrawings.digest(message) } }
          Line.new(v: VERSION, turn_id: range.id.to_s, kind: "completed", from: range.from, to: range.to,
                   from_digest: digest.call(list[range.from]), to_digest: digest.call(list[range.to - 1]),
                   drawing: { "prompt" => nil, "turn_id" => range.id.to_s, "parts" => [] }, end: { "type" => "turn_completed" })
        end

        # CardStore's listing fields that change with later turns (where an
        # entry reads on the page), not with what the turn showed.
        LISTING_KEYS = %i[turns_since current earlier opening_id during after_failed label].freeze

        # #safe_line, kept per range in MEMO: a finished turn's range doesn't
        # change, so a show after a turn end makes no old turn again. The key
        # names everything the line is made from: the session, the range and
        # every message's digest in it (an edit anywhere inside it, a plugin's
        # replace_messages, misses), the turn's records and its CardStore
        # entries without their listing fields (a later turn changes those).
        # @return [Line]
        def memoized(session_id, messages, range, record: nil, tools: [], entries: [], cwd: nil)
          list = Array(messages)
          own = record && Array(tools).select { |t| t.is_a?(Hash) && (t[:turn_id] || t["turn_id"]) == (record[:id] || record["id"]) }
          mine = own_entries(entries, range).map { |e| e.except(*LISTING_KEYS) }
          body = Digest::SHA1.hexdigest(list[range.from...range.to].to_a.map { |m| TurnDrawings.digest(m) }.join)
          key = [session_id.to_s, range.from, range.to, range.id, body, Digest::SHA1.hexdigest(JSON.generate([record, own, mine, cwd]))]
          MEMO.fetch(key) { safe_line(list, range, record: record, tools: tools, entries: entries, cwd: cwd) }
        end

        # @return [Line]
        def minimal(messages, range, record: nil)
          list = Array(messages)
          record &&= TurnAccumulator.from_wire(record)
          events = Events.new(list, range, record, [], [], nil)
          line_of(list, range, events.started.merge(parts: []), events.ending, record)
        end

        # A turn's CardStore entries: its own turn id's (of_turn), none for a
        # range whose id repeats an earlier one's (…~N: whose they are can't
        # be told).
        def own_entries(entries, range)
          return [] unless range.own_id?

          Array(entries).filter_map { |e| TurnAccumulator.from_wire(e) if e.is_a?(Hash) }.select { |e| e[:of_turn] == range.turn_id }
        end
        private_class_method :own_entries

        # The fold raises what it can't fold (raise_errors:), so a bad event
        # fails the line (safe_line logs it) instead of dropping its row.
        def fold(events)
          captured = nil
          accumulator = TurnAccumulator.new(clock: -> { 0.0 }, raise_errors: true,
                                            on_turn_end: ->(turn, ending) { captured = [turn, ending] })
          events.each { |event| accumulator.call(event) }
          raise Error, "the fold drew no turn" unless captured

          captured
        end
        private_class_method :fold

        def line_of(list, range, turn, end_event, record)
          ending = TurnDrawings.end_of(end_event)
          ending[:record_id] = record[:id] if record && record[:id]
          Line.new(v: VERSION, turn_id: range.id, kind: KINDS[end_event[:type].to_s] || end_event[:type].to_s,
                   from: range.from, to: range.to,
                   from_digest: TurnDrawings.digest(list[range.from]), to_digest: TurnDrawings.digest(list[range.to - 1]),
                   drawing: JSON.parse(JSON.generate(TurnDrawings.scrub(turn.slice(*DRAWING_KEYS)))),
                   end: JSON.parse(JSON.generate(TurnDrawings.scrub(ending))))
        end
        private_class_method :line_of

        # The turn's tool records: those of its record's id, else its own
        # turn id's (a caller's records of the turn, no turn record saved).
        def own_tool_records(tools, record, range)
          id = (record && record[:id]) || (range.turn_id if range.own_id?)
          return [] unless id

          Array(tools).filter_map { |t| TurnAccumulator.from_wire(t) if t.is_a?(Hash) }
                      .select { |t| t[:turn_id] == id }
                      .sort_by { |t| [t[:iteration].to_i, t[:call_index].to_i] }
        end
        private_class_method :own_tool_records

        # One turn's event stream, built once (#build).
        class Events
          END_TYPES = { "completed" => :turn_completed, "canceled" => :turn_canceled, "failed" => :turn_failed }.freeze
          ROW_TYPES = %i[hook_notice empty_answer_retry steer_cut llm_context_edited].freeze
          # A step no saved message holds: one the loop asked again.
          REDONE = %i[empty_answer_retry steer_cut].freeze
          REMINDER_NAME = /\A\s*(?:-\s*)?([^:\n]+?):/

          def initialize(list, range, record, tools, entries, cwd)
            @list = list
            @range = range
            @record = record
            @pool = tools.dup
            @entries = entries
            @cwd = cwd
            @opening = range.opening && list[range.opening]
            @marks = MessageParts.edit_marks(list)
          end

          # @return [Array(Array<Hash>, Array<Array>)] the events, and the
          #   [iteration, call_index] of each tool with no record (no duration)
          def build
            @events = [started]
            @untimed = []
            @iteration = 0
            @placed = []
            @marker = nil
            @last_tools = false
            empties = marker_steps
            own_messages.each do |message|
              step(message, empties)
            end
            redone_steps(Float::INFINITY, empties)
            # The empty answer's last steps: no message holds them.
            empties.each do |thinking|
              @iteration += 1
              @events << { type: :generation_started, iteration: @iteration }
              @events << { type: :generation_chunk, iteration: @iteration, text: "", thinking: thinking } unless thinking.empty?
              place_at(@iteration, 0)
            end
            @events << { type: :generation_started, iteration: @iteration + 1 } if kind == "failed" && @last_tools
            leftover = @entries.reject { |entry| @placed.include?(entry) }
            leftover.each { |entry| place(entry) }
            @events << ending
            [@events, @untimed]
          end

          def started
            prompt = prompt_message
            event = { type: :turn_started, prompt: prompt && content_of(prompt), turn_id: @range.id, origin: nil,
                      continue: @record ? @record[:continue] == true : false }
            event[:resumed] = true if @record && @record[:resumed] == true
            # A wake's note was written before its turn began: the turn's
            # first stamped message is nearer its start.
            inside = @opening && @range.opening >= @range.from
            at = MessageTime.of(inside ? @opening : (own_messages.find { |m| MessageTime.of(m) } || @opening))
            event[:at] = at.to_s if at
            images = prompt && fetch(prompt, :images)
            event[:images] = images if images.is_a?(Array) && !images.empty?
            source = prompt || (@opening if user?(@opening))
            Steer::AUTHOR_KEYS.each { |key| event[key] = fetch(source, key) if source && fetch(source, key) }
            event
          end

          def ending
            type = END_TYPES.fetch(kind)
            event = { type: type, kept_from: @range.from, kept_to: @range.to }
            event[:turn_id] = @range.id if @range.own_id?
            if @record
              event[:duration_ms] = @record[:duration_ms] if @record[:duration_ms].is_a?(Integer)
              event[:cancellation_reason] = @record[:cancellation_reason] if @record[:cancellation_reason]
              event[:cancelled_by] = @record[:cancelled_by] if @record[:cancelled_by]
              event.merge!(@record[:failure].slice(:summary, :message, :error_class, :kept_steps)) if @record[:failure].is_a?(Hash)
            end
            if @opening
              revises = ReviseAnchor.from(fetch(@opening, :revises))
              event[:revises] = revises.to_h if revises
              event[:verify] = true if VerifyAnchor.from(fetch(@opening, :verify))
            end
            empty = marker
            event[:turn_summary] = { empty_answer: empty.slice(:retries, :refusal) } if empty
            event
          end

          private

          # completed, canceled or failed: the record's, else the turn's own
          # note's (a cancel's, a failure's), else completed.
          def kind
            status = @record && @record[:status].to_s
            # A failed record saved before its failure field says nothing a
            # failure's line is made of: the turn's own note decides.
            return status if END_TYPES.key?(status) && !(status == "failed" && !@record[:failure].is_a?(Hash))

            # Only the turn's own ending: a note that is its last message.
            last = own_messages.last
            note = last if TurnNote.note?(last) && !TurnNote.empty_answer(last)
            text = note && fetch(note, :content).to_s
            return "canceled" if text&.start_with?("#{TurnNote::OPEN}the previous turn was cancelled")
            return "failed" if text&.start_with?(TurnNote::OPEN + TurnNote::FAILED, TurnNote::OPEN + TurnNote::FAILED_AFTER)

            "completed"
          end

          # The range's messages (a damaged file's non-Hash entries left out).
          def own_messages = @list[@range.from...@range.to].to_a.grep(Hash)

          # The prompt the turn opened with: a user message, not a wake's
          # report (an input: the turn's first merged line) or note.
          def prompt_message
            return nil unless @opening && user?(@opening) && !Steer.input?(@opening)

            @opening
          end

          def step(message, empties)
            return if message.equal?(prompt_message)

            role = fetch(message, :role).to_s
            if role == "system"
              system_message(message)
            elsif Steer.steer?(message)
              @events << { type: :pending_input_merged, iteration: step_of(message), count: 0, content: nil,
                           steers: [{ source: fetch(message, :source).to_s, text: fetch(message, :content).to_s }] }
            elsif Steer.input?(message)
              input = { type: :pending_input_merged, iteration: step_of(message), count: 1, content: fetch(message, :content).to_s,
                        steers: [] }
              Steer::AUTHOR_KEYS.each { |key| input[key] = fetch(message, key) if fetch(message, key) }
              @events << input
            elsif %w[model assistant].include?(role)
              model_step(message, empties)
            end
          end

          def system_message(message)
            if TurnNote.empty_answer(message)
              @marker = TurnNote.empty_answer(message)
            elsif !ContextNote.note?(message) && !TurnNote.note?(message) &&
                  fetch(message, :content).to_s.start_with?(TurnRanges::REMINDER)
              @events << { type: :reminder_injected, reminders: reminder_names(fetch(message, :content).to_s) }
            end
          end

          def model_step(message, empties)
            redone_steps(@iteration + 1, empties)
            @iteration += 1
            n = @iteration
            index = @list.index { |m| m.equal?(message) }
            parts = MessageParts.for_message(message, responses_after(index), cwd: @cwd, marks: @marks) || {}
            text = OutputFormatter.strip_markup(fetch(message, :content).to_s)
            thinking = parts[:thinking].to_s
            thinking = empties.shift.to_s if thinking.empty? && text.empty? && parts[:tools].to_a.empty? && !empties.empty?
            @events << { type: :generation_started, iteration: n }
            @events << { type: :generation_chunk, iteration: n, text: "", thinking: thinking } unless thinking.empty?
            @events << { type: :generation_chunk, iteration: n, text: text, thinking: "" } unless text.empty?
            place_at(n, 0)
            tools = parts[:tools].to_a
            tools.each_with_index { |tool, j| tool_events(tool, n, j + 1) }
            @last_tools = !tools.empty?
          end

          # The steps before +upto+ that left no message: each one a retry
          # or a steer's cut asked again (CardStore's rows name them), with
          # its thinking when the empty answer's marker kept it.
          def redone_steps(upto, empties)
            loop do
              n = @iteration + 1
              break if n > upto
              break unless @entries.any? { |e| REDONE.include?(e[:type]&.to_sym) && e[:iteration].to_i == n && !@placed.include?(e) }

              # The step a saved message holds is the one at +upto+ itself
              # unless a retry names it: then it was the one asked again.
              @iteration = n
              @events << { type: :generation_started, iteration: n }
              thinking = empties.shift.to_s
              @events << { type: :generation_chunk, iteration: n, text: "", thinking: thinking } unless thinking.empty?
              place_at(n, 0)
            end
          end

          def tool_events(part, iteration, index)
            rec = take_record(part[:tool])
            call = { iteration: iteration, call_index: index, tool: part[:tool] }
            call[:label] = part[:label] if part[:label]
            call[:tool_id] = part[:tool_id] if part[:tool_id]
            title = part.slice(*ToolRowFields::ACTIVITY_KEYS).compact
            view = part.slice(*ToolRowFields::EVENT_KEYS).compact
            @events << { type: :tool_call_started, **call, params: part[:params], **title, **view }
            place_at(iteration, index)
            activity = { tool: part[:tool], status: (rec && rec[:status]&.to_s) || status_of(part),
                         params: part[:params], **title,
                         action: part[:label] || ToolActivity.tool_activity_action(part[:tool]) }
            activity[:no_match] = true if rec && rec[:no_match]
            activity[:guardrail] = rec[:guardrail].merge(decided_by: "system one") if rec && rec[:guardrail].is_a?(Hash)
            output = part[:output].to_s
            completed = { type: :tool_call_completed, **call, output: output, preview: output,
                          output_truncated: part[:output_truncated] ? true : false, activity: activity, **view }
            if rec && rec[:duration_ms].is_a?(Integer)
              completed[:duration_ms] = rec[:duration_ms]
            else
              @untimed << [iteration, index]
            end
            completed[:diff] = part[:diff] if part[:diff]
            completed[:images] = part[:images] if part[:images]
            @events << completed
          end

          # A call's status with no record of it, from its saved output as a
          # reload always read it: "no result" for a call the turn never
          # answered, "blocked" for a guardrail's deny, else the live rule
          # (a grep that found nothing is ok).
          def status_of(part)
            return "no result" if part[:output].nil?

            text = ToolActivity.saved_result_text(part[:output])
            return "blocked" if ToolActivity.guardrail_denied?(text)

            command = part.dig(:view, :truncated) ? nil : part.dig(:view, :command)
            ToolActivity.tool_activity_status(text, part[:tool], command: command)
          end

          # The turn's next tool record of +tool+, in call order, with the
          # ones it skipped (the page's timing.js takeRecord).
          def take_record(tool)
            at = @pool.index { |r| r[:tool].to_s == tool.to_s }
            return nil unless at

            @pool.shift(at + 1).last
          end

          # The entries a step names (+iteration+, +calls+: the tool it came
          # after; 0 for before any), in CardStore's order.
          def place_at(iteration, calls)
            @entries.each do |entry|
              next if @placed.include?(entry)
              next unless entry[:iteration].to_i == iteration && entry[:calls].to_i == calls

              place(entry)
            end
          end

          def place(entry)
            @placed << entry
            type = entry[:type]&.to_sym
            if type == :card
              @events << entry.slice(:id, :source, :title, :body, :level, :actions).merge(type: :card, in_turn: true)
            elsif ROW_TYPES.include?(type)
              @events << { type: type, **entry.slice(*TurnNotice::FIELDS.fetch(type)) }
            elsif type == :question && entry[:pending_question].is_a?(Hash)
              question(entry)
            end
          end

          def question(entry)
            pending = entry[:pending_question]
            @events << { type: :question_requested, pending_question: pending }
            if entry.key?(:answer)
              @events << { type: :question_answered, id: pending[:id], answer: entry[:answer] }
            elsif entry[:cancelled]
              @events << { type: :question_cancelled, id: pending[:id], reason: entry[:reason] }
            end
          end

          # The tool_response messages right after the model message at +index+.
          def responses_after(index)
            return [] unless index

            @list[(index + 1)...@range.to].to_a.take_while { |m| fetch(m, :role).to_s == "tool_response" }
          end

          # The empty steps' thinking the empty answer's marker kept, in order.
          def marker_steps
            empty = marker
            Array(empty && empty[:steps]).map { |s| (s.is_a?(Hash) ? (s[:thinking] || s["thinking"]) : nil).to_s }
          end

          def marker
            own_messages.each { |m| (found = TurnNote.empty_answer(m)) && (return TurnAccumulator.from_wire(found)) }
            nil
          end

          # The step that read a steer or a merged line (the server's count):
          # its saved step, else one past the model messages before it.
          def step_of(message)
            saved = fetch(message, :step)
            saved.is_a?(Integer) ? saved : @iteration + 1
          end

          def reminder_names(content)
            lines = content.lines.drop(1).take_while { |l| !l.start_with?("[END REMINDERS]") }
            lines.filter_map { |l| (name = l[REMINDER_NAME, 1]) && { name: name.strip } }
          end

          def content_of(message)
            content = fetch(message, :content)
            content.is_a?(String) ? content : content.to_s
          end

          def user?(message) = message.is_a?(Hash) && fetch(message, :role).to_s == "user"

          def fetch(hash, key)
            return nil unless hash.is_a?(Hash)

            hash.key?(key) ? hash[key] : hash[key.to_s]
          end
        end
        private_constant :Events
      end
    end
  end
end
