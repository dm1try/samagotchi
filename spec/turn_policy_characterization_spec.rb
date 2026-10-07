# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/client"
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
  # Engine#cut_for_steer's detail, for a [:steer_cut] step (the user's message).
  steer_cut = { by: "steer", steer: true, source: "", reason: "a new message" }.freeze

  # Streams like Client#complete: content chunks, then the last payload
  # (llama.cpp's /completion shape) with the finish reason the transport
  # reads from it; a cancelled controller raises before the request, as
  # LLM::HTTP does.
  class TurnPolicyFakeClient
    attr_reader :requests

    def initialize(steps)
      @steps = steps
      @requests = []
    end

    def context_window(model: nil) = nil

    def complete(prompt, on_chunk: nil, cancel_controller: nil, sampling: nil, images: [], **)
      raise Samagotchi::LLM::RequestCancelled, cancel_controller.reason if cancel_controller&.cancelled?

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
      if %i[cut steer_cut].include?(kind)
        on_chunk&.call(content: loop_name == :gemma ? "<|channel>thought\nloop " : "<think>loop ", payload: {})
        kind == :cut ? controller.cancel_generation!(:hook, cut) : controller.cancel_generation!(:steer, steer_detail(options))
        raise Samagotchi::LLM::RequestCancelled, kind == :cut ? :hook : :steer
      end
      text = native_text(loop_name, step)
      on_chunk&.call(content: text, payload: { "content" => text })
      final = { "content" => "", "stop" => true, "stop_type" => kind == :length ? "limit" : "eos" }
      if (usage = options[:usage])
        final.merge!("tokens_evaluated" => usage[0], "tokens_predicted" => usage[1])
      end
      on_chunk&.call(content: "", payload: final,
                     finish_reason: Samagotchi::Client::Transport.new(:llama_cpp).finish_reason_from(final))
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
    when :cut, :steer_cut
      lambda do |on_delta:, **|
        on_delta&.call(content: "", reasoning: "loop ", payload: {})
        kind == :cut ? controller.cancel_generation!(:hook, cut) : controller.cancel_generation!(:steer, steer_detail(options))
        raise Samagotchi::LLM::RequestCancelled, kind == :cut ? :hook : :steer
      end
    end
  end

  # A [:steer_cut, { source: "chi_send" }] step: the steer's own source.
  define_method(:steer_detail) do |options|
    options[:source] ? steer_cut.merge(source: options[:source]) : steer_cut
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
    kernel.turn_settings = kernel.turn_settings.with(vision: vision)
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
    when :steer_cut then "steer_cut(#{event[:source].inspect})"
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

    if diffs.is_a?(Array)
      diffs.map { |diff| diff ? :diff : nil }
    else
      :diff
    end
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
      # What event_line leaves out of a cut's rows.
      when :cut_fields
        observed[:cut_fields] = events.select { |e| %i[empty_answer_retry generation_cancelled steer_cut].include?(e[:type]) }
                                      .map { |e| e.except(:iteration, :attempt, :of) }
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
  res = lambda do |text, empty: false, canceled: false, reason: nil, exhausted: false|
    { text: text, empty: empty, canceled: canceled, reason: reason, exhausted: exhausted }
  end
  answered = ["gen", "done", "retry 1/1", "gen", "done"]
  merged = lambda do |answer, count: 1, steers: nil|
    ["gen", "done", "merged(count=#{count} answer=#{answer.inspect}#{" steers=#{steers}" if steers})", "gen", "done"]
  end
  # A cut's :empty_answer_retry fields, with the thinking the cut step streamed.
  cut_retry = lambda do |thinking_chars|
    { type: :empty_answer_retry, finish_reason: "stopped", thinking_chars: thinking_chars, stopped_by: "loop-guard" }
  end
  hook_ending = { type: :generation_cancelled, reason: :hook, stopped_by: "loop-guard" }
  line_at_first = [{ on: :generation_completed, iteration: 1, items: ["user line"] }]
  window = { "SAMAGOTCHI_CONTEXT_WINDOW_TOKENS" => "1000" }

  rows = [
    { name: "empty answer, then an answer", steps: [[:thought], [:text, "PONG"]],
      expected: { events: answered, conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.call("PONG"),
                  temps: [nil, 0.6], activity: [] } },
    # Neither loop keeps an empty generation (result.empty_steps has them,
    # for the UIs); the native loop drops the last nudge, the chat loop
    # leaves its nudges for the Engine (TurnNote.without_trailing). Either
    # way the first spent nudge stays (found, not B2's).
    { name: "empty answer past the budget", env: { "SAMAGOTCHI_RETRY_EMPTY_ANSWER" => "2" }, steps: [[:thought]],
      expected: { events: ["gen", "done", "retry 1/2", "gen", "done", "retry 2/2", "gen", "done"],
                  temps: [nil, 0.6, 0.6], activity: [] },
      native: { conversation: ["user:hi", "system:nudge"], result: res.call("", empty: true) },
      chat: { conversation: ["user:hi", "system:nudge", "system:nudge"], result: res.call("", empty: true) } },
    { name: "retry.empty_answer 0", env: { "SAMAGOTCHI_RETRY_EMPTY_ANSWER" => "0" }, steps: [[:thought], [:text, "late"]],
      expected: { events: %w[gen done], temps: [nil], activity: [] },
      native: { conversation: ["user:hi"], result: res.call("", empty: true) },
      chat: { conversation: ["user:hi"], result: res.call("", empty: true) } },
    { name: "whitespace-only answer", steps: [[:blank], [:text, "PONG"]],
      expected: { events: answered, conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.call("PONG"),
                  temps: [nil, 0.6], activity: [] } },
    { name: "whitespace-only answer with a line queued", steps: [[:blank], [:text, "PONG"]], queue: line_at_first,
      expected: { events: merged.call(nil), conversation: ["user:hi", "user:input", "model:PONG"], result: res.call("PONG"),
                  temps: [nil, nil], activity: [] } },
    # Not retried: the window is full (≥ 90 %), not a thinking loop. Neither
    # loop keeps the empty generation.
    { name: "length stop with the context full", env: window, also: %i[finish],
      steps: [[:length, { usage: [950, 10] }], [:text, "late"]],
      expected: { events: %w[gen done], temps: [nil], activity: [], finish: ["generation_completed=\"length\""] },
      native: { conversation: ["user:hi"], result: res.call("", empty: true) },
      chat: { conversation: ["user:hi"], result: res.call("", empty: true) } },
    { name: "length stop with room left", env: window, steps: [[:length, { usage: [100, 10] }], [:text, "PONG"]],
      expected: { events: answered, conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.call("PONG"),
                  temps: [nil, 0.6], activity: [] } },
    { name: "cut, then an answer", steps: [[:cut], [:text, "PONG"]],
      expected: { events: ["gen", "done(stopped)", "retry 1/1 cut", "gen", "done"],
                  conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.call("PONG"), temps: [nil, 0.6],
                  activity: [] } },
    { name: "cut with no budget", env: { "SAMAGOTCHI_RETRY_EMPTY_ANSWER" => "0" }, steps: [[:cut]],
      expected: { events: ["gen", "done(stopped)", "cancelled(hook)"], conversation: ["user:hi"],
                  result: res.call("", canceled: true, reason: :hook), temps: [nil], activity: [] } },
    { name: "cut twice", steps: [[:cut], [:cut]],
      expected: { events: ["gen", "done(stopped)", "retry 1/1 cut", "gen", "done(stopped)", "cancelled(hook)"],
                  conversation: ["user:hi"], result: res.call("", canceled: true, reason: :hook), temps: [nil, 0.6],
                  activity: [] } },
    { name: "cut, then Stop", steps: [[:cut], [:text, "PONG"]], stop_after_cut: true,
      expected: { events: ["gen", "done(stopped)", "cancelled(user)"], conversation: ["user:hi"],
                  result: res.call("", canceled: true, reason: :user), temps: [nil], activity: [] } },
    # The chat loop's next iteration checks for a Stop too: only on the
    # last one does a cut's Stop differ from the turn going on.
    { name: "cut, then Stop on the last iteration", max_iterations: 1, steps: [[:cut]], stop_after_cut: true,
      expected: { events: ["gen", "done(stopped)", "cancelled(user)"], conversation: ["user:hi"],
                  result: res.call("", canceled: true, reason: :user), temps: [nil], activity: [] } },
    { name: "cut with a line queued", steps: [[:cut], [:text, "PONG"]], queue: line_at_first,
      expected: { events: ["gen", "done(stopped)", "merged(count=1 answer=nil)", "gen", "done"],
                  conversation: ["user:hi", "user:input", "model:PONG"], result: res.call("PONG"), temps: [nil, nil],
                  activity: [] } },
    # Queued input goes in at a cut with or without a retry left.
    { name: "cut with no budget and a line queued", env: { "SAMAGOTCHI_RETRY_EMPTY_ANSWER" => "0" },
      steps: [[:cut], [:text, "PONG"]], queue: line_at_first,
      expected: { events: ["gen", "done(stopped)", "merged(count=1 answer=nil)", "gen", "done"],
                  conversation: ["user:hi", "user:input", "model:PONG"], result: res.call("PONG"), temps: [nil, nil],
                  activity: [] } },
    { name: "cut twice, a plugin steer queued at the second", steps: [[:cut], [:cut], [:text, "PONG"]],
      queue: [{ on: :generation_completed, iteration: 2, items: [{ text: "steer", source: "check-in" }] }],
      expected: { events: ["gen", "done(stopped)", "retry 1/1 cut", "gen", "done(stopped)", "merged(count=0 answer=nil steers=1)",
                           "gen", "done"],
                  conversation: ["user:hi", "system:nudge", "user:steer", "model:PONG"], result: res.call("PONG"),
                  temps: [nil, 0.6, nil], activity: [] } },
    # A steer's cut (Engine#cut_for_steer): the message goes in, or with
    # nothing queued the step is asked again; no nudge, no attempt spent.
    { name: "steer cut, line queued", steps: [[:steer_cut], [:text, "PONG"]], queue: line_at_first,
      expected: { events: ["gen", "done(stopped)", "steer_cut(\"\")", "merged(count=1 answer=nil)", "gen", "done"],
                  conversation: ["user:hi", "user:input", "model:PONG"], result: res.call("PONG"), temps: [nil, nil],
                  activity: [] } },
    { name: "steer cut, nothing queued", env: { "SAMAGOTCHI_RETRY_EMPTY_ANSWER" => "0" },
      steps: [[:steer_cut], [:text, "PONG"]],
      expected: { events: ["gen", "done(stopped)", "steer_cut(\"\")", "gen", "done"], conversation: ["user:hi", "model:PONG"],
                  result: res.call("PONG"), temps: [nil, nil], activity: [] } },
    { name: "steer cut, then Stop", steps: [[:steer_cut], [:text, "PONG"]], stop_after_cut: true, queue: line_at_first,
      expected: { events: ["gen", "done(stopped)", "cancelled(user)"], conversation: ["user:hi"],
                  result: res.call("", canceled: true, reason: :user), temps: [nil], activity: [] } },
    # The fields event_line leaves out: a cut's retry (finish_reason
    # "stopped", the bundle that cut, the thinking it streamed) and the
    # hook ending (stopped_by the bundle).
    { name: "cut, then an answer: the fields", also: %i[cut_fields], steps: [[:cut], [:text, "PONG"]],
      expected: { events: ["gen", "done(stopped)", "retry 1/1 cut", "gen", "done"],
                  conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.call("PONG"), temps: [nil, 0.6],
                  activity: [], cut_fields: [cut_retry.call(5)] },
      gemma: { cut_fields: [cut_retry.call(6)] } },
    { name: "cut twice: the fields", also: %i[cut_fields], steps: [[:cut], [:cut]],
      expected: { events: ["gen", "done(stopped)", "retry 1/1 cut", "gen", "done(stopped)", "cancelled(hook)"],
                  conversation: ["user:hi"], result: res.call("", canceled: true, reason: :hook), temps: [nil, 0.6],
                  activity: [], cut_fields: [cut_retry.call(5), hook_ending] },
      gemma: { cut_fields: [cut_retry.call(6), hook_ending] } },
    # A steer cut spends no attempt: the empty answer after it still gets
    # its retry.
    { name: "steer cut, nothing queued, budget left, then an empty answer",
      steps: [[:steer_cut], [:thought], [:text, "PONG"]],
      expected: { events: ["gen", "done(stopped)", "steer_cut(\"\")", "gen", "done", "retry 1/1", "gen", "done"],
                  conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.call("PONG"), temps: [nil, nil, 0.6],
                  activity: [] } },
    { name: "steer cut from chi send", also: %i[cut_fields], steps: [[:steer_cut, { source: "chi_send" }], [:text, "PONG"]],
      expected: { events: ["gen", "done(stopped)", "steer_cut(\"chi_send\")", "gen", "done"],
                  conversation: ["user:hi", "model:PONG"], result: res.call("PONG"), temps: [nil, nil], activity: [],
                  cut_fields: [{ type: :steer_cut, source: "chi_send" }] } },
    { name: "user line queued at an empty answer", steps: [[:thought], [:text, "PONG"]], queue: line_at_first,
      expected: { events: merged.call(nil), conversation: ["user:hi", "user:input", "model:PONG"], result: res.call("PONG"),
                  temps: [nil, nil], activity: [] } },
    { name: "user line queued at an answer", steps: [[:text, "A"], [:text, "B"]], queue: line_at_first,
      expected: { events: merged.call("A"), conversation: ["user:hi", "model:A", "user:input", "model:B"], result: res.call("B"),
                  temps: [nil, nil], activity: [] } },
    { name: "steer at an empty answer", steps: [[:thought], [:text, "PONG"]],
      queue: [{ on: :generation_completed, iteration: 1, items: [{ text: "steer", source: "check-in" }] }],
      expected: { events: merged.call(nil, count: 0, steers: 1), conversation: ["user:hi", "user:steer", "model:PONG"],
                  result: res.call("PONG"), temps: [nil, nil], activity: [] } },
    { name: "steer at an answer", steps: [[:text, "A"], [:text, "B"]],
      queue: [{ on: :generation_completed, iteration: 1, items: [{ text: "steer", source: "check-in" }] }],
      expected: { events: %w[gen done], conversation: ["user:hi", "model:A"], result: res.call("A"), temps: [nil],
                  activity: [] } },
    # Native formats the next prompt and starts a generation before the
    # request sees the Stop; chat checks first.
    { name: "Stop between two tool calls", drift: "#13", stop_between_calls: true,
      steps: [[:calls, ["probe", { what: "a" }], ["probe", { what: "b" }]], [:text, "late"]],
      expected: { result: res.call("", canceled: true, reason: :user), temps: [nil], activity: %w[probe probe] },
      native: { events: ["gen", "done", "tools(2)", "tool:probe", "tool:probe", "gen", "cancelled(user)"],
                conversation: ["user:hi", "model:", "tool_response"] },
      chat: { events: ["gen", "done", "tools(2)", "tool:probe", "tool:probe", "cancelled(user)"],
              conversation: ["user:hi", "model+calls:", "tool_response", "tool_response"] } },
    { name: "max_iterations on tool calls", max_iterations: 2, steps: [[:calls, ["probe", { what: "a" }]]],
      expected: { events: ["gen", "done", "tools(1)", "tool:probe", "gen", "done", "tools(1)", "tool:probe"],
                  result: res.call("", exhausted: true), temps: [nil, nil], activity: %w[probe probe] },
      native: { conversation: ["user:hi", "model:", "tool_response", "model:", "tool_response"] },
      chat: { conversation: ["user:hi", "model+calls:", "tool_response", "model+calls:", "tool_response"] } },
    { name: "max_iterations on a merge", drift: "#14", max_iterations: 1, steps: [[:text, "A"]], queue: line_at_first,
      expected: { events: ["gen", "done", "merged(count=1 answer=\"A\")"], conversation: ["user:hi", "model:A", "user:input"],
                  temps: [nil], activity: [] },
      native: { result: res.call("A") },
      chat: { result: res.call("A", exhausted: true) } },
    # Formats, not drift: native joins a batch's results into one entry
    # (with per-call image counts and diffs), chat answers each call.
    { name: "a batch with an image and an edit", also: %i[tool_shapes],
      steps: [[:calls, ["shots", {}], ["write", { path: "%{dir}/out.txt", content: "hello" }]], [:text, "done"]],
      expected: { events: ["gen", "done", "tools(2)", "tool:shots", "tool:write", "gen", "done"], result: res.call("done"),
                  temps: [nil, nil], activity: %w[shots write] },
      native: { conversation: ["user:hi", "model:", "tool_response", "model:done"],
                tool_shapes: [{ keys: %i[image_counts images tool_diffs tool_ids], images: 1, image_counts: [1, 0],
                                diffs: [nil, :diff] }] },
      chat: { conversation: ["user:hi", "model+calls:", "tool_response", "tool_response", "model:done"],
              tool_shapes: [{ keys: %i[images tool_call_id tool_ids], images: 1 },
                            { keys: %i[tool_call_id tool_diffs tool_ids], images: 0, diffs: :diff }] } },
    { name: "a dispatcher that raises", raising_dispatch: true,
      steps: [[:calls, ["probe", { what: "a" }]], [:text, "done"]],
      expected: { events: ["gen", "done", "tools(1)", "tool:probe", "gen", "done"], result: res.call("done"), temps: [nil, nil],
                  activity: [] },
      native: { conversation: ["user:hi", "model:", "tool_response", "model:done"] },
      chat: { conversation: ["user:hi", "model+calls:", "tool_response", "model:done"] } },
    # Both loops estimate the prompt before each request: past 40% they
    # emit :context_status and give the model its line.
    { name: "usage crossing 40%", env: window, prompt: "x" * 2000, also: %i[ctx_display],
      steps: [[:text, "ok", { usage: [500, 10] }]],
      expected: { events: ["ctx(40plus)", "gen", "done"], conversation: ["user:xxxxxxxxxxxx", "system:context", "model:ok"],
                  result: res.call("ok"), temps: [nil], activity: [], ctx_display: "40plus" } },
    { name: "finish_reason on the events", also: %i[finish], steps: [[:thought], [:text, "PONG"]],
      expected: { events: answered, conversation: ["user:hi", "system:nudge", "model:PONG"], result: res.call("PONG"),
                  temps: [nil, 0.6], activity: [],
                  finish: ["generation_completed=\"stop\"", "empty_answer_retry=\"stop\"", "generation_completed=\"stop\""] } }
  ]

  loops = %i[qwen gemma chat]

  if ENV["TURN_POLICY_DUMP"]
    # Not a check: TURN_POLICY_DUMP=1 prints the rows to refresh the table.
    it "dumps every row" do # rubocop:disable RSpec/NoExpectationExample
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
