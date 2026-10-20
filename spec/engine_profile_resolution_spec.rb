# frozen_string_literal: true

require "json"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/kernel_loop"

# The Engine resolves its prompt profile with ModelProfile.resolve (config,
# the llama.cpp server's chat template, the name, qwen36): lazily, once per
# model, again after /model, and again before a turn when the last /props
# probe failed. The kernel and the system prompt follow the resolution.
RSpec.describe "Engine prompt profile resolution" do
  let(:gemma4_template) { File.read(File.expand_path("fixtures/llama_cpp/gemma4_template_excerpt.jinja", __dir__)) }
  let(:ornith_props) { JSON.parse(File.read(File.expand_path("fixtures/llama_cpp/props_ornith.json", __dir__))) }

  # A llama.cpp client whose /props answers are queued (the last one repeats).
  # An answer is kept per model, as Client#server_props keeps it (the
  # kernel reads it again each turn: Thinking.opens_thought?); a failed
  # probe is asked again.
  class FakeResolvingClient
    attr_reader :asked, :transport, :prompts

    def initialize(*answers)
      @answers = answers
      @asked = []
      @prompts = []
      @transport = Samagotchi::Client::Transport.new(:llama_cpp)
    end

    def server_props(model: nil)
      return @kept[model] if (@kept ||= {}).key?(model)

      @asked << model
      answer = @answers.size > 1 ? @answers.shift : @answers.first
      @kept[model] = answer if answer&.answered?
      answer
    end

    def invalidate_context_window! = nil
    def context_window(model: nil) = nil

    def complete(prompt, **)
      @prompts << prompt
      { "content" => "ok", "stop" => true }
    end
  end

  def answered(body) = Samagotchi::Client::ServerProps.new(body: body, status: :ok)
  def loading = Samagotchi::Client::ServerProps.new(body: nil, status: :http_error)

  around do |example|
    saved = ENV.values_at("SAMAGOTCHI_DEFAULT_MODEL", "SAMAGOTCHI_MODEL_PROFILE")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "house-blend-35b"
    ENV.delete("SAMAGOTCHI_MODEL_PROFILE")
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"], ENV["SAMAGOTCHI_MODEL_PROFILE"] = saved
  end

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({})
  end

  def engine_with(client)
    registry = Samagotchi::HostRegistry.new(hosts_config: { "main" => { host: "h.test", port: 8081 } })
    registry.client_override = client
    Samagotchi::Engine.new(host_registry: registry)
  end

  def session = Samagotchi::Session.new_session(mode: "assist", model_name: "house-blend-35b", working_directory: Dir.pwd)

  it "asks the server nothing until the profile is needed" do
    client = FakeResolvingClient.new(answered("chat_template" => gemma4_template))
    engine_with(client)

    expect(client.asked).to be_empty
  end

  it "takes the family from the server's chat template when the name says none" do
    client = FakeResolvingClient.new(answered("chat_template" => gemma4_template))
    engine = engine_with(client)

    expect([engine.profile.name, engine.profile_resolution.label]).to eq(["gemma4", "server (chat_template)"])
    expect(client.asked).to eq(["house-blend-35b"])
  end

  it "formats the turn and the system prompt with the resolved profile" do
    client = FakeResolvingClient.new(answered(ornith_props))
    engine = engine_with(client)
    events = []

    engine.run_turn(session, "hi", on_event: ->(e) { events << e })

    expect(client.prompts.first).to start_with("<|im_start|>system")
    started = events.find { |e| e[:type] == :generation_started }
    expect(started).to include(profile: "qwen36", profile_source: "server (chat_template)")
  end

  it "resolves again after a model switch" do
    client = FakeResolvingClient.new(answered(ornith_props), answered("chat_template" => gemma4_template))
    engine = engine_with(client)
    expect(engine.profile.name).to eq("qwen36")

    engine.switch_model!("other-blend")

    expect([engine.profile.name, client.asked]).to eq(["gemma4", %w[house-blend-35b other-blend]])
  end

  # A /stats on a Bridge thread resolving the old model's profile while
  # /model runs: its answer lands after the switch and must not stand for
  # the new model (nor reach the kernel).
  it "keeps no profile resolved for a model switched away while it was asked" do
    client = FakeResolvingClient.new(answered(ornith_props), answered("chat_template" => gemma4_template))
    asking = Queue.new
    gate = Queue.new
    allow(client).to receive(:server_props).and_wrap_original do |original, model:|
      if model == "house-blend-35b"
        asking << true
        gate.pop
      end
      original.call(model: model)
    end
    engine = engine_with(client)
    kernel = engine.instance_variable_get(:@kernel)
    applied = []
    allow(kernel).to receive(:use_profile!).and_wrap_original do |original, resolution|
      applied << resolution.profile.name
      original.call(resolution)
    end

    stats = Thread.new { engine.profile_resolution }
    asking.pop
    engine.switch_model!("other-blend")
    gate << true

    expect(stats.value.profile.name).to eq("qwen36")
    expect(engine.profile.name).to eq("gemma4")
    expect(applied).to eq(["gemma4"])
  end

  it "keeps a resolution for the session: no new probe per turn" do
    client = FakeResolvingClient.new(answered(ornith_props))
    engine = engine_with(client)
    s = session

    engine.run_turn(s, "one")
    engine.run_turn(s, "two")

    expect(client.asked.size).to eq(1)
  end

  it "retries a failed probe before the next turn and rebuilds the system prompt" do
    client = FakeResolvingClient.new(loading, answered("chat_template" => gemma4_template))
    engine = engine_with(client)
    s = session

    engine.run_turn(s, "one")
    expect(engine.profile_resolution).to have_attributes(source: :default, retry: true)
    engine.run_turn(s, "two")

    expect(engine.profile_resolution.label).to eq("server (chat_template)")
    expect(client.prompts.first).to start_with("<|im_start|>system")
    expect(client.prompts.last).not_to include("<|im_start|>")
  end

  it "lets --profile / SAMAGOTCHI_MODEL_PROFILE win over the server" do
    ENV["SAMAGOTCHI_MODEL_PROFILE"] = "qwen36"
    client = FakeResolvingClient.new(answered("chat_template" => gemma4_template))

    expect(engine_with(client).profile_resolution).to have_attributes(source: :env, retry: false)
    expect(client.asked).to be_empty
  end

  it "looks up models: under the alias as typed" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return("ista" => Samagotchi::ModelSettings.new(profile: "gemma4"))
    allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return("ista" => "house-blend-35b")
    engine = engine_with(FakeResolvingClient.new(answered(ornith_props)))

    engine.switch_model!("ista")

    expect(engine.profile_resolution.label).to eq("config (models: ista)")
  end

  it "looks up models: vision under the alias as typed, like the profile" do
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return("ista" => Samagotchi::ModelSettings.new(vision: false))
    allow(Samagotchi::ConfigFile).to receive(:model_aliases).and_return("ista" => "house-blend-35b")
    engine = engine_with(FakeResolvingClient.new(answered(ornith_props)))

    engine.switch_model!("ista")

    expect(engine.send(:turn_vision, session).capability).to have_attributes(value: false, reason: "models: ista sets vision: false")
  end
