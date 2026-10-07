# frozen_string_literal: true

require "fileutils"
require "json"
require_relative "strategies"

module LLMContextBench
  # The one part of the benchmark that calls a model: asks it, at a case
  # (the end of a turn), which of its tool outputs to forget, through chi's
  # own chat client (LLM::OpenAIChat for a host with api: openai), and
  # saves each answer where Strategies::Picks scores it offline:
  # <out>/<case>.pick_<tool>_<policy>_s<sample>.json. An answer already
  # saved is never asked again.
  #
  # Built for the plan's D7 A/B (the tool named forget_outputs vs
  # forget_llm_context, all else equal) and for policy lines; never run by
  # the specs or by default (--live).
  #
  # The request: the session's system prompt and messages as chat messages
  # (thinking dropped, as chi drops it; a native session's calls read out
  # of its text), every tool result led by its id "[#tN]", one per run,
  # chi's built-in chat tools plus the forget tool, and the policy's tail
  # line. A model that answers without the forget tool is asked once more
  # with the tool forced (the spike did the same); the record says which.
  #
  # A request that fails is saved as an error record and the run goes on,
  # except a payment error (PaymentStop): a 402, or an error that mentions
  # credits or balance, stops the run at once, since every later request
  # would fail the same way.
  class LivePick
    # Raised by #run on a payment error; +written+ is what it saved before.
    class PaymentStop < StandardError
      attr_reader :written

      def initialize(message, written:)
        @written = written
        super(message)
      end
    end

    PAYMENT_RE = /credit|balance/i
    TOOL_NAMES = %w[forget_outputs forget_llm_context].freeze
    # The plan's default policy line (D7, adapted from CLM's steering example).
    POLICY_LINE = "Tidy at subtask boundaries: once a subtask is done, forget its tool outputs and note what it " \
                  "established; keep anything you'll still edit against."
    DESCRIPTION = "Forget tool outputs you no longer need, to free context. Every tool output starts with an id like " \
                  "[#t42]. List the ids in ids; each is replaced in place by a one-line stub holding your note (the " \
                  "call itself stays). The note is required and is all that stays: write what you learned from them " \
                  "(facts, file:line, conclusions, what's ruled out), e.g. \"lib/x.rb 1-200 + spec: no retry logic; " \
                  "retries live in client.rb:340\", not \"not needed\". Good candidates: reads of a file you've since " \
                  "edited, exploration that led nowhere, long logs or test output whose result you've noted, listings. " \
                  "Keep anything you'll still edit against (edit needs the exact text) or cite line numbers from. The " \
                  "system prompt and user messages can't be forgotten."
    # The tail line per policy; %<tool>s is the tool's name, %<k>s the
    # context in thousands of tokens. now: the spike's (it made both models
    # forget nearly everything); soft: the spike's selective one; subtask:
    # the plan's, the line only offers the tool and the policy sentence
    # goes into its description.
    POLICIES = {
      "now" => "[CONTEXT: about %<k>sk tokens of context are in use. context heavy — free context now: call %<tool>s " \
               "to forget the tool outputs (ids [#tN]) you won't need again. The note is required and is all that " \
               "stays of them: write what you learned (facts, file:line, conclusions, what's ruled out) so you won't " \
               "need to re-read them. Make one %<tool>s call now.]",
      "soft" => "[CONTEXT: about %<k>sk tokens of context are in use. context elevated — you may free context with " \
                "%<tool>s. Forget only tool outputs you are confident you won't need for the rest of this task: " \
                "superseded reads (the file changed since), exploration that led nowhere, long logs whose result you " \
                "already know. Keep outputs you will still edit against, quote, or cite line numbers from. The note is " \
                "required and is all that stays: write what you learned from them (facts, file:line, conclusions, " \
                "what's ruled out). Call %<tool>s once now, or not at all if nothing qualifies.]",
      "subtask" => "[CONTEXT: about %<k>sk tokens of context are in use. context elevated — you may free context " \
                   "with %<tool>s.]"
    }.freeze
    # Where and how the tail line goes. tail_system: a system message after
    # the case's last entry (the spike's layout); tail_user: the same line as
    # a user message; boundary: a system message worded as a stopping point
    # of its own. (Cutting at the model's final answer instead isn't offered:
    # 9 of the spike's 12 cases end mid-task, with a tool result or a
    # turn note, so there is no such answer to cut at.)
    LAYOUTS = %w[tail_system tail_user boundary].freeze
    BOUNDARY = "[CONTEXT: about %<k>sk tokens in use. You've reached a stopping point. Before you continue, tidy up: " \
               "%<tool>s whatever you won't need again, or skip it if nothing qualifies.]"
    # The spike's sampling: what the models were picked at; usage.include
    # asks OpenRouter for each request's cost (other servers ignore it).
    OPTIONS = { temperature: 0.6, max_tokens: 12_000, usage: { include: true } }.freeze

    attr_reader :tool_name, :policy, :out_dir, :samples, :layout

    # @param adapter [#chat] chi's chat client (LLM::OpenAIChat); nil for a
    #   dry run
    # @param force [Boolean] ask again with the tool forced when the model
    #   didn't call it
    def initialize(adapter:, model:, tool_name:, policy:, out_dir:, samples: 1, log: $stderr, layout: LAYOUTS.first,
                   force: true)
      raise ArgumentError, "tool name: #{TOOL_NAMES.join(" or ")}" unless TOOL_NAMES.include?(tool_name)
      raise ArgumentError, "policy: #{POLICIES.keys.join(", ")}" unless POLICIES.key?(policy)
      raise ArgumentError, "layout: #{LAYOUTS.join(", ")}" unless LAYOUTS.include?(layout)

      @layout = layout
      @force = force

      @adapter = adapter
      @model = model
      @tool_name = tool_name
      @policy = policy
      @out_dir = out_dir
      @samples = samples
      @log = log
    end

    # The adapter and bare model chi would use for +model_ref+ (a chat host
    # only: the request is chat-shaped).
    def self.chat_adapter(model_ref, registry: Samagotchi::HostRegistry.new)
      entry, bare = registry.host_for_model(model_ref)
      raise ArgumentError, "#{model_ref}: host #{entry.name} isn't a chat host (api: openai)" unless entry.chat?

      [registry.adapter_for(entry), bare]
    end

    # The baseline layout keeps the name picks had before layouts.
    def variant(sample)
      named = layout == LAYOUTS.first ? policy : "#{policy}_#{layout}"
      "pick_#{tool_name}_#{named}_s#{sample}"
    end

    def path(kase, sample) = File.join(out_dir, "#{kase.name}.#{variant(sample)}.json")

    # Asks for every case and sample not saved yet.
    # @return [Array<String>] the files written
    # @raise [PaymentStop] on a payment error; nothing is saved for its case
    def run(cases)
      FileUtils.mkdir_p(out_dir)
      written = []
      cases.product((1..samples).to_a).each do |kase, sample|
        target = path(kase, sample)
        next if File.exist?(target)

        record = begin
          ask(kase)
        rescue PaymentStop => e
          raise PaymentStop.new(e.message, written: written)
        end
        File.write(target, JSON.generate(record))
        @log.puts "picked #{kase.name} #{variant(sample)}"
        written << target
      end
      written
    end

    # A 402, or an error that mentions credits or balance (an OpenRouter
    # key out of credit, a provider's "insufficient balance").
    def self.payment_error?(error)
      error.status == 402 || error.is_a?(Samagotchi::LLM::OutOfCredits) || PAYMENT_RE.match?(error.message.to_s)
    end

    # What a run would send: requests (one per case and sample, more when a
    # pick is forced) and their estimated prompt tokens (chars/4).
    def estimate(cases)
      prompts = cases.map { |kase| JSON.generate(messages(kase)).length / 4.0 }
      { requests: prompts.size * samples, prompt_tokens: prompts.sum * samples, largest: prompts.max || 0 }
    end

    # The record Picks reads: the answer, the forced one when it took that,
    # and how it was asked.
    def ask(kase)
      request = messages(kase)
      unforced = chat(request, OPTIONS)
      record = { "unforced" => unforced }
      if @force && Strategies::Picks.forget_calls(unforced).empty?
        record["forced"] = chat(request, OPTIONS.merge(tool_choice: { type: "function", function: { name: tool_name } }))
      end
      record.merge("bench" => { "id_scheme" => "run", "tool" => tool_name, "policy" => policy, "layout" => layout,
                                "model" => @model })
    rescue Samagotchi::LLM::ProviderError => e
      raise PaymentStop.new(e.summary, written: []) if self.class.payment_error?(e)

      { "unforced" => { "error" => e.message }, "bench" => { "id_scheme" => "run", "tool" => tool_name, "policy" => policy } }
    end

    # The tools offered: chi's built-in chat tools, then the forget tool.
    def tools
      builtin = Samagotchi::ToolDeclarations.chat_schemas(Samagotchi::ToolDeclarations::TOOL_SCHEMAS).map do |schema|
        { type: "function", function: schema.slice(:name, :description, :parameters) }
      end
      builtin + [forget_tool]
    end

    def forget_tool
      description = policy == "subtask" ? "#{DESCRIPTION} #{POLICY_LINE}" : DESCRIPTION
      { type: "function", function: {
        name: tool_name, description: description,
        parameters: { type: "object", additionalProperties: false, required: %w[ids note], properties: {
          ids: { type: "array", items: { type: "string" }, description: "the tool output ids to forget, e.g. [\"t42\", \"t43\"]" },
          note: { type: "string", description: "what you learned from the forgotten outputs (required)" }
        } }
      } }
    end

    # The case's conversation as chat messages up to its turn's end, then
    # the policy's tail line.
    def messages(kase)
      replay = kase.replay
      ids = kase.outputs.each_with_index.to_h { |output, index| [[output.entry_index, output.run], "t#{index + 1}"] }
      wire = []
      replay.messages[0...replay.turns[kase.turn].end].each_with_index do |entry, index|
        wire.concat(wire_entries(replay, entry, index, ids))
      end
      wire = paired(wire)
      k = (JSON.generate(wire).length / 4000.0).round
      text = format(layout == "boundary" ? BOUNDARY : POLICIES.fetch(policy), tool: tool_name, k: k)
      wire << { role: layout == "tail_user" ? "user" : "system", content: text }
    end

    private

    # One request, shaped, with the cost the server put in a streamed usage
    # chunk (OpenRouter's usage.cost), when it did.
    def chat(request, options)
      cost = nil
      on_delta = lambda do |payload:, **|
        found = payload.is_a?(Hash) ? payload.dig("usage", "cost") : nil
        cost = found unless found.nil?
      end
      response = @adapter.chat(messages: request, model: @model, tools: tools, options: options, on_delta: on_delta)
      shaped(response).tap { |record| record["usage"]["cost"] = cost unless cost.nil? }
    end

    def wire_entries(replay, entry, index, ids)
      case replay.role(index)
      when "system", "user" then [{ role: replay.role(index), content: entry[:content].to_s }]
      when "model" then [assistant(replay, entry, index)]
      when "tool_response" then tool_messages(replay, index, ids)
      else []
      end
    end

    def assistant(replay, entry, index)
      prose = replay.parts(entry).first
      calls = replay.calls[replay.request_of(index)].each_with_index.map do |call, position|
        { id: call_id(entry, index, position), type: "function",
          function: { name: call.name, arguments: JSON.generate(call.args) } }
      end
      calls.empty? ? { role: "assistant", content: prose } : { role: "assistant", content: prose, tool_calls: calls }
    end

    # A chat call keeps its id; a native one gets "n<entry>_<position>".
    def call_id(entry, index, position)
      Array(entry[:tool_calls])[position]&.dig(:id) || "n#{index}_#{position}"
    end

    def tool_messages(replay, index, ids)
      entry = replay.messages[index]
      model_index = replay.requests.reverse.find { |request_index| request_index < index }
      replay.outputs.select { |output| output.entry_index == index }.map do |output|
        id = entry[:tool_call_id] || (model_index && "n#{model_index}_#{output.run}")
        { role: "tool", tool_call_id: id, content: "[##{ids.fetch([index, output.run])}] #{output.text}" }
      end
    end

    # Valid chat order: an assistant's call no tool message answers is
    # dropped, and a tool message no call asked for goes as user text.
    def paired(wire)
      asked = wire.flat_map { |message| Array(message[:tool_calls]).map { |call| call[:id] } }.to_set
      answered = wire.filter_map { |message| message[:tool_call_id] if message[:role] == "tool" }.to_set
      wire.map do |message|
        if message[:tool_calls]
          calls = message[:tool_calls].select { |call| answered.include?(call[:id]) }
          calls.empty? ? message.except(:tool_calls) : message.merge(tool_calls: calls)
        elsif message[:role] == "tool" && !asked.include?(message[:tool_call_id])
          { role: "user", content: "[tool results]\n#{message[:content]}" }
        else
          message
        end
      end
    end

    # chi's ChatResponse in the OpenAI shape Picks reads.
    def shaped(response)
      calls = response.tool_calls.map do |call|
        arguments = call.arguments.is_a?(String) ? call.arguments : JSON.generate(call.arguments)
        { "id" => call.id, "type" => "function", "function" => { "name" => call.name, "arguments" => arguments } }
      end
      { "model" => response.model,
        "choices" => [{ "message" => { "content" => response.text, "reasoning" => response.reasoning, "tool_calls" => calls },
                        "finish_reason" => response.finish_reason }],
        "usage" => { "prompt_tokens" => response.usage.prompt_tokens, "completion_tokens" => response.usage.completion_tokens,
                     "cached_tokens" => response.usage.cached_tokens } }
    end
  end
end
