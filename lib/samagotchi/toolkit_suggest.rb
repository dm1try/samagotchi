# frozen_string_literal: true

require "json"

require_relative "cancellation_controller"
require_relative "log"
require_relative "message_time"
require_relative "steer"
require_relative "system_one/question"
require_relative "toolkit"

module Samagotchi
  # The first-prompt toolkit classifier and its append-only record.
  # The Engine prepares a Snapshot on its turn thread; #judge only sees that
  # copy, so the question cannot change the running session or tool
  # registry. On mode's turn applies the answer itself (Pending#wait,
  # ToolkitBinding#suggest).
  class ToolkitSuggest
    FILE = "toolkit_suggestions.jsonl"
    QUESTION_ID = "toolkit"
    PROMPT_MAX = 1500
    CHARS_PER_TOKEN = 4.0
    INSTRUCTIONS = "A user is starting a session of a coding agent with the prompt in the state. " \
                   "Which toolkit should the session start on? Pick the smallest toolkit whose tools the work will need."

    # A kit as the ask saw it: its name, classifier description and #rules.
    Candidate = Data.define(:name, :description, :rules)
    # +default+ is a Candidate (no description needed); +core_tools+ the
    # built-ins registered when the ask started.
    Snapshot = Data.define(:session_id, :turn_number, :default, :candidates, :core_tools, :state)
    Suggestion = Data.define(:kit, :raw, :confidence, :decided)
    # One ask's outcome: its Suggestion, what on mode would do with it
    # (suggested, default, defer, below_threshold, invalid, no_judgment)
    # and its log line's fields.
    Judged = Data.define(:suggestion, :would, :fields)

    # The candidates with classifier descriptions, excluding the configured
    # default, the participants' review boundary, the defer sentinel, and a
    # kit that doesn't resolve (a missing base, a cycle): it is left out,
    # not the whole ask, and the ≥ 2 clause counts what is left.
    def self.candidates(kits, default_name:)
      kits.values.filter_map do |kit|
        next if [default_name.to_s, Toolkit::REVIEW, "undecided"].include?(kit.name)
        next if kit.description.to_s.empty?
        next unless resolves?(kit.name, kits)

        kit
      end
    end

    def self.resolves?(name, kits)
      Toolkit.resolve_kit(name, kits)
      true
    rescue Toolkit::Unresolved
      false
    end

    # A System 1 choice and the small, bounded state it classifies.
    def self.question(default:, kits:, project:, prompt:)
      candidates = candidates(kits, default_name: default.name)
      criteria = candidates.to_h { |kit| ["kit:#{kit.name}", "#{kit.name}: #{kit.description}"] }
      criteria["default"] = "none of the other toolkits fits: the user's everyday default"
      criteria["undecided"] = "There is no task yet; defer this choice"
      question = SystemOne::Question.new(id: QUESTION_ID, type: :choice, instructions: INSTRUCTIONS, criteria: criteria)
      [question, { project: project.to_s, prompt: prompt.to_s[0, PROMPT_MAX] }]
    end

    # The single turn eligibility predicate shared by audit and on mode.
    # A later prompt is eligible only inside an undecided defer window.
    # +candidate_count+ and +last_suggestion+ may be callables: they are
    # read only once the session's own clauses pass (the kits read memory
    # files; the suggestion log is read whole), the log only on the defer
    # path, when the session already has a model reply.
    def self.eligible?(session:, prompt:, author:, candidate_count:, last_suggestion:, defer_turns:, defer_tokens:)
      return false unless session&.toolkit_origin == "default"
      return false if session.delegate? || session.review?
      return false if Steer.participant_author?(author)
      return false unless prompt.is_a?(String) && !prompt.strip.empty?
      return false if value(candidate_count).to_i < 2

      messages = Array(session.messages)
      return true unless model_reply?(messages)
      return false unless field(value(last_suggestion), :raw) == "undecided"

      current_turn_number = turn_number(messages)
      current_turn_number <= defer_turns.to_i && conversation_chars(messages) / CHARS_PER_TOKEN < defer_tokens.to_i
    end

    # The conversation's size for the defer window: its messages' text and
    # tool calls, summed (no JSON: a byte that isn't UTF-8 can't break it).
    def self.conversation_chars(messages)
      Array(messages).sum do |message|
        field(message, :content).to_s.length + field(message, :tool_calls).to_s.length
      end
    end

    def self.turn_number(messages) = user_prompt_count(Array(messages)) + 1

    # The owner's own prompt: a user line the Engine kept for a turn (it
    # carries the turn's id), or TurnCheckpoint's line for a turn killed
    # before its first boundary (stamped, no id). A !command's output, a
    # declined continue's reason and KernelLoop's recovery prompt are
    # neither; steers, notes and reminders carry their kind.
    def self.owner_prompt?(message)
      field(message, :role).to_s == "user" &&
        !Steer.participant_author?(field(message, :author)) &&
        !%w[input steer note reminder].include?(field(message, :kind).to_s) &&
        !field(message, :preserve_literals) &&
        !(field(message, :turn_id) || field(message, MessageTime::KEY)).nil?
    end

    # The prior logged suggestion for this session; the log, not process
    # memory, keeps a deferred choice alive across a worker respawn.
    def self.last_suggestion(log, session_id)
      log.records.reverse_each.find do |entry|
        entry["kind"] == "suggestion" && entry["session_id"] == session_id
      end
    end

    # Runs one already-prepared ask and appends its line (audit's thread).
    # @return [Suggestion]
    def self.ask(client:, log:, snapshot:, threshold:, cancel_controller: nil)
      judged = judge(client: client, snapshot: snapshot, threshold: threshold, cancel_controller: cancel_controller)
      record(log, judged)
      judged.suggestion
    end

    # Runs one already-prepared ask: its raw pick, what on mode would do
    # with it, and the log line's fields (every offered kit's #rules, the
    # default's too, so the report can tell a narrower kit that would also
    # have covered the turn). A missing judgment (Client#ask's nil) is a
    # Judged too, would "no_judgment".
    # @raise [LLM::RequestCancelled] the turn stopped while it was asked
    # @return [Judged]
    def self.judge(client:, snapshot:, threshold:, cancel_controller: nil)
      question, = question(default: Toolkit.new(name: snapshot.default.name),
                           kits: snapshot.candidates.to_h { |candidate| [candidate.name, kit_for(candidate)] },
                           project: snapshot.state.fetch(:project), prompt: snapshot.state.fetch(:prompt))
      answer = client.ask(state: snapshot.state, questions: { QUESTION_ID => question },
                          cancel_controller: cancel_controller)&.fetch(QUESTION_ID, nil)
      raw = answer&.choice
      candidate_name = raw.to_s.delete_prefix("kit:")
      candidate = snapshot.candidates.find { |item| item.name == candidate_name } if raw.to_s.start_with?("kit:")
      selected = if raw == "default"
                   snapshot.default.name
                 elsif candidate
                   candidate.name
                 end
      confidence = answer&.confidence
      decided = raw == "default" || (candidate && confidence && confidence >= threshold.to_f)
      would = if answer.nil?
                "no_judgment"
              elsif raw == "undecided"
                "defer"
              elsif raw == "default"
                "default"
              elsif candidate.nil?
                "invalid"
              elsif confidence.nil? || confidence < threshold.to_f
                "below_threshold"
              else
                "suggested"
              end
      fields = {
        session_id: snapshot.session_id,
        turn_number: snapshot.turn_number,
        default_kit: snapshot.default.name,
        raw: raw,
        kit: selected,
        confidence: confidence,
        decided: !!decided,
        would: would,
        core_tools: snapshot.core_tools,
        kits: [snapshot.default, *snapshot.candidates].to_h { |kit| [kit.name, kit.rules] }
      }
      Judged.new(suggestion: Suggestion.new(kit: selected, raw: raw, confidence: confidence, decided: !!decided),
                 would: would, fields: fields)
    end

    # One line in the suggestion log. +did+ (on mode only) is what the
    # turn did with it: suggested (the session switched), default, defer,
    # chosen (the user picked a toolkit first), timeout or canceled (the
    # turn stopped waiting; the line is written when the ask ends).
    def self.record(log, judged, did: nil)
      log.entry("suggestion", did.nil? ? judged.fields : judged.fields.merge(did: did))
    end

    # Whether the session has a model reply: a later prompt's ask is the
    # defer path, and on mode's switch applies "from this turn".
    def self.model_reply?(messages)
      Array(messages).any? { |message| field(message, :role).to_s == "model" }
    end

    # An ask's hand-over between its thread and the turn. Audit mode never
    # waits (+joined+ false): the thread records its line itself. On mode's
    # turn waits (#wait) until the answer, a Stop or the deadline (System
    # 1's timeout from the ask's start), and records what it did with the
    # answer (#record); a turn that stopped waiting leaves the line to the
    # thread, which writes it with why (timeout, canceled) when the ask
    # ends.
    #
    # The request watches the ask's own controller (#cancel_controller),
    # cut only by a Stop the turn sees before it settled (#wait, #abandon
    # :canceled): a Stop later in a turn that went on after a timeout
    # leaves the late ask (and its timeout line) alone.
    class Pending
      POLL_SECONDS = 0.05

      # @return [CancellationController] what the ask's request watches
      attr_reader :cancel_controller

      def initialize(log:, timeout_seconds:, joined:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @log = log
        @clock = clock
        @deadline = clock.call + timeout_seconds.to_f
        @joined = joined
        @cancel_controller = CancellationController.new
        @mutex = Mutex.new
        @done = ConditionVariable.new
        @finished = false
        @recorded = false
        @settled = false
        @judged = nil
        @gave_up = nil
      end

      # On the ask's thread, always (an ensure): its Judged, nil when it
      # was cut (a Stop) or raised.
      def finish(judged)
        @mutex.synchronize do
          @finished = true
          @judged = judged
          if !@joined
            write(nil)
          elsif @gave_up
            write(@gave_up)
          end
          @done.broadcast
        end
      end

      # On the turn thread: [:answered, Judged or nil] once the ask ended,
      # [:canceled, nil] when +controller+ is cancelled (first: a Stop wins
      # over an answer already in), [:timeout, nil] at the deadline. It
      # waits in short slices, so a Stop is seen at once.
      def wait(controller)
        @mutex.synchronize do
          loop do
            return give_up(:canceled) if controller&.cancelled?
            return [:answered, @judged] if @finished

            remaining = @deadline - @clock.call
            return give_up(:timeout) unless remaining.positive?

            @done.wait(@mutex, [remaining, POLL_SECONDS].min)
          end
        end
      end

      # The answered ask's line, with what the turn did.
      def record(did)
        @mutex.synchronize do
          @settled = true
          write(did.to_s)
        end
      end

      # The turn ended before it settled the ask (a Stop before or after
      # the wait, a failure, an Interrupt): its line says +reason+, now or
      # when the ask ends. Nothing once the turn settled it (#record, a
      # timeout or Stop in #wait), so prepare_turn calls it from an ensure.
      def abandon(reason)
        @mutex.synchronize do
          next if @settled

          if @finished
            @settled = true
            write(reason.to_s)
          else
            give_up(reason.to_sym)
          end
        end
      end

      private

      def give_up(reason)
        @settled = true
        @gave_up = reason.to_s
        @cancel_controller.cancel!(:manual) if reason == :canceled
        # An answer already in (a Stop wins over it): its line now.
        write(@gave_up) if @finished
        [reason, nil]
      end

      # Once: an ask that ended with nothing (cut, raised) has no line.
      def write(did)
        return if @recorded || @judged.nil?

        @recorded = true
        ToolkitSuggest.record(@log, @judged, did: did)
      end
    end

    # The warm-up's stand-in prompt: the question (instruction + criteria)
    # is the real one, so System 1's server has that prefix cached when
    # the first real prompt is asked.
    WARMUP_PROMPT = "hello"

    # One ask with the real question and a stand-in prompt, its answer
    # dropped: on mode's warm-up as an idle worker starts (Engine
    # #warm_toolkit_suggestion!). Straight to the backend, so a failure is
    # one info line, never Client#ask's warn, and nothing is logged as a
    # suggestion.
    def self.warm(client:, default:, kits:, project:)
      question, state = question(default: default, kits: kits, project: project, prompt: WARMUP_PROMPT)
      client.backend.ask(state: state, questions: { QUESTION_ID => question })
      nil
    rescue StandardError => e
      Log.info(:toolkit, "toolkit_suggest_warmup_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      nil
    end

    # A resolved kit (Toolkit::Resolved) as frozen, JSON-ready rules, not
    # a tool list: plugin and MCP tools may still be loading when the ask
    # starts, and every kit declares a non-core tool anyway
    # (Resolved#declares?), so the report expands these against the tools
    # a turn really called (ToolkitReportCommand).
    # @return [Hash{String => Object}]
    def self.rules(resolved)
      {
        "all_core" => resolved.all_core,
        "core" => resolved.core.map { |name| name.to_s.dup.freeze }.freeze,
        "added" => resolved.added.map { |name| name.to_s.dup.freeze }.freeze,
        "removed" => resolved.removed.map { |name| name.to_s.dup.freeze }.freeze,
        "groups" => resolved.groups == :all ? "all" : resolved.groups.map { |name| name.to_s.dup.freeze }.freeze
      }.freeze
    end

    def self.log_path(sessions_dir)
      File.join(File.dirname(sessions_dir), FILE)
    end

    def self.warn(error)
      Log.warn(:toolkit, "toolkit_suggest_failed",
               echo: "[samagotchi:toolkit] toolkit suggestion: #{error.class}: #{error.message}",
               error: error.class.name, msg: error.message.to_s[0, 200])
    end

    class << self
      private

      def value(given) = given.respond_to?(:call) ? given.call : given

      def field(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end

      def user_prompt_count(messages)
        prompts = messages.filter_map do |message|
          next unless owner_prompt?(message)

          field(message, :turn_id) || message.object_id
        end
        prompts.uniq.size
      end

      # Reconstitute only the candidate metadata needed to build the question;
      # names, descriptions and groups are copied from the Snapshot.
      def kit_for(candidate)
        Toolkit::Kit.new(name: candidate.name, description: candidate.description)
      end
    end
  end
end
