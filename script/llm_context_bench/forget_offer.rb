# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "strategies"

module LLMContextBench
  module Strategies
    # forget_outputs (P4): chi's forget layer as chi offers it, replayed at
    # each case (a turn the model answered; the next turn's first request,
    # where chi offers forgetting). The request is what chi would send there
    # under llm_context.strategy [stale, forget], built by chi's own code:
    # the case's conversation up to and with the next user message (an id
    # given to each output a legacy entry holds, as chi gives new ones),
    # stale's stubs applied (later reads, P2's rule), every output led by its
    # id through the LLMContextView, the [CONTEXT: …] line chi's ContextStatus
    # adds at a turn's start under +budget+ (none below its guided buckets),
    # the chat wire messages and tools of chi's ChatLoop (forget_outputs with
    # its real description). The model answers once (+picker+, a model call
    # or a fake); a forget_outputs call among its calls is run through chi's
    # LLMContextForget (its refusals, protect_steps, keep), and the plan is
    # stale's stubs plus the forgets, all reaching the case's request.
    #
    # The row's +how+ says what the model did: called (it called the tool),
    # no_call (it answered or called other tools), error (no answer), or
    # unasked (no saved answer and no model to ask). The
    # plan carries the note's length and the ids chi refused.
    class ForgetOutputs
      DEFAULT_BUDGET = 64_000
      LAYERS = %i[stale forget].freeze
      # A window the budget is always under: the buckets count against the
      # budget (the bench has no server to ask).
      WINDOW = Samagotchi::ContextWindow::Resolved.new(tokens: 100_000_000, source: :config)
      NAME = "forget_outputs"
      NOW = "bench"

      # A case's request: the id-assigned conversation (copies), each
      # assigned id's Output and back, the offer line (nil: none), the wire
      # messages and the tools.
      Offer = Data.define(:conversation, :outputs, :ids, :line, :messages, :tools)

      attr_reader :budget

      # @param picker [#call, nil] (kase, messages, tools) → an OpenAI-shaped
      #   response Hash ({"choices" => [{"message" => {"tool_calls" => …}}]},
      #   or {"error" => …}); nil: every case is skipped (NotBuilt)
      def initialize(picker:, budget: DEFAULT_BUDGET, policy: "-")
        @picker = picker
        @budget = budget
        @policy = policy
      end

      def name = NAME

      def plans(kase)
        raise NotBuilt, "forget_outputs needs a model to ask (--forget-model, or saved answers in --out)" unless @picker

        offer = offer(kase)
        stale = Stale.new.plans(kase).first.edits
        response = @picker.call(kase, offer.messages, offer.tools)
        return [plan(kase, stale, how: response.nil? ? "unasked" : "error")] if response.nil? || response["error"]

        calls = forget_calls(response)
        return [plan(kase, stale, how: "no_call")] if calls.empty?

        forgets, refused, notes = run_calls(kase, offer, calls)
        [plan(kase, stale + forgets.reject { |edit| stale.any? { |s| s.output_id == edit.output_id } },
              how: "called", refused: refused, note_chars: notes)]
      end

      # The request chi would send at +kase+'s offer point.
      # @return [Offer]
      def offer(kase)
        replay = kase.replay
        work = replay.messages[0...replay.prompt_end(kase.at)].map(&:dup)
        outputs, ids = assign_ids(replay, work)
        stub_stale(replay, work)
        line = offer_line(work)
        chat = chat_loop
        sent = line ? work + [line] : work
        Offer.new(conversation: work, outputs: outputs, ids: ids, line: line, messages: chat.wire_messages(sent),
                  tools: chat.tool_definitions)
      end

      # The strategy chi runs the case's turn under.
      def llm_context
        Samagotchi::LLMContextStrategy::Resolved.new(layers: LAYERS, strategy: LAYERS, source: :config,
                                                     apply: :next_request, budget_tokens: budget)
      end

      private

      def plan(kase, edits, how:, refused: 0, note_chars: 0)
        Plan.new(strategy: name, kase: kase, model: @picker.respond_to?(:label) ? @picker.label : kase.replay.model_name,
                 policy: @policy, edits: edits, how: how, invalid_ids: refused, note_chars: note_chars)
      end

      # Gives each run of an entry without stored ids one (t<N>, after the
      # highest stored one, as ToolIds does); returns the Outputs by chi id
      # and the chi ids by Output id.
      def assign_ids(replay, work)
        outputs = {}
        ids = {}
        by_place = replay.outputs.to_h { |output| [[output.entry_index, output.run], output] }
        work.each_with_index do |entry, index|
          next unless entry[:role].to_s == "tool_response"

          refs = Samagotchi::ToolIds.refs_at(work, index)
          if refs.any?(&:derived?)
            entry[:tool_ids] = Samagotchi::ToolIds.next_ids(work, refs.size)
            refs = Samagotchi::ToolIds.refs_at(work, index)
          end
          refs.each do |ref|
            output = by_place[[index, ref.run]] or next
            outputs[ref.id] = output
            ids[output.id] = ref.id
          end
        end
        [outputs, ids]
      end

      # Stale's stubs (a later read, P2's rule) as chi has them applied by
      # the case's request.
      def stub_stale(replay, work)
        Samagotchi::LLMContextStale.found(work, root: replay.working_directory || Dir.pwd).each do |stale|
          edit = Samagotchi::LLMContextEdit.new(id: stale.run.ref.id, kind: :stale, note: stale.note,
                                                by: Samagotchi::LLMContextStale::BY, staged_at: NOW, applied_at: NOW)
          Samagotchi::LLMContextEdit.store(work[stale.run.index], edit)
        end
      end

      # The line chi's ContextStatus adds at a turn's first request.
      def offer_line(work)
        status = Samagotchi::ContextStatus.new(conversation: work, llm_context: llm_context)
        chars = Samagotchi::LLMContextView.chars(view.messages(work))
        status.observe(chars, iteration_index: 0, window: WINDOW)
        status.take_guidance
      end

      def view = Samagotchi::LLMContextView.new(strategy: LAYERS)

      # A chat loop on a kernel that runs the turn under [stale, forget]:
      # its wire messages and tools are what chi sends.
      def chat_loop
        kernel = Samagotchi::KernelLoop.new(client: Object.new, profile: Samagotchi::ModelProfile.qwen36,
                                            model_name: "bench")
        kernel.turn_settings = kernel.turn_settings.with(llm_context: llm_context)
        Samagotchi::LLM::ChatLoop.new(kernel: kernel)
      end

      # The forget_outputs calls in a response, each its id and arguments.
      def forget_calls(response)
        message = response.dig("choices", 0, "message") || {}
        Array(message["tool_calls"]).filter_map do |call|
          function = call["function"] || {}
          next unless function["name"] == NAME

          args = begin
            JSON.parse(function["arguments"].to_s)
          rescue JSON::ParserError
            {}
          end
          [call["id"].to_s, args.is_a?(Hash) ? args : {}]
        end
      end

      # Runs the calls through chi's LLMContextForget on the case's
      # conversation (the model's entry with them as the last step).
      # @return [Array(Array<PlannedEdit>, Integer, Integer)] the forgets,
      #   the ids refused, the notes' length
      def run_calls(kase, offer, calls)
        work = offer.conversation + [{ role: "model", content: "",
                                       tool_calls: calls.map { |id, args| { id: id, name: NAME, arguments: args } } }]
        root = kase.replay.working_directory || Dir.pwd
        resolved = llm_context
        turn = Samagotchi::LLMContextForget::Turn.new(conversation: work, context: nil)
        apply = lambda do
          Samagotchi::LLMContextApply.run!(work, layers: LAYERS, rule: :next_request, moment: :request,
                                                 protect_steps: resolved.protect_steps, root: root, now: NOW)
        end
        refused = 0
        notes = 0
        calls.each do |_id, args|
          call = Samagotchi::Tools::BuiltinCalls.build(NAME, args)
          result = Samagotchi::LLMContextForget.call(turn, call, llm_context: resolved, apply: apply, root: root, now: NOW)
          refused += result.lines.count { |line| line.start_with?("- t") }
          notes += call[:note].to_s.length
        end
        [forgets(kase, offer, work), refused, notes]
      end

      def forgets(kase, offer, work)
        work.flat_map do |entry|
          next [] unless entry[:role].to_s == "tool_response"

          Samagotchi::LLMContextEdit.on(entry).values.select { |edit| edit.kind == :forget }.filter_map do |edit|
            output = offer.outputs[edit.id] or next
            PlannedEdit.new(output_id: output.id, kind: :forget, note: edit.note, applies_at: kase.at, keep: edit.keep)
          end
        end
      end
    end

    # The model's answers at the forget offer, one file per case
    # (<case>.forget_offer.json under +dir+): read back when saved, else
    # asked (+ask+: messages, tools → response) and saved (an error isn't:
    # a rerun asks again). +label+ is the
    # report's model. A payment error, or the costs reported passing
    # +max_cost+ (US dollars), stops the run (LivePick::PaymentStop).
    class ForgetAnswers
      OPTIONS = { temperature: 0.6, max_tokens: 12_000, usage: { include: true } }.freeze

      attr_reader :label, :cost

      def initialize(dir:, label:, ask: nil, max_cost: nil, log: $stderr)
        @dir = dir
        @label = label
        @ask = ask
        @max_cost = max_cost
        @log = log
        @cost = 0.0
      end

      def path(kase) = File.join(@dir, "#{kase.name}.forget_offer.json")

      def call(kase, messages, tools)
        target = path(kase)
        return JSON.parse(File.read(target)) if File.exist?(target)
        return nil unless @ask

        if @max_cost && @cost >= @max_cost
          raise LivePick::PaymentStop.new(format("--max-cost $%.2f reached", @max_cost), written: [])
        end

        response = @ask.call(messages, tools)
        @cost += response.dig("usage", "cost").to_f
        return response if response["error"] # not saved: a rerun asks again

        FileUtils.mkdir_p(@dir)
        File.write(target, JSON.generate(response))
        @log.puts "asked #{kase.name} (#{format("$%.4f", @cost)} so far)"
        response
      end

      # An asker through chi's chat client (LivePick.chat_adapter): the
      # answer in the OpenAI shape, its cost when the server reports one.
      def self.chat_asker(adapter, model)
        lambda do |messages, tools|
          cost = nil
          on_delta = lambda do |payload:, **|
            found = payload.is_a?(Hash) ? payload.dig("usage", "cost") : nil
            cost = found unless found.nil?
          end
          response = adapter.chat(messages: messages, model: model, tools: tools, options: OPTIONS, on_delta: on_delta)
          shaped(response).tap { |record| record["usage"]["cost"] = cost unless cost.nil? }
        rescue Samagotchi::LLM::ProviderError => e
          raise LivePick::PaymentStop.new(e.summary, written: []) if LivePick.payment_error?(e)

          { "error" => e.message }
        end
      end

      def self.shaped(response)
        calls = response.tool_calls.map do |call|
          arguments = call.arguments.is_a?(String) ? call.arguments : JSON.generate(call.arguments)
          { "id" => call.id, "type" => "function", "function" => { "name" => call.name, "arguments" => arguments } }
        end
        { "model" => response.model,
          "choices" => [{ "message" => { "content" => response.text, "tool_calls" => calls },
                          "finish_reason" => response.finish_reason }],
          "usage" => { "prompt_tokens" => response.usage.prompt_tokens,
                       "completion_tokens" => response.usage.completion_tokens } }
      end
    end
  end
end
