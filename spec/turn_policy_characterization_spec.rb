# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/kernel_loop"
require "samagotchi/model_profile"
require "samagotchi/cancellation_controller"
require "samagotchi/vision_support"
require "samagotchi/llm/native_backend"
require "samagotchi/llm/chat_loop"
require_relative "support/fake_chat_adapter"

# One turn's policy, as data: each row is a scripted turn run through the
# native loop (a real KernelLoop, Qwen 3.6 and Gemma 4, with a client fake
# that streams like Client) and the chat loop (ChatLoop over a real
# KernelLoop, with FakeChatAdapter). Each row pins, per loop, the stream
# events, the saved conversation and the result. `expected` holds what both
# loops do; `native` (both profiles) / `chat` override it where they differ.
# A row whose loops differ by drift (not by format) names it in `drift`
# (the B2 plan's table rows, "A9" for the context ones), so fixing one is an
# edited cell here.
RSpec.describe "Turn policy characterization" do
  cut = { by: "loop-guard", reason: "its thinking kept repeating itself" }.freeze

  # Streams like Client#complete: content chunks, then the last payload
  # (llama.cpp's /completion shape); a cancelled controller raises before
  # the request, as LLM::HTTP does.
  class TurnPolicyFakeClient
    attr_reader :requests

    def initialize(steps)
      @steps = steps
      @requests = []
    end

    def context_window(model: nil) = nil

    def complete(prompt, on_chunk: nil, cancel_controller: nil, sampling: nil, images: [], **)
      raise Samagotchi::LLM::RequestCancelled.new(cancel_controller.reason) if cancel_controller&.cancelled?

      @requests << { prompt: prompt, sampling: sampling, images: images }
      step = @steps.length > 1 ? @steps.shift : @steps.first
      step.call(on_chunk: on_chunk)
    end
  end

  define_method(:profile_for) do |loop_name|
    loop_name == :gemma ? Samagotchi::ModelProfile.gemma4 : Samagotchi::ModelProfile.qwen36
  end

  # ── steps: one generation each, built per loop ───────────────────────────

  define_method(:native_text) do |loop_name, step|
    kind, *args = step
    case kind
    when :text then args.first
    when :blank then "  \n "
    when :thought, :length
      loop_name == :gemma ? "<|channel>thought\nloop loop loop\n<channel|>" : "<think>loop loop loop</think>"
    when :calls
      args.map do |name, params|
        if loop_name == :gemma
          body = params.map { |key, value| "#{key}:<|\"|>#{value}<|\"|>" }.join(",")
          "<|tool_call>call:#{name}{#{body}}<tool_call|>"
        else
          body = params.map { |key, value| "<parameter=#{key}>\n#{value}\n</parameter>\n" }.join
          "<tool_call>\n<function=#{name}>\n#{body}</function>\n</tool_call>"
        end
      end.join("\n")
    end
  end

  define_method(:native_step) do |loop_name, step, controller|
    kind, *args = step
    options = args.last.is_a?(Hash) && kind != :calls ? args.last : {}
    lambda do |on_chunk:|
      if kind == :cut
        on_chunk&.call(content: loop_name == :gemma ? "<|channel>thought\nloop " : "<think>loop ", payload: {})
        controller.cancel_generation!(:hook, cut)
        raise Samagotchi::LLM::RequestCancelled.new(:hook)
      end
      text = native_text(loop_name, step)
      on_chunk&.call(content: text, payload: { "content" => text })
      final = { "content" => "", "stop" => true, "stop_type" => kind == :length ? "limit" : "eos" }
      if (usage = options[:usage])
        final.merge!("tokens_evaluated" => usage[0], "tokens_predicted" => usage[1])
      end
      on_chunk&.call(content: "", payload: final)
      text
    end
  end

  define_method(:chat_step) do |step, controller|
    kind, *args = step
    options = args.last.is_a?(Hash) && kind != :calls ? args.last : {}
    usage = if options[:usage]
              Samagotchi::LLM::Usage.new(prompt_tokens: options[:usage][0], completion_tokens: options[:usage][1], source: :server)
            else
              Samagotchi::LLM::Usage.none
            end
    case kind
    when :text then FakeChatAdapter.text(args.first, usage: usage)
    when :blank then FakeChatAdapter.text("  \n ", usage: usage)
    when :thought then FakeChatAdapter.text("", reasoning: "loop loop loop", usage: usage)
    when :length
      Samagotchi::LLM::ChatResponse.new(text: "", reasoning: "loop loop loop", tool_calls: [], usage: usage,
                                        finish_reason: "length")
    when :calls
      FakeChatAdapter.tools(*args.each_with_index.map { |(name, params), index| ["c#{index + 1}", name, params] })
    when :cut
      lambda do |on_delta:, **|
        on_delta&.call(content: "", reasoning: "loop ", payload: {})
        controller.cancel_generation!(:hook, cut)
        raise Samagotchi::LLM::RequestCancelled.new(:hook)
      end
    end
  end

  # ── the run ──────────────────────────────────────────────────────────────

  let(:dir) { Dir.mktmpdir("chi-turn-policy") }
  let(:png_path) { File.expand_path("fixtures/images/tiny.png", __dir__) }

  after { FileUtils.rm_rf(dir) }

  define_method(:registry) do
    Samagotchi::Tools::Builtins.registry.tap do |r|
      r.register("probe", schema: { parameters: { properties: { what: { type: "string" } } } }, source: "sample-plugin",
                          handler: ->(*) { "probed" })
      png = png_path
      with_images = Class.new(String) do
        define_method(:images) { [{ path: png }] }
      end
      r.register("shots", schema: { parameters: { properties: {} } }, source: "sample-plugin",
                          handler: ->(*) { with_images.new("one shot") })
    end
  end

  define_method(:vision) do
    limits = Samagotchi::ImageStore::Limits.new(max_side: 1568, max_bytes: 3_750_000, max_per_request: 20)
    Samagotchi::VisionContext.new(session_dir: dir, limits: limits, resizer: Samagotchi::ImageResizer.new(nil))
  end

  # The steps' %{dir} placeholders, filled per run.
  define_method(:fill) do |step|
    return step unless step.first == :calls

    [:calls, *step[1..].map { |name, params| [name, params.transform_values { |v| v.to_s.gsub("%{dir}", dir) }] }]
  end

  # Runs +row+ through +loop_name+ (:qwen, :gemma or :chat); returns what it observed.
  define_method(:run_row) do |row, loop_name|
    controller = Samagotchi::CancellationController.new
    events = []
    queue = []
    steps = row[:steps].map { |step| fill(step) }
    if loop_name == :chat
      adapter = FakeChatAdapter.new(*steps.map { |step| chat_step(step, controller) })
      kernel = Samagotchi::KernelLoop.new(client: TurnPolicyFakeClient.new([]), profile: profile_for(:qwen), tools: registry)
      backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
    else
      client = TurnPolicyFakeClient.new(steps.map { |step| native_step(loop_name, step, controller) })
      kernel = Samagotchi::KernelLoop.new(client: client, profile: profile_for(loop_name), tools: registry)
      backend = Samagotchi::LLM::NativeBackend.new(kernel: kernel)
    end
    kernel.vision = vision
    if row[:raising_dispatch]
      allow(kernel).to receive(:dispatch_tool_call).and_raise(RuntimeError, "dispatcher broke")
    end
    sink = lambda do |event|
      events << event
      Array(row[:queue]).each do |trigger|
        queue.concat(trigger[:items]) if event[:type] == trigger[:on] && event[:iteration] == trigger[:iteration]
      end
      controller.cancel!(:user) if row[:stop_after_cut] && event[:type] == :generation_completed && event[:stopped_by]
      if row[:stop_between_calls] && event[:type] == :tool_call_completed && event[:call_index] == 1
        controller.cancel!(:user)
      end
    end
    # Like Engine#turn_drain: a plugin's steers are dropped at an answer.
    drain = lambda do |at_answer: false|
      items = queue.dup
      queue.clear
      at_answer ? items.grep_v(Hash) : items
    end
    messages = [{ role: "user", content: row[:prompt] || "hi" }]
    result = with_env(row[:env] || {}) do
      backend.complete(messages: messages, max_iterations: row[:max_iterations] || 10, on_stream_event: sink,
                       cancel_controller: controller, model_name: "m", pending_input: drain)
    end
    observe(row, kernel, result, events, loop_name == :chat ? adapter.requests : client.requests)
  end

  define_method(:with_env) do |env, &block|
    saved = env.to_h { |key, _| [key, ENV.fetch(key, nil)] }
    env.each { |key, value| ENV[key] = value }
    Samagotchi::ContextWindow.reset!
    block.call
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # ── observations ─────────────────────────────────────────────────────────

  define_method(:event_line) do |event|
    case event[:type]
    when :generation_started then "gen"
    when :generation_completed then event[:stopped_by] ? "done(stopped)" : "done"
    when :generation_cancelled then "cancelled(#{event[:reason]})"
    when :context_status then "ctx(#{event[:bucket]})"
    when :empty_answer_retry then "retry #{event[:attempt]}/#{event[:of]}#{" cut" if event[:stopped_by]}"
    when :pending_input_merged
      fields = ["count=#{event[:count]}", "answer=#{event[:answer].inspect}"]
      fields << "steers=#{event[:steers].size}" if event[:steers]
      "merged(#{fields.join(" ")})"
    when :tool_dispatch_started then "tools(#{event[:call_count]})"
    when :tool_call_completed then "tool:#{event[:tool]}"
    end
  end

  define_method(:entry_line) do |kernel, entry|
    role = entry[:role].to_s
    return "system:nudge" if Samagotchi::TurnNote.retry_nudge?(entry)
    return "system:#{entry[:kind]}" if role == "system"
    return "user:#{entry[:kind] || entry[:content].to_s[0, 12]}" if role == "user"
    return "tool_response" if role == "tool_response"

    content = entry[:content].to_s
    visible = kernel.parser.strip_tool_calls(kernel.strip_model_thought(content)).strip
    text = visible.empty? && !content.empty? && content.strip.empty? ? "<blank>" : visible
    entry[:tool_calls] ? "model+calls:#{text}" : "model:#{text}"
  end

  # A native entry has one diff per call (nil for other calls); a chat
  # entry its call's own.
  define_method(:diff_shape) do |diffs|
    return nil if diffs.nil?

    diffs.is_a?(Array) ? diffs.map { |diff| diff ? :diff : nil } : :diff
  end

  define_method(:observe) do |row, kernel, result, events, requests|
    observed = {
      events: events.filter_map { |event| event_line(event) },
      conversation: result.conversation.map { |entry| entry_line(kernel, entry) },
      result: { text: result.text, empty: result.empty_answer?, canceled: result.canceled?,
                reason: result.cancellation_reason, exhausted: result.exhausted? },
      temps: requests.map do |request|
        sampling = request[:sampling] || request[:options] || {}
        sampling[:temperature]
      end,
      activity: result.tool_activity.map { |activity| activity && activity[:tool] }
    }
    Array(row[:also]).each do |extra|
      case extra
      when :ctx_display then observed[:ctx_display] = result.context_status&.dig(:bucket)
      when :finish
        observed[:finish] = events.select { |e| %i[generation_completed empty_answer_retry].include?(e[:type]) }
                                  .map { |e| "#{e[:type]}=#{e[:finish_reason].inspect}" }
      when :tool_shapes
        observed[:tool_shapes] = result.conversation.select { |e| e[:role].to_s == "tool_response" }.map do |entry|
          { keys: (entry.keys - %i[role content]).sort,
            images: Array(entry[:images]).size,
            image_counts: entry[:image_counts],
            diffs: diff_shape(entry[:tool_diffs]) }.compact
        end
      end
    end
    observed
  end

  # ── the table ────────────────────────────────────────────────────────────
  # The result's fields: text, empty_answer?, canceled?, cancellation_reason, exhausted?.
  res = ->(text, empty: false, canceled: false, reason: nil, exhausted: false) do
    { text: text, empty: empty, canceled: canceled, reason: reason, exhausted: exhausted }
  end
  empty_answer = "(the model returned an empty answer)"
  answered = ["gen", "done", "retry 1/1", "gen", "done"]
  merged = ->(answer, count: 1, steers: nil) do
    ["gen", "done", "merged(count=#{count} answer=#{answer.inspect}#{" steers=#{steers}" if steers})", "gen", "done"]
  end
  line_at_first = [{ on: :generation_completed, iteration: 1, items: ["user line"] }]
  window = { "SAMAGOTCHI_CONTEXT_WINDOW_TOKENS" => "1000" }

  rows = [
    { name: "empty answer, then an answer", steps: [[:thought], [:text, "PONG"]],
      expected: { events: answered, conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.("PONG"),
                  temps: [nil, 0.6], activity: [] } },
    # The native loop keeps the last empty generation and drops the last
    # nudge; the chat loop saves no empty answer and leaves its nudges for
    # the Engine (TurnNote.without_trailing). Either way the first spent
    # nudge stays (found, not B2's).
    { name: "empty answer past the budget", env: { "SAMAGOTCHI_RETRY_EMPTY_ANSWER" => "2" }, steps: [[:thought]],
      expected: { events: ["gen", "done", "retry 1/2", "gen", "done", "retry 2/2", "gen", "done"],
                  temps: [nil, 0.6, 0.6], activity: [] },
      native: { conversation: ["user:hi", "system:nudge", "model:"], result: res.("") },
      chat: { conversation: ["user:hi", "system:nudge", "system:nudge"], result: res.(empty_answer, empty: true) } },
    { name: "retry.empty_answer 0", env: { "SAMAGOTCHI_RETRY_EMPTY_ANSWER" => "0" }, steps: [[:thought], [:text, "late"]],
      expected: { events: ["gen", "done"], temps: [nil], activity: [] },
      native: { conversation: ["user:hi", "model:"], result: res.("") },
      chat: { conversation: ["user:hi"], result: res.(empty_answer, empty: true) } },
    { name: "whitespace-only answer", drift: "#4", steps: [[:blank], [:text, "PONG"]],
      expected: { activity: [] },
      native: { events: answered, conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.("PONG"),
                temps: [nil, 0.6] },
      chat: { events: ["gen", "done"], conversation: ["user:hi", "model:<blank>"], result: res.("  \n "), temps: [nil] } },
    { name: "whitespace-only answer with a line queued", drift: "#4", steps: [[:blank], [:text, "PONG"]],
      queue: line_at_first,
      expected: { result: res.("PONG"), temps: [nil, nil], activity: [] },
      native: { events: merged.(nil), conversation: ["user:hi", "user:input", "model:PONG"] },
      chat: { events: merged.("  \n "), conversation: ["user:hi", "model:<blank>", "user:input", "model:PONG"] } },
    { name: "length stop with the context full", drift: "A9", env: window, also: %i[finish],
      steps: [[:length, { usage: [950, 10] }], [:text, "late"]],
      expected: { activity: [] },
      native: { events: ["gen", "done", "retry 1/1", "ctx(80plus)", "gen", "done"],
                conversation: ["user:hi", "system:nudge", "system:context", "model:late"], result: res.("late"),
                temps: [nil, 0.6],
                finish: ["generation_completed=nil", "empty_answer_retry=nil", "generation_completed=nil"] },
      chat: { events: ["gen", "done"], conversation: ["user:hi"], result: res.(empty_answer, empty: true), temps: [nil],
              finish: ["generation_completed=\"length\""] } },
    { name: "length stop with room left", env: window, steps: [[:length, { usage: [100, 10] }], [:text, "PONG"]],
      expected: { events: answered, conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.("PONG"),
                  temps: [nil, 0.6], activity: [] } },
    { name: "cut, then an answer", steps: [[:cut], [:text, "PONG"]],
      expected: { events: ["gen", "done(stopped)", "retry 1/1 cut", "gen", "done"],
                  conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.("PONG"), temps: [nil, 0.6],
                  activity: [] } },
    { name: "cut with no budget", env: { "SAMAGOTCHI_RETRY_EMPTY_ANSWER" => "0" }, steps: [[:cut]],
      expected: { events: ["gen", "done(stopped)", "cancelled(hook)"], conversation: ["user:hi"],
                  result: res.("", canceled: true, reason: :hook), temps: [nil], activity: [] } },
    { name: "cut twice", steps: [[:cut], [:cut]],
      expected: { events: ["gen", "done(stopped)", "retry 1/1 cut", "gen", "done(stopped)", "cancelled(hook)"],
                  conversation: ["user:hi"], result: res.("", canceled: true, reason: :hook), temps: [nil, 0.6],
                  activity: [] } },
    { name: "cut, then Stop", steps: [[:cut], [:text, "PONG"]], stop_after_cut: true,
      expected: { events: ["gen", "done(stopped)", "cancelled(user)"], conversation: ["user:hi"],
                  result: res.("", canceled: true, reason: :user), temps: [nil], activity: [] } },
    { name: "cut with a line queued", steps: [[:cut], [:text, "PONG"]], queue: line_at_first,
      expected: { events: ["gen", "done(stopped)", "merged(count=1 answer=nil)", "gen", "done"],
                  conversation: ["user:hi", "user:input", "model:PONG"], result: res.("PONG"), temps: [nil, nil],
                  activity: [] } },
    { name: "user line queued at an empty answer", steps: [[:thought], [:text, "PONG"]], queue: line_at_first,
      expected: { events: merged.(nil), conversation: ["user:hi", "user:input", "model:PONG"], result: res.("PONG"),
                  temps: [nil, nil], activity: [] } },
    { name: "user line queued at an answer", steps: [[:text, "A"], [:text, "B"]], queue: line_at_first,
      expected: { events: merged.("A"), conversation: ["user:hi", "model:A", "user:input", "model:B"], result: res.("B"),
                  temps: [nil, nil], activity: [] } },
    { name: "steer at an empty answer", steps: [[:thought], [:text, "PONG"]],
      queue: [{ on: :generation_completed, iteration: 1, items: [{ text: "steer", source: "check-in" }] }],
      expected: { events: merged.(nil, count: 0, steers: 1), conversation: ["user:hi", "user:steer", "model:PONG"],
                  result: res.("PONG"), temps: [nil, nil], activity: [] } },
    { name: "steer at an answer", steps: [[:text, "A"], [:text, "B"]],
      queue: [{ on: :generation_completed, iteration: 1, items: [{ text: "steer", source: "check-in" }] }],
      expected: { events: ["gen", "done"], conversation: ["user:hi", "model:A"], result: res.("A"), temps: [nil],
                  activity: [] } },
    # Native formats the next prompt and starts a generation before the
    # request sees the Stop; chat checks first.
    { name: "Stop between two tool calls", drift: "#13", stop_between_calls: true,
      steps: [[:calls, ["probe", { what: "a" }], ["probe", { what: "b" }]], [:text, "late"]],
      expected: { result: res.("", canceled: true, reason: :user), temps: [nil], activity: %w[probe probe] },
      native: { events: ["gen", "done", "tools(2)", "tool:probe", "tool:probe", "gen", "cancelled(user)"],
                conversation: ["user:hi", "model:", "tool_response"] },
      chat: { events: ["gen", "done", "tools(2)", "tool:probe", "tool:probe", "cancelled(user)"],
              conversation: ["user:hi", "model+calls:", "tool_response", "tool_response"] } },
    { name: "max_iterations on tool calls", max_iterations: 2, steps: [[:calls, ["probe", { what: "a" }]]],
      expected: { events: ["gen", "done", "tools(1)", "tool:probe", "gen", "done", "tools(1)", "tool:probe"],
                  result: res.("", exhausted: true), temps: [nil, nil], activity: %w[probe probe] },
      native: { conversation: ["user:hi", "model:", "tool_response", "model:", "tool_response"] },
      chat: { conversation: ["user:hi", "model+calls:", "tool_response", "model+calls:", "tool_response"] } },
    { name: "max_iterations on a merge", drift: "#14", max_iterations: 1, steps: [[:text, "A"]], queue: line_at_first,
      expected: { events: ["gen", "done", "merged(count=1 answer=\"A\")"], conversation: ["user:hi", "model:A", "user:input"],
                  temps: [nil], activity: [] },
      native: { result: res.("A") },
      chat: { result: res.("A", exhausted: true) } },
    # Formats, not drift: native joins a batch's results into one entry
    # (with per-call image counts and diffs), chat answers each call.
    { name: "a batch with an image and an edit", also: %i[tool_shapes],
      steps: [[:calls, ["shots", {}], ["write", { path: "%{dir}/out.txt", content: "hello" }]], [:text, "done"]],
      expected: { events: ["gen", "done", "tools(2)", "tool:shots", "tool:write", "gen", "done"], result: res.("done"),
                  temps: [nil, nil], activity: %w[shots write] },
      native: { conversation: ["user:hi", "model:", "tool_response", "model:done"],
                tool_shapes: [{ keys: %i[image_counts images tool_diffs], images: 1, image_counts: [1, 0],
                                diffs: [nil, :diff] }] },
      chat: { conversation: ["user:hi", "model+calls:", "tool_response", "tool_response", "model:done"],
              tool_shapes: [{ keys: %i[images tool_call_id], images: 1 },
                            { keys: %i[tool_call_id tool_diffs], images: 0, diffs: :diff }] } },
    { name: "a dispatcher that raises", drift: "#12", raising_dispatch: true,
      steps: [[:calls, ["probe", { what: "a" }]], [:text, "done"]],
      expected: { events: ["gen", "done", "tools(1)", "tool:probe", "gen", "done"], result: res.("done"), temps: [nil, nil] },
      native: { conversation: ["user:hi", "model:", "tool_response", "model:done"], activity: [nil] },
      chat: { conversation: ["user:hi", "model+calls:", "tool_response", "model:done"], activity: [] } },
    # Native estimates the prompt before each request: past 40% it emits
    # :context_status and gives the model its line. Chat only shows the
    # server's count after the generation.
    { name: "usage crossing 40%", drift: "A9", env: window, prompt: "x" * 2000, also: %i[ctx_display],
      steps: [[:text, "ok", { usage: [500, 10] }]],
      expected: { result: res.("ok"), temps: [nil], activity: [], ctx_display: "40plus" },
      native: { events: ["ctx(40plus)", "gen", "done"], conversation: ["user:xxxxxxxxxxxx", "system:context", "model:ok"] },
      chat: { events: ["gen", "done"], conversation: ["user:xxxxxxxxxxxx", "model:ok"] } },
    { name: "finish_reason on the events", drift: "#19", also: %i[finish], steps: [[:thought], [:text, "PONG"]],
      expected: { events: answered, conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.("PONG"),
                  temps: [nil, 0.6], activity: [] },
      native: { finish: ["generation_completed=nil", "empty_answer_retry=nil", "generation_completed=nil"] },
      chat: { finish: ["generation_completed=\"stop\"", "empty_answer_retry=\"stop\"", "generation_completed=\"stop\""] } }
  ]

  loops = %i[qwen gemma chat]

  if ENV["TURN_POLICY_DUMP"]
    it "dumps every row" do
      require "pp"
      rows.each do |row|
        loops.each { |loop_name| puts "#{row[:name]} [#{loop_name}]: #{run_row(row, loop_name).pretty_inspect}" }
      end
    end
  else
    rows.each do |row|
      loops.each do |loop_name|
        side = loop_name == :chat ? :chat : :native
        expected = (row[:expected] || {}).merge(row[side] || {}).merge(row[loop_name] || {})
        label = "#{row[:name]} [#{loop_name}]"
        label += " (drift #{row[:drift]})" if row[:drift] && (row[:native] || row[:chat])
        it(label) do
          expect(run_row(row, loop_name)).to eq(expected)
        end
      end
    end
  end
end
