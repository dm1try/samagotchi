# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/grants"
require "samagotchi/participants"
require "support/test_kernel"
require_relative "support/fake_provider_server"

# What KernelLoop and ChatLoop share through one Engine, pinned before the
# ToolHost refactor (~/.claude/plans/arch-toolhost.md, C0) and kept green
# through it: a real Engine (its own KernelLoop, ChatLoop, ToolRunner,
# Gate, nothing injected) over a FakeProviderServer with two host entries,
# so each host has its own client (no Engine client:, which would share one
# through client_override): `box` (native, llama.cpp /completion, a Qwen 3.6
# profile from /props) and `oai` (a local `api: openai` host: its window is
# probed through the client).
#
# The few reads of the Engine's insides go through the helpers below
# (#kernel_of, #forget_turn_of, #dispatch_on), so the refactor's phases
# change those, not the examples.
# Each wire's model and the path its server answers (a module: constants in
# a describe block would be top-level ones).
module ToolHostWires
  NATIVE = "box:Qwen3.6"
  CHAT = "oai:chat-a"
  PATHS = { native: "/completion", chat: "/v1/chat/completions" }.freeze
  MODELS = { native: NATIVE, chat: CHAT }.freeze
end

RSpec.describe "Tool host characterization" do
  include TestKernel

  let(:tmp) { File.realpath(Dir.mktmpdir("tool-host")) }
  let(:project) { File.join(tmp, "project") }
  let(:state_dir) { File.join(tmp, "state", "samagotchi", "sessions") }
  let(:server) { FakeProviderServer.start }
  let(:events) { [] }
  let(:hook_calls) { [] }
  let(:asked) { [] }

  around do |example|
    FakeProviderServer.without_webmock do
      FileUtils.mkdir_p(project)
      with_config_home(File.join(tmp, "config")) do
        with_env("XDG_STATE_HOME" => File.join(tmp, "state")) do
          Dir.chdir(project) { example.run }
        end
      end
    end
  ensure
    server.stop
    FileUtils.rm_rf(tmp)
  end

  def config(**extra)
    {
      "default" => { "model" => ToolHostWires::NATIVE },
      "hosts" => {
        "box" => { "host" => "127.0.0.1", "port" => server.port },
        "oai" => { "host" => "127.0.0.1", "port" => server.port, "api" => "openai" }
      },
      "models" => {
        "Qwen3.6" => { "sampling" => { "temperature" => 0.3 }, "thinking" => "off" },
        "chat-a" => { "sampling" => { "temperature" => 0.2 }, "thinking" => "off" }
      },
      "guardrails" => {
        "system_one" => { "mode" => "off" },
        "rules" => [{ "id" => "host-ask", "tool" => "write", "path" => "**/asked.txt", "verdict" => "ask",
                      "reason" => "the characterization asks" }]
      },
      "toolkit" => { "suggest" => { "mode" => "off" } },
      "context" => { "candidates" => { "mode" => "off" } },
      "objectives" => { "system_one" => "off" },
      "recap" => { "enabled" => false },
      "cache" => { "warmup" => "off" }
    }.merge(extra)
  end

  def write_config(**extra)
    File.write(File.join(tmp, "config", "samagotchi", "config.yml"), YAML.dump(config(**extra)))
  end

  before do
    write_config
    File.write(File.join(project, "notes.txt"), "golden notes\n")
    server.default("/props", json: { "chat_template" => "<|im_start|> <function=",
                                     "default_generation_settings" => { "n_ctx" => 32_768 } })
    server.default("/v1/models", json: { data: [] })
  end

  # -- the engine's insides, in one place ----------------------------------

  def kernel_of(engine) = engine.instance_variable_get(:@kernel)

  # The running turn a forget_outputs call works on (LLMContextForget::Turn).
  def forget_turn_of(engine) = kernel_of(engine).llm_context_turn

  # One call through the dispatch both loops share.
  def dispatch_on(engine, call, context) = kernel_of(engine).dispatch_tool_call(call, context)

  def chat_loop_of(engine)
    engine.switch_model!(ToolHostWires::CHAT)
    engine.backend
  end

  # -- the engine and its session ---------------------------------------

  def engine_on(model, **options)
    engine = Samagotchi::Engine.new(host_registry: Samagotchi::HostRegistry.new, model_name: model, **options)
    engine.interface = :worker
    engine.session_state_dir = state_dir
    engine.set_question_sync_handler do |pending|
      asked << pending
      { selected: [pending[:options].first], selected_indices: [0] }
    end
    engine
  end

  def session_on(model)
    Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: project)
  end

  # A turn on +wire+ (:native or :chat): the engine switched to its model first.
  def turn(engine, session, wire, prompt, **options)
    engine.switch_model!(ToolHostWires::MODELS.fetch(wire)) unless engine.effective_model_ref == ToolHostWires::MODELS.fetch(wire)
    engine.store_model!(session)
    engine.session = session
    # A turn's own hooks (Engine#register_hook) go at its end.
    engine.register_hook(:before_tool_call) { |event| hook_calls << event[:call][:name] }
    engine.run_turn(session, prompt, on_event: ->(event) { events << event }, **options)
  end

  # -- what each wire's server answers ----------------------------------

  # One reply on +wire+: tool calls ([id, name, arguments]) or text; +usage+
  # (prompt, cached) is the server's token counts.
  def enqueue(wire, calls: [], text: nil, usage: [100, 0])
    sse = wire == :native ? native_reply(calls, text, usage) : openai_reply(calls, text, usage)
    server.enqueue(ToolHostWires::PATHS.fetch(wire), sse: sse)
  end

  def native_reply(calls, text, (prompt, cached))
    content = text || calls.map do |(_id, name, args)|
      body = args.map { |key, value| "<parameter=#{key}>\n#{value.is_a?(String) ? value : JSON.generate(value)}\n</parameter>\n" }.join
      "<tool_call>\n<function=#{name}>\n#{body}</function>\n</tool_call>"
    end.join("\n")
    ["data: #{JSON.generate(content: content, stop: false)}\n\n",
     "data: #{JSON.generate(content: "", stop: true, tokens_evaluated: prompt, tokens_predicted: 10,
                            timings: { cache_n: cached, prompt_n: prompt - cached })}\n\n"]
  end

  def openai_chunk(delta, finish = nil, usage: nil)
    chunk = { id: "chatcmpl-host", object: "chat.completion.chunk", created: 1_790_000_000, model: "served" }
    if usage
      chunk[:choices] = []
      chunk[:usage] = { prompt_tokens: usage[0], completion_tokens: 10, total_tokens: usage[0] + 10,
                        prompt_tokens_details: { cached_tokens: usage[1] } }
    else
      chunk[:choices] = [{ index: 0, delta: delta, finish_reason: finish }]
    end
    "data: #{JSON.generate(chunk)}\n\n"
  end

  def openai_reply(calls, text, usage)
    chunks = [openai_chunk({ role: "assistant", content: nil })]
    if text
      chunks << openai_chunk({ content: text }) << openai_chunk({}, "stop")
    else
      calls.each_with_index do |(id, name, args), index|
        chunks << openai_chunk({ tool_calls: [{ index: index, id: id, type: "function",
                                                function: { name: name, arguments: JSON.generate(args) } }] })
      end
      chunks << openai_chunk({}, "tool_calls")
    end
    chunks << openai_chunk(nil, usage: usage) << "data: [DONE]\n\n"
  end

  def requests_on(wire) = server.requests.select { |request| request.path == ToolHostWires::PATHS.fetch(wire) }

  # What a request sends of the conversation, as text: the native prompt,
  # or the chat messages' JSON.
  def sent_text(request)
    body = request.json
    body["prompt"].is_a?(String) ? body["prompt"] : JSON.generate(body["messages"])
  end

  def completed(type = :tool_call_completed) = events.select { |event| event[:type] == type }

  # -- (a) one Gate, one set of hooks, one Registry, one reminder store -----

  it "runs both loops' tool calls through the same gate, hooks, tools and reminder store" do
    engine = engine_on(ToolHostWires::CHAT)
    session = session_on(ToolHostWires::CHAT)
    session.save(state_dir: state_dir)
    { chat: "chat-reminder", native: "native-reminder" }.each do |wire, name|
      enqueue(wire, calls: [["c_#{wire}_1", "register_reminder", { "name" => name, "description" => "from #{wire}" }],
                            ["c_#{wire}_2", "write", { "path" => "asked.txt", "content" => wire.to_s }]])
      enqueue(wire, text: "Done on #{wire}.")
      turn(engine, session, wire, "Remind me, then write asked.txt (#{wire}).")
    end

    expect(hook_calls).to eq(%w[register_reminder write register_reminder write])
    expect(asked.size).to eq(2)
    expect(asked.map { |pending| pending[:question] }).to all(include("asked.txt"))
    expect(engine.instance_variable_get(:@reminder_store).list).to include("chat-reminder", "native-reminder")
    expect(File.read(File.join(project, "asked.txt"))).to eq("native")
  end

  # -- (b) forget_outputs on each loop ------------------------------------

  describe "forget_outputs on each loop (llm_context forget)" do
    before do
      write_config("llm_context" => { "protect_steps" => 0 })
      File.write(File.join(project, "log.txt"), (1..200).map { |n| "spec #{n}: ok\n" }.join)
    end

    def forget_session(model)
      session_on(model).tap do |session|
        session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:forget], apply: :next_request)
      end
    end

    %i[native chat].each do |wire|
      it "sends the stub with the next request on the #{wire} loop" do
        engine = engine_on(ToolHostWires::MODELS[wire])
        session = forget_session(ToolHostWires::MODELS[wire])
        enqueue(wire, calls: [["c1", "read", { "path" => "log.txt" }]])
        enqueue(wire, calls: [["c2", "forget_outputs", { "ids" => ["t1"], "note" => "the log says every spec passed" }]])
        enqueue(wire, text: "Tidied.")

        turn(engine, session, wire, "Read the log, then forget it.")

        sent = requests_on(wire).map { |request| sent_text(request) }
        expect(sent.size).to eq(3)
        expect(sent[1]).to include("spec 150: ok")
        expect(sent[2]).not_to include("spec 150: ok")
        expect(sent[2]).to include("forgot t1")
      end

      it "refuses an output the user pinned on the #{wire} loop" do
        engine = engine_on(ToolHostWires::MODELS[wire])
        session = forget_session(ToolHostWires::MODELS[wire])
        session.working_set_pins = [Samagotchi::WorkingSetPin.new(kind: "file", key: File.join(project, "log.txt"))]
        enqueue(wire, calls: [["c1", "read", { "path" => "log.txt" }]])
        enqueue(wire, calls: [["c2", "forget_outputs", { "ids" => ["t1"], "note" => "the log says every spec passed" }]])
        enqueue(wire, text: "Kept.")

        turn(engine, session, wire, "Read the log, then forget it.")

        last = sent_text(requests_on(wire).last)
        expect(last).to include("spec 150: ok")
        expect(last).to include("t1: #{Samagotchi::WorkingSetSteer::Refused.text(:pinned_by_user)}")
      end
    end
  end

  # -- (c) one re-prefill baseline across the loops --------------------------

  # The baseline is the Engine's, whichever loop ran last: keyed by the
  # model and the host's client, so a switch to another host and back
  # starts over on the way back.
  it "keeps one re-prefill baseline for both loops, and a warm-up starts it over" do
    engine = engine_on(ToolHostWires::CHAT)
    session = session_on(ToolHostWires::CHAT)
    reprefills = lambda do
      generations = completed(:generation_completed)
      events.clear
      generations.map { |event| event[:reprefill_tokens] }
    end

    # Turn 1, oai: the 2nd generation reprefills 1000 - 200 of the 1st's prompt.
    enqueue(:chat, calls: [["c1", "read", { "path" => "notes.txt" }]], usage: [1000, 0])
    enqueue(:chat, text: "One.", usage: [1200, 200])
    turn(engine, session, :chat, "one")
    expect(reprefills.call).to eq([nil, 800])

    # Turn 2, box: another model on another client, none.
    enqueue(:native, text: "Two.", usage: [3000, 0])
    turn(engine, session, :native, "two")
    expect(reprefills.call).to eq([nil])

    # Turn 3, oai again: the baseline is box's, so the 1st has none; the 2nd has.
    enqueue(:chat, calls: [["c2", "read", { "path" => "notes.txt" }]], usage: [1400, 300])
    enqueue(:chat, text: "Three.", usage: [1500, 400])
    turn(engine, session, :chat, "three")
    expect(reprefills.call).to eq([nil, 1000])

    # A warm-up (Warmup#after) starts it over: turn 4's 1st has none.
    kernel_of(engine).warmed_up!
    enqueue(:chat, text: "Four.", usage: [1600, 100])
    turn(engine, session, :chat, "four")
    expect(reprefills.call).to eq([nil])
  end

  # The chat loop's window on a local host comes from that host's client
  # (its /props), as the native loop's does.
  it "probes a local chat host's window through its own client, and the native host's through its own" do
    server.default("/props", json: { "chat_template" => "<|im_start|> <function=",
                                     "default_generation_settings" => { "n_ctx" => 24_576 } })
    engine = engine_on(ToolHostWires::CHAT)
    session = session_on(ToolHostWires::CHAT)
    enqueue(:chat, text: "Chat.")
    turn(engine, session, :chat, "one")
    enqueue(:native, text: "Native.")
    turn(engine, session, :native, "two")

    started = completed(:generation_started).map { |event| event.slice(:context_window_tokens, :context_window_source) }
    expect(started).to eq([{ context_window_tokens: 24_576, context_window_source: :server }] * 2)
    expect(server.requests.map(&:path)).to include("/props")
  end

  # -- (d) a bare ChatLoop's own turn -----------------------------------------

  it "gives a bare ChatLoop (no context:) the default model's settings and a bare surface of its tools" do
    kernel = test_kernel
    chat = Samagotchi::LLM::ChatLoop.new(kernel: kernel)

    context = chat.turn_context
    expect(context.settings.model_name).to eq(Samagotchi::ModelProfile.required_model_name(nil))
    expect(Samagotchi::Tools::ToolSurface.of(context).declared.map(&:name))
      .to eq(Samagotchi::Tools::ToolSurface.of(Samagotchi::Tools::ToolSurface.bare(Samagotchi::TurnContext.none, kernel.tools))
                                          .declared.map(&:name))
  end

  # -- (e) a failing before_generation hook --------------------------------

  it "keeps a turn whose before_generation hook fails: silent on the chat loop, logged on the native one" do
    engine = engine_on(ToolHostWires::CHAT)
    session = session_on(ToolHostWires::CHAT)
    hooks = engine.instance_variable_get(:@hooks)
    allow(hooks).to receive(:fire).and_call_original
    allow(hooks).to receive(:fire).with(:before_generation, anything).and_raise(IOError, "hook gone")
    allow(Samagotchi::Log).to receive(:warn).and_call_original

    enqueue(:chat, text: "Chat answer.")
    expect(turn(engine, session, :chat, "hi").output).to eq("Chat answer.")
    expect(Samagotchi::Log).not_to have_received(:warn).with(:hooks, "hook_fire_failed", anything)

    enqueue(:native, text: "Native answer.")
    expect(turn(engine, session, :native, "hi").output).to eq("Native answer.")
    expect(Samagotchi::Log).to have_received(:warn).with(:hooks, "hook_fire_failed", hash_including(hook: :before_generation))
  end

  # -- (f) live_conversation, (g) a pair turn past its participant's cap -------

  %i[native chat].each do |wire|
    it "reads the #{wire} loop's own conversation mid-turn, and nothing after" do
      engine = engine_on(ToolHostWires::MODELS[wire])
      session = session_on(ToolHostWires::MODELS[wire])
      seen = []
      engine.register_hook(:before_generation) do |_event|
        live = engine.live_conversation
        seen << [live, live&.size, forget_turn_of(engine)&.conversation]
      end
      enqueue(wire, calls: [["c1", "read", { "path" => "notes.txt" }]])
      enqueue(wire, text: "Read.")

      turn(engine, session, wire, "Read the notes (#{wire}).")

      expect(seen.size).to eq(2)
      expect(seen.map(&:first)).to all(be_an(Array))
      expect(seen[0][0]).to equal(seen[0][2])
      expect(seen[1][0]).to equal(seen[0][0])
      expect(seen[1][1]).to be > seen[0][1]
      expect(seen[0][0].map { |message| message[:content] }).to include("Read the notes (#{wire}).")
      expect(engine.live_conversation).to be_nil
    end

    it "stops a pair turn past its participant's cap before the #{wire} loop's next generation" do
      engine = engine_on(ToolHostWires::MODELS[wire])
      session = session_on(ToolHostWires::MODELS[wire])
      session.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))
      grants = Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir))
      grant = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex",
                                                      state_dir: state_dir).grant
      checks = 0
      engine.participant_stop = lambda { |_who|
        checks += 1
        checks > 1 ? "Alex reached their $2.00 cap" : nil
      }
      enqueue(wire, calls: [["c1", "read", { "path" => "notes.txt" }]])
      enqueue(wire, text: "never asked")

      turn(engine, session, wire, "go", origin: { client_id: "review:#{grant.id}", author: grant.author })

      expect(requests_on(wire).size).to eq(1)
      expect(checks).to eq(2)
      notice = events.find { |event| event[:type] == :hook_notice }
      expect(notice).to include(hook: "participants", text: "stopped the turn: Alex reached their $2.00 cap")
    end
  end

  # -- r2 M5: what else the shared dispatch carries ---------------------------

  it "cuts a native memory_read at half the window the kernel's client reports (no fixed cap)" do
    memories = File.join(tmp, "config", "samagotchi", "memories")
    FileUtils.mkdir_p(memories)
    File.write(File.join(memories, "big.md"), "x" * 80_000)
    engine = engine_on(ToolHostWires::NATIVE)
    session = session_on(ToolHostWires::NATIVE)
    enqueue(:native, calls: [["c1", "memory_read", { "name" => "big", "scope" => "system" }]])
    enqueue(:native, text: "Read.")

    turn(engine, session, :native, "Read the big memory.")

    run = completed.find { |event| event[:tool] == "memory_read" }
    expect(run).to include(output_truncated: true)
    half = (32_768 * Samagotchi::MemoryBundle::IndexSize.chars_per_token / 2).floor
    kept = sent_text(requests_on(:native).last)[/\[cut: (\d+) of 80014 chars; the rest is in the memory's \.md file/, 1]
    expect(kept.to_i).to be_between(half - 1000, half)
  end

  it "refuses a muted memory_read and asks the user's question on the chat loop" do
    engine = engine_on(ToolHostWires::CHAT, muted_memories: ["secret"])
    session = session_on(ToolHostWires::CHAT)
    enqueue(:chat, calls: [["c1", "memory_read", { "name" => "secret" }],
                           ["c2", "ask_user_question", { "question" => "Which file?", "options" => %w[a.rb b.rb] }]])
    enqueue(:chat, text: "Asked.")

    turn(engine, session, :chat, "Read the secret, then ask me.")

    expect(asked.map { |pending| pending[:question] }).to eq(["Which file?"])
    tools = requests_on(:chat).last.json["messages"].select { |message| message["role"] == "tool" }
    expect(tools.map { |message| message["tool_call_id"] }).to eq(%w[c1 c2])
    expect(tools[0]["content"]).to include("Error: memory 'secret' is muted for this session")
    expect(tools[1]["content"]).to include("a.rb")
  end

  describe "a turn context without a ToolSurface (fail closed)" do
    let(:call) { Samagotchi::Tools::BuiltinCalls.build("read", { "path" => "notes.txt" }) }

    %i[native chat].each do |wire|
      it "answers the #{wire} engine's dispatch with an error output and no activity row" do
        engine = engine_on(ToolHostWires::MODELS[wire])
        engine.switch_model!(ToolHostWires::MODELS[wire])

        dispatched = dispatch_on(engine, call, Samagotchi::TurnContext.none)

        expect(dispatched[:output]).to start_with("[read] Error: ")
        expect(dispatched[:activity]).to be_nil
      end
    end

    # The native prompt names no tools of the surface, so its request goes
    # out; the call it answers raises before the gate. The chat request's
    # tools come from the surface: nothing goes out.
    it "fails each loop's run closed: the native one at its tool call, the chat one before any request" do
      engine = engine_on(ToolHostWires::NATIVE)
      bare = Samagotchi::TurnContext.none(settings: Samagotchi::LLM::TurnSettings.none.with(model_name: "Qwen3.6"))
      messages = [{ role: "user", content: "hi" }]
      enqueue(:native, calls: [["c1", "write", { "path" => "asked.txt", "content" => "no" }]])

      expect { kernel_of(engine).run(messages, context: bare) }.to raise_error(Samagotchi::Tools::MissingSurface)
      expect(requests_on(:native).size).to eq(1)
      expect(File.exist?(File.join(project, "asked.txt"))).to be(false)

      expect { chat_loop_of(engine).complete(messages: messages, context: bare) }
        .to raise_error(Samagotchi::Tools::MissingSurface)
      expect(requests_on(:chat)).to be_empty
    end
  end

  %i[native chat].each do |wire|
    it "tags the #{wire} loop's tool_call and tool_result debug dumps with the turn's model" do
      allow(Samagotchi::Log).to receive(:level?).and_call_original
      allow(Samagotchi::Log).to receive(:level?).with(:debug).and_return(true)
      allow(Samagotchi::Log).to receive(:debug).and_call_original
      engine = engine_on(ToolHostWires::MODELS[wire])
      session = session_on(ToolHostWires::MODELS[wire])
      enqueue(wire, calls: [["c1", "read", { "path" => "notes.txt" }]])
      enqueue(wire, text: "Read.")

      turn(engine, session, wire, "Read the notes.")

      model = ToolHostWires::MODELS[wire].split(":").last
      %w[tool_call tool_result].each do |dump|
        expect(Samagotchi::Log).to have_received(:debug).with(:model, dump, hash_including(model: model, tool: "read"))
      end
    end
  end
end
