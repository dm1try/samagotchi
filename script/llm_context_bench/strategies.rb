# frozen_string_literal: true

require "json"
require_relative "cases"

module LLMContextBench
  # One edit a strategy makes: the output (its ToolIds id), the edit's kind
  # (an LLMContextEdit kind), the note its stub carries, and the request it
  # first reaches the prompt at (an edit is applied there and stays).
  PlannedEdit = Data.define(:output_id, :kind, :note, :applies_at)

  # What a strategy does at a case: its edits, scored at the case's request
  # (+case+.at). +model+ and +policy+ are the report's row: the session's
  # model for a strategy chi runs alone, the picking model for one a model
  # chose. +how+ says how a pick was got (unforced, forced, none);
  # +invalid_ids+ counts the ids it named that aren't outputs in context.
  Plan = Data.define(:strategy, :kase, :model, :policy, :edits, :how, :invalid_ids) do
    def initialize(how: nil, invalid_ids: 0, policy: "-", **fields) = super
  end

  # A strategy isn't built yet: its phase of the plan builds it.
  class NotBuilt < StandardError; end

  # The strategies the benchmark knows, by name. Each answers #plans(kase)
  # with the Plans it scores at that case. Pluggable: a later phase adds its
  # strategy here (stale, P2; stale_edits_<rule>, P3; forget_outputs in
  # P4), and the scorer and the report take it as they are.
  module Strategies
    # none: nothing changes, the prompt stays byte-identical. The base.
    class None
      def name = "none"

      def plans(kase) = [Plan.new(strategy: name, kase: kase, model: kase.replay.model_name, edits: [])]
    end

    # forget_all: at the turn's end, forget every output in context, with an
    # empty note. The spike's "base rate": what forgetting everything (or
    # at random) scores, and about what a model told "free context now"
    # did (Splash forgot 97%).
    class ForgetAll
      def name = "forget_all"

      def plans(kase)
        edits = kase.outputs.map { |output| PlannedEdit.new(output_id: output.id, kind: :forget, note: "", applies_at: kase.at) }
        [Plan.new(strategy: name, kase: kase, model: kase.replay.model_name, edits: edits)]
      end
    end

    # stale (P2): chi's own layer (Samagotchi::LLMContextStale) as chi runs
    # it, apply next_request: before each request it stubs every read a
    # later read covering its lines superseded (an edit or write of the
    # file supersedes nothing), so an edit reaches the prompt at the first
    # request after that read. A relative path is taken against the
    # session's working directory (chi takes it against its process's,
    # which is the session's).
    class Stale
      def name = "stale"

      def plans(kase)
        replay = kase.replay
        conversation = replay.messages[0...replay.prompt_end(kase.at)]
        found = Samagotchi::LLMContextStale.found(conversation, root: replay.working_directory || Dir.pwd)
        edits = found.map do |stale|
          PlannedEdit.new(output_id: stale.run.ref.id, kind: :stale, note: stale.note,
                          applies_at: replay.request_after(stale.by.index))
        end
        [Plan.new(strategy: name, kase: kase, model: replay.model_name, edits: edits)]
      end
    end

    # stale with edits (P3): chi's stale layer with edit-driven stubs
    # (llm_context.stale_edits: true, opt-in) under an apply rule (Samagotchi::LLMContextApply), run as chi runs it, over
    # the session from its start: at each request (moment :request) and at
    # the end of each turn that ends with the model's answer (:turn_end,
    # sent from the next turn's first request), with llm_context.protect_steps'
    # default. The top ContextStatus bucket isn't modelled (no window), so
    # payoff applies only when the freed tokens are at least the tail.
    # Named stale_edits_<rule>: next_request, turn_end, payoff.
    class StaleApply
      attr_reader :rule

      def initialize(rule, protect_steps: Samagotchi::LLMContextStrategy::DEFAULT_PROTECT_STEPS)
        @rule = rule
        @protect_steps = protect_steps
        @runs = {}
      end

      def name = "stale_edits_#{rule}"

      def plans(kase)
        replay = kase.replay
        edits = (@runs[replay] ||= run(replay)).select { |edit| edit.applies_at <= kase.at }
        [Plan.new(strategy: name, kase: kase, model: replay.model_name, edits: edits)]
      end

      private

      # Every edit the rule applies over the session, at the request it
      # first reaches.
      def run(replay)
        work = replay.messages.map(&:dup)
        root = replay.working_directory || Dir.pwd
        ends = answered_turn_ends(replay)
        last = -1
        replay.requests.each_with_index.flat_map do |prompt_end, request|
          edits = ends.select { |turn_end| turn_end > last && turn_end <= prompt_end }.flat_map do |turn_end|
            apply(work[0...turn_end], :turn_end, root)
          end
          last = prompt_end
          (edits + apply(work[0...prompt_end], :request, root)).map do |edit|
            PlannedEdit.new(output_id: edit.id, kind: edit.kind, note: edit.note, applies_at: request)
          end
        end
      end

      def apply(conversation, moment, root)
        Samagotchi::LLMContextApply.run!(conversation, layers: [:stale], rule: rule, moment: moment, changes: true,
                                                       protect_steps: @protect_steps, root: root, now: "bench").applied
      end

      # Where each turn the model answered ends (its range's end).
      def answered_turn_ends(replay)
        replay.turns.each_index.filter_map do |turn|
          replay.turns[turn].end if Case.new(replay: replay, turn: turn).answer_ended?
        end
      end
    end

    # A strategy whose phase hasn't built it yet.
    class Unbuilt
      attr_reader :name, :phase

      def initialize(name, phase)
        @name = name
        @phase = phase
      end

      def plans(_kase) = raise(NotBuilt, "#{name} is not built yet (#{phase} of the llm_context plan)")
    end

    # Model picks of what to forget, recorded as responses: the spike's
    # out/<model>/<case>.pick*.json, or what LivePick saves. Each file
    # "<case>.<variant>.json" is one pick; its variant (without a "_s<N>"
    # sample suffix) is the report's policy, +label+ its model.
    #
    # A pick names outputs by the ids the model was shown: "t<N>" for the
    # Nth tool_response entry (the spike's numbering) or, when the file says
    # bench.id_scheme "run", for the Nth run (LivePick's, one per output).
    # Each call's ids are forgotten with its note; chi's view sends it on
    # the first of them in a row and a pointer to that one on the rest.
    class Picks
      TOOL_NAMES = %w[context_edit forget_outputs forget_llm_context].freeze
      RANGE = /\A\W*t(\d+)\s*[-–]\s*#?t?(\d+)\W*\z/

      attr_reader :label, :dir

      def initialize(label:, dir:)
        @label = label
        @dir = dir
      end

      def name = "picks"

      # The case names this source has picks for.
      def case_names
        Dir.glob(File.join(dir, "*.pick*.json")).map { |path| File.basename(path).split(".").first }.uniq.sort
      end

      def plans(kase)
        Dir.glob(File.join(dir, "#{kase.name}.pick*.json")).sort.filter_map { |path| plan(kase, path) }
      end

      # The ids in a pick's list: "t42", "#t42", "t40-t45" (a range).
      def self.parse_ids(raw)
        Array(raw).flat_map do |item|
          item = item.to_s
          if (range = RANGE.match(item))
            (range[1].to_i..range[2].to_i).map { |n| "t#{n}" }
          else
            item.scan(/t(\d+)/).flatten.map { |n| "t#{n}" }
          end
        end
      end

      # The forget calls in an OpenAI-shaped response: [{ids:, note:}].
      def self.forget_calls(response)
        message = response.is_a?(Hash) ? response.dig("choices", 0, "message") : nil
        Array(message && message["tool_calls"]).filter_map do |call|
          function = call["function"] || {}
          next unless TOOL_NAMES.include?(function["name"])

          args = begin
            JSON.parse(function["arguments"].to_s)
          rescue JSON::ParserError
            {}
          end
          args = {} unless args.is_a?(Hash)
          { ids: parse_ids(args["ids"] || args["forget"]), note: args["note"].to_s }
        end
      end

      private

      def plan(kase, path)
        record = JSON.parse(File.read(path))
        return nil if record["skipped"]

        variant = File.basename(path, ".json").delete_prefix("#{kase.name}.")
        how, calls = picked(record)
        by_id = id_map(kase, record.dig("bench", "id_scheme"))
        edits = []
        invalid = 0
        calls.each do |call|
          call[:ids].uniq.each do |shown|
            outputs = by_id[shown]
            next invalid += 1 unless outputs

            outputs.each do |output|
              edits << PlannedEdit.new(output_id: output.id, kind: :forget, note: call[:note], applies_at: kase.at)
            end
          end
        end
        Plan.new(strategy: name, kase: kase, model: label, policy: variant.sub(/_s\d+\z/, ""),
                 edits: edits.uniq(&:output_id), how: how, invalid_ids: invalid)
      end

      def picked(record)
        calls = self.class.forget_calls(record["unforced"])
        return ["unforced", calls] unless calls.empty?
        return ["forced", self.class.forget_calls(record["forced"])] if record["forced"]

        ["none", []]
      end

      # Shown id => the outputs it names, among those in context.
      def id_map(kase, scheme)
        outputs = kase.outputs
        return outputs.each_with_index.to_h { |output, index| ["t#{index + 1}", [output]] } if scheme == "run"

        outputs.group_by(&:entry_ordinal).transform_keys { |ordinal| "t#{ordinal + 1}" }
      end
    end

    BUILT = { "none" => None, "forget_all" => ForgetAll, "stale" => Stale }.freeze
    APPLIED = Samagotchi::LLMContextStrategy::APPLIES.to_h { |rule| ["stale_edits_#{rule}", rule] }.freeze
    UNBUILT = { "forget_outputs" => "P4" }.freeze

    module_function

    def names = BUILT.keys + APPLIED.keys + UNBUILT.keys

    # The strategy named +name+ (Picks are made apart, from their files).
    # @raise [ArgumentError] for an unknown one
    def build(name)
      return BUILT.fetch(name).new if BUILT.key?(name)
      return StaleApply.new(APPLIED.fetch(name)) if APPLIED.key?(name)
      return Unbuilt.new(name, UNBUILT.fetch(name)) if UNBUILT.key?(name)

      raise ArgumentError, "unknown strategy #{name} (#{names.join(", ")}, or --picks)"
    end
  end
end