end

RSpec.describe "Engine#stats_snapshot" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "house-blend-35b") { example.run } }

  before { allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return({}) }

  let(:ornith_props) { JSON.parse(File.read(File.expand_path("fixtures/llama_cpp/props_ornith.json", __dir__))) }

  def engine_with(client, hosts: { "main" => { host: "h.test", port: 8081 } })
    registry = Samagotchi::HostRegistry.new(hosts_config: hosts)
    registry.client_override = client
    Samagotchi::Engine.new(host_registry: registry)
  end

  # /stats before the first turn: no generation has reported the window or
  # the profile yet, so the snapshot asks the server.
  it "fills the context window and the prompt profile before the first turn" do
    client = FakeResolvingClient.new(Samagotchi::Client::ServerProps.new(body: ornith_props, status: :ok))
    def client.context_window(model: nil) = 131_072

    snapshot = engine_with(client).stats_snapshot

    expect(snapshot[:context]).to include(window_tokens: 131_072, window_source: "server")
    expect(snapshot).to include(profile: "qwen36", profile_source: "server (chat_template)")
  end

  it "names the effective model's host as price_host (the cost estimate's hosts.<name>.models prices)" do
    snapshot = engine_with(FakeResolvingClient.new(nil), hosts: { "gw" => { host: "h.test", port: 8081 } }).stats_snapshot

    expect(snapshot[:price_host]).to eq("gw")
  end

  it "falls back to the configured window when the server has none" do
    snapshot = engine_with(FakeResolvingClient.new(nil)).stats_snapshot

    expect(snapshot.dig(:context, :window_tokens)).to be_a(Integer)
    expect(snapshot.dig(:context, :window_source)).not_to eq("server")
  end

  it "keeps what a turn reported" do
    engine = engine_with(FakeResolvingClient.new(nil))
    engine.metrics.call(type: :generation_started, iteration: 1, context_window_tokens: 4096, context_window_source: :server,
                        profile: "gemma4", profile_source: "env")

    expect(engine.stats_snapshot).to include(profile: "gemma4", profile_source: "env")
    expect(engine.stats_snapshot[:context]).to include(window_tokens: 4096)
  end

  it "carries the per-model rows (the Bridge's GET /stats)" do
    engine = engine_with(FakeResolvingClient.new(nil))
    %w[main:a main:b].each do |ref|
      [{ type: :turn_started, session_id: "s", prompt: "p" }, { type: :generation_started, iteration: 1, model_ref: ref },
       { type: :generation_completed, iteration: 1 }, { type: :turn_completed }].each { |event| engine.metrics.call(event) }
    end

    expect(engine.stats_snapshot[:model_segments].map { |row| row[:model_ref] }).to eq(%w[main:a main:b])
  end

  # After /model the old model's ctx % goes; announce_switched_context!
  # counts the history against the new model's window (D4 a).
  describe "the ctx % after /model" do
    def counted_turn(engine, used, model_ref: nil)
      [{ type: :turn_started, session_id: "s", prompt: "p" }, { type: :generation_started, iteration: 1, model_ref: model_ref }.compact,
       { type: :generation_chunk, iteration: 1, content: "a",
         payload: { "usage" => { "prompt_tokens" => used - 800, "completion_tokens" => 800 } } },
       { type: :generation_completed, iteration: 1 }, { type: :turn_completed }].each { |event| engine.metrics.call(event) }
    end

    def engine_on(windows)
      client = FakeResolvingClient.new(nil)
      client.define_singleton_method(:context_window) { |model: nil| windows.fetch(model) }
      engine_with(client)
    end

    it "drops the old model's % at the switch, then sends and keeps the new window's" do
      engine = engine_on("house-blend-35b" => 32_000, "other-blend" => 128_000)
      engine.metrics.call(type: :generation_started, iteration: 1, context_window_tokens: 32_000, context_window_source: :server)
      counted_turn(engine, 12_800)
      engine.instance_variable_set(:@last_context_status, { est_pct: 40.0, bucket: "under60" })
      events = []
      engine.subscribe(observer: ->(event) { events << event if event[:type] == :context_status })

      engine.switch_model!("other-blend")
      expect(engine.session_state_snapshot[:context_status]).to be_nil

      sent = engine.announce_switched_context!
      expect(events.map { |event| event.except(:event_seq) }).to eq([sent])
      expect(sent).to include(bucket: "under20", context_window_tokens: 128_000, context_window_source: "server")
      expect(sent[:usage]).to include(estimated_pct: 10.0, estimated_used_tokens: 12_800, window_tokens: 128_000)
      expect(engine.session_state_snapshot[:context_status]).to eq(est_pct: 10.0, bucket: "under20")
      # The metrics' context names the new window too: a page loaded now
      # counts its % from the timing's context (savedCtxPct).
      expect(engine.metrics.snapshot[:context]).to include(used_tokens: 12_800, window_tokens: 128_000, window_source: "server")
    end

    it "sends usage nil when the new window doesn't resolve, and nothing before a counted turn" do
      engine = engine_on("house-blend-35b" => 32_000)
      expect(engine.announce_switched_context!).to be_nil

      counted_turn(engine, 12_800)
      engine.switch_model!("other-blend")
      allow(engine).to receive(:current_context_window).and_return(nil)

      expect(engine.announce_switched_context!).to include(usage: nil, bucket: nil, context_window_tokens: nil)
      expect(engine.session_state_snapshot[:context_status]).to be_nil
    end

    # A process that loads the session on another model than its last turn
    # ran on (a --resume'd REPL with --model, a worker woken after a /model
    # with no turn since): the status /model would have sent, at #session=,
    # on the configured window only: it runs before a worker's Bridge
    # serves, so it never asks the server (no /props GET, no model list).
    it "counts a loaded session's context against the configured window when its last turn ran on another" do
      saved = Samagotchi::Session.new_session(mode: "assist", model_name: "house-blend-35b", working_directory: Dir.pwd)
      earlier = engine_on("house-blend-35b" => 128_000)
      earlier.session = saved
      earlier.metrics.call(type: :generation_started, iteration: 1, context_window_tokens: 32_000, context_window_source: :server)
      counted_turn(earlier, 12_800, model_ref: "other-blend")
      earlier.metrics.persist
      expect(earlier.session_state_snapshot[:context_status]).to eq(est_pct: 40.0, bucket: "40plus")

      [[128_000, { est_pct: 10.0, bucket: "under20" }], [nil, nil]].each do |configured, status|
        client = FakeResolvingClient.new(nil)
        client.define_singleton_method(:context_window) { |model: nil| (asked << [:window, model]) && 64_000 }
        registry = Samagotchi::HostRegistry.new(hosts_config: { "main" => { host: "h.test", port: 8081, window_tokens: configured }.compact })
        registry.client_override = client
        engine = Samagotchi::Engine.new(host_registry: registry)
        events = []
        engine.subscribe(observer: ->(event) { events << event if event[:type] == :context_status })

        engine.session = saved

        expect(client.asked).to be_empty
        expect(engine.session_state_snapshot[:context_status]).to eq(status)
        expect(engine.metrics.snapshot[:context]).to include(used_tokens: 12_800, window_tokens: configured)
        expect(events.map { |event| event[:context_window_tokens] }).to eq([configured])
      end
    end

    it "keeps a loaded session's saved status when its last turn ran on the effective model, or named none" do
      ["house-blend-35b", nil].each do |ref|
        engine = engine_on("house-blend-35b" => 128_000)
        engine.metrics.call(type: :generation_started, iteration: 1, context_window_tokens: 32_000, context_window_source: :server)
        counted_turn(engine, 12_800, model_ref: ref)

        engine.session = Samagotchi::Session.new_session(mode: "assist", model_name: "house-blend-35b", working_directory: Dir.pwd)

        expect(engine.session_state_snapshot[:context_status]).to eq(est_pct: 40.0, bucket: "40plus")
      end
    end
  end

  # What a turn reported belongs to the model it ran on: after /model to
  # another native model, /stats resolves the new model's profile and window.
  it "drops the profile and window a turn reported for the model before /model" do
    engine = engine_with(FakeResolvingClient.new(nil))
    engine.metrics.call(type: :generation_started, iteration: 1, context_window_tokens: 4096, context_window_source: :server,
                        profile: "gemma4", profile_source: "env")
    engine.switch_model!("other-qwen-model")

    snapshot = engine.stats_snapshot
    expect(snapshot).to include(profile: "qwen36")
    expect(snapshot[:profile_source]).not_to eq("env")
    expect(snapshot.dig(:context, :window_tokens)).to be_a(Integer).and(satisfy { |tokens| tokens != 4096 })
  end

  # A single-model llama.cpp answers any name with the model it loaded.
  it "names the served model from /props before the first turn, for the name asked" do
    engine = engine_with(FakeResolvingClient.new(Samagotchi::Client::ServerProps.new(body: ornith_props, status: :ok)))

    expect(engine.stats_snapshot).to include(served_model: ornith_props["model_alias"], served_model_for: "house-blend-35b")
  end

  # The chat loop uses no prompt profile; a native turn's one must not
  # show after /model moved to a chat host.
  it "has no prompt profile for a chat host's model" do
    engine = engine_with(FakeResolvingClient.new(nil),
                         hosts: { "main" => { host: "h.test", port: 8081 },
                                  "chat" => { host: "c.test", port: 8000, api: :openai } })
    engine.metrics.call(type: :generation_started, iteration: 1, profile: "qwen36", profile_source: "name")
    allow(engine).to receive(:current_context_window).and_return(nil)
    engine.switch_model!("chat:some-model")

    expect(engine.stats_snapshot).not_to include(:profile, :profile_source)
  end

  it "keeps the served model a turn reported for the current model" do
    engine = engine_with(FakeResolvingClient.new(nil))
    engine.metrics.call(type: :generation_completed, served_model: "ornith-x", requested_model: "house-blend-35b")

    expect(engine.stats_snapshot).to include(served_model: "ornith-x", served_model_for: "house-blend-35b")
  end

  it "drops a served model reported for another model (after /model), asking the server again" do
    engine = engine_with(FakeResolvingClient.new(nil))
    engine.metrics.call(type: :generation_completed, served_model: "ornith-x", requested_model: "older-model")

    expect(engine.stats_snapshot).to include(served_model: nil, served_model_for: nil)
  end

  it "puts only a reported served model in the cheap session state (no probe)" do
    client = FakeResolvingClient.new(Samagotchi::Client::ServerProps.new(body: ornith_props, status: :ok))
    engine = engine_with(client)

    expect(engine.session_state_snapshot).to include(served_model: nil, served_model_for: nil)
    expect(client.asked).to eq([])

    engine.metrics.call(type: :generation_completed, served_model: "ornith-x", requested_model: "house-blend-35b")
    expect(engine.session_state_snapshot).to include(served_model: "ornith-x", served_model_for: "house-blend-35b")
  end

  # /stats' budget line comes from here, the session's own override included.
  it "names a session's own LLM context budget" do
    engine = engine_with(FakeResolvingClient.new(nil))
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "house-blend-35b", working_directory: Dir.pwd)
    session.llm_context = Samagotchi::LLMContextOverride.new(budget_tokens: 64_000)
    engine.session = session

    expect(engine.stats_snapshot[:llm_context]).to include(budget_tokens: 64_000, budget_where: "the session")
  end

  it "builds the metrics snapshot once per session state" do
    engine = engine_with(FakeResolvingClient.new(nil))
    engine.metrics.call(type: :generation_completed, served_model: "ornith-x", requested_model: "house-blend-35b")
    expect(engine.metrics).to receive(:snapshot).once.and_call_original

    expect(engine.session_state_snapshot).to include(served_model: "ornith-x", served_model_for: "house-blend-35b")
  end
end
