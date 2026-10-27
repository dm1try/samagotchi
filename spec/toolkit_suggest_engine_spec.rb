# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "support/thinking_off"
require "support/test_kernel"

RSpec.describe Samagotchi::Engine do
  include_context "thinking off"

  before do
    allow(Samagotchi::Toolkit).to receive(:config_kits).and_return({
      "web" => { "base" => "lean", "description" => "Browser work" },
      "coding" => { "base" => "child", "description" => "Code changes" }
    })
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.mode").and_return("audit")
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.threshold").and_return(0.5)
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.defer_turns").and_return(3)
    allow(Samagotchi::Config).to receive(:get).with("toolkit.suggest.defer_tokens").and_return(5000)
  end

  after { @engine&.shutdown }

  def build_engine
    client = test_client
    @engine = described_class.new(client: client, kernel: test_kernel(client: client), model_name: "Gemma-4B-it")
  end

  def session
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd).tap do |s|
      s.toolkit = Samagotchi::Toolkit.new(name: "full")
      s.toolkit_origin = "default"
    end
  end

  def start(engine, session: self.session, prompt: "Fix the browser workflow")
    turn = Struct.new(:session, :prompt, :origin).new(session, prompt, Struct.new(:author).new(nil))
    engine.send(:start_toolkit_suggestion_audit, turn)
  end

  it "runs the ask off the turn thread using a copied question and leaves the session unchanged" do
    engine = build_engine
    s = session
    started = Queue.new
    release = Queue.new
    system_one = instance_double(Samagotchi::SystemOne::Client)
    allow(system_one).to receive(:host).and_return("judge")
    allow(system_one).to receive(:ask) do |state:, questions:|
      started << [state, questions.keys]
      release.pop
      nil
    end
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)

    begin
      start(engine, session: s)
      state, question_ids = pop!(started, "the audit question")

      expect(state).to eq(project: "samagotchi", prompt: "Fix the browser workflow")
      expect(question_ids).to eq(["toolkit"])
      expect(s.toolkit.name).to eq("full")
      expect(s.toolkit_origin).to eq("default")
    ensure
      release << true
      engine.shutdown
    end
  end

  it "logs every offered kit's rules and the built-ins, with no tool list taken before plugins load" do
    engine = build_engine
    dir = Dir.mktmpdir("toolkit-audit")
    engine.instance_variable_set(:@session_state_dir, File.join(dir, "sessions"))
    engine.instance_variable_set(:@host_registry, double(host_for_model: [double(name: "model", remote?: true, root_url: "https://model:443"), nil],
                                                         find_entry: nil))
    allow(engine).to receive(:effective_model_name).and_return("model")
    answer = Samagotchi::SystemOne::Answer.new(id: "toolkit", type: :choice, choice: "kit:web", confidence: 0.9)
    system_one = instance_double(Samagotchi::SystemOne::Client, host: "judge", ask: { "toolkit" => answer })
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)

    start(engine)
    engine.instance_variable_get(:@toolkit_audit_thread).join(5)
    line = JSON.parse(File.readlines(File.join(dir, Samagotchi::ToolkitSuggest::FILE)).last)

    expect(line["kits"].keys).to contain_exactly("full", "web", "coding")
    expect(line["kits"]["full"]).to include("all_core" => true, "groups" => "all")
    expect(line["kits"]["web"]["all_core"]).to be(false)
    expect(line["core_tools"]).to include("read", "write")
    expect(line).not_to have_key("suggested")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "joins the audit thread on shutdown, with the short audit timeout" do
    engine = build_engine
    started = Queue.new
    release = Queue.new
    system_one = instance_double(Samagotchi::SystemOne::Client, host: "judge")
    allow(system_one).to receive(:ask) do |**|
      started << true
      release.pop
      nil
    end
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)
    begin
      start(engine)
      pop!(started, "the audit ask to start")
      release << true
      engine.shutdown
    ensure
      release << true
    end

    expect(engine.instance_variable_get(:@toolkit_audit_thread)).not_to be_alive
    expect(Samagotchi::Engine::TOOLKIT_AUDIT_JOIN_SECONDS).to be < Samagotchi::Engine::SHUTDOWN_JOIN_SECONDS
    expect(Samagotchi::Engine::TOOLKIT_AUDIT_JOIN_SECONDS).to be >= 1.0
  end

  it "says so when an eligible turn goes unasked because the last ask still runs" do
    engine = build_engine
    engine.instance_variable_set(:@host_registry, double(host_for_model: [double(name: "model", remote?: true), nil]))
    allow(engine).to receive(:effective_model_name).and_return("model")
    started = Queue.new
    release = Queue.new
    system_one = instance_double(Samagotchi::SystemOne::Client, host: "judge")
    allow(system_one).to receive(:ask) do |**|
      started << true
      release.pop
      nil
    end
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)
    allow(Samagotchi::Log).to receive(:info)

    begin
      start(engine)
      pop!(started, "the first audit ask")
      start(engine)

      expect(Samagotchi::Log).to have_received(:info).with(:toolkit, "toolkit_suggest_in_flight_skipped",
                                                           hash_including(:session_id))
      expect(system_one).to have_received(:ask).once
    ensure
      release << true
    end
  end

  it "skips a shared local System 1 host before starting the ask" do
    engine = build_engine
    local_host = double(name: "judge", remote?: false)
    registry = double(host_for_model: [local_host, nil])
    engine.instance_variable_set(:@host_registry, registry)
    allow(engine).to receive(:effective_model_name).and_return("model")
    system_one = instance_double(Samagotchi::SystemOne::Client, host: "judge")
    allow(system_one).to receive(:ask)
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)
    allow(Samagotchi::Log).to receive(:info)

    start(engine)

    expect(Samagotchi::Log).to have_received(:info).with(
      :toolkit, "toolkit_suggest_shared_host_skipped",
      hash_including(host: "judge")
    )
    expect(system_one).not_to have_received(:ask)
  end

  it "skips a local System 1 host under another name for the model's server root (D7)" do
    engine = build_engine
    model_host = double(name: "splash", remote?: false, root_url: "http://127.0.0.1:8080")
    judge_host = double(name: "judge", root_url: "HTTP://127.0.0.1:8080")
    registry = double(host_for_model: [model_host, nil])
    allow(registry).to receive(:find_entry).with("judge").and_return(judge_host)
    engine.instance_variable_set(:@host_registry, registry)
    allow(engine).to receive(:effective_model_name).and_return("model")
    system_one = instance_double(Samagotchi::SystemOne::Client, host: "judge")
    allow(system_one).to receive(:ask)
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)
    allow(Samagotchi::Log).to receive(:info)

    start(engine)

    expect(Samagotchi::Log).to have_received(:info).with(:toolkit, "toolkit_suggest_shared_host_skipped",
                                                         hash_including(host: "judge"))
    expect(system_one).not_to have_received(:ask)
  end

  it "asks when the local System 1 host is another server" do
    engine = build_engine
    model_host = double(name: "splash", remote?: false, root_url: "http://127.0.0.1:8080")
    registry = double(host_for_model: [model_host, nil], find_entry: double(root_url: "http://127.0.0.1:8082"))
    engine.instance_variable_set(:@host_registry, registry)
    allow(engine).to receive(:effective_model_name).and_return("model")
    asked = Queue.new
    system_one = instance_double(Samagotchi::SystemOne::Client, host: "judge")
    allow(system_one).to receive(:ask) { |**| (asked << true) && nil }
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)

    start(engine)

    expect(pop!(asked, "the audit ask")).to be(true)
  end

  it "reads neither the kits nor the suggestion log for a session that can't be asked" do
    engine = build_engine
    binding = engine.instance_variable_get(:@toolkit_binding)
    allow(binding).to receive(:kits).and_call_original
    allow(Samagotchi::ToolkitSuggest).to receive(:last_suggestion).and_call_original
    s = session
    s.toolkit_origin = "chosen"

    start(engine, session: s)

    expect(binding).not_to have_received(:kits)
    expect(Samagotchi::ToolkitSuggest).not_to have_received(:last_suggestion)
  end

  it "reads the suggestion log only on the defer path, once the session has a model reply" do
    engine = build_engine
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(nil)
    allow(Samagotchi::ToolkitSuggest).to receive(:last_suggestion).and_return(nil)
    s = session

    start(engine, session: s)
    expect(Samagotchi::ToolkitSuggest).not_to have_received(:last_suggestion)

    s.messages << { role: "user", turn_id: "t1", content: "hi" } << { role: "model", content: "hello" }
    start(engine, session: s)
    expect(Samagotchi::ToolkitSuggest).to have_received(:last_suggestion).once
  end

  it "warns when the audit ask fails without affecting the turn" do
    engine = build_engine
    model_host = double(name: "model", remote?: true)
    engine.instance_variable_set(:@host_registry, double(host_for_model: [model_host, nil]))
    allow(engine).to receive(:effective_model_name).and_return("model")
    system_one = instance_double(Samagotchi::SystemOne::Client, host: "judge")
    allow(system_one).to receive(:ask).and_raise("request failed")
    allow(Samagotchi::SystemOne::Client).to receive(:from_config).and_return(system_one)
    expect(Samagotchi::Log).to receive(:warn).with(
      :toolkit, "toolkit_suggest_failed",
      hash_including(error: "RuntimeError")
    )

    s = session
    start(engine, session: s)
    engine.instance_variable_get(:@toolkit_audit_thread).join

    expect(s.toolkit.name).to eq("full")
    expect(s.toolkit_origin).to eq("default")
  end
end
