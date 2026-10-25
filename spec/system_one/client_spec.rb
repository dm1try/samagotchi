# frozen_string_literal: true

require "tmpdir"
require "samagotchi/cancellation_controller"
require "samagotchi/host_registry"
require "samagotchi/system_one"

RSpec.describe Samagotchi::SystemOne::Client do
  def question(id) = Samagotchi::SystemOne::Question.new(id: id, type: :noul, instructions: "allow #{id}?")
  def answer(id, p) = Samagotchi::SystemOne::Answer.new(id: id, type: :noul, noul: p)
  def client(backend, mode: "audit") = described_class.new(backend: backend, mode: mode, host: "one")

  # One warn and a nil: the ask goes to the user exactly as it would have.
  def expect_no_judgment(reason)
    expect(Samagotchi::Log).to receive(:warn).with(
      :guardrails, "system_one_failed",
      hash_including(echo: /system one: .*#{reason}/, host: "one")
    ).once
  end

  it "answers every question it is asked, in the order asked" do
    backend = Samagotchi::SystemOne::FakeBackend.new { |_state, questions| questions.to_h { |q| [q.id, answer(q.id, 0.98)] } }
    answers = client(backend).ask(state: "git push origin main",
                                  questions: { "git-push" => question("git-push"),
                                               "commit" => { "type" => "noul", "instructions" => "allow a commit?" } })
    expect(answers.keys).to eq(%w[git-push commit])
    expect(answers["commit"]).to have_attributes(type: :noul, noul: 0.98)
  end

  it "takes the turn's cancel controller and still answers" do
    backend = Samagotchi::SystemOne::FakeBackend.new { |_state, questions| questions.to_h { |q| [q.id, answer(q.id, 0.5)] } }
    answers = client(backend).ask(state: "x", questions: { "a" => question("a") },
                                  cancel_controller: Samagotchi::CancellationController.new)
    expect(answers["a"].noul).to eq(0.5)
  end

  it "is nil with no questions, and asks for nothing" do
    expect(client(Samagotchi::SystemOne::FakeBackend.new).ask(state: "x", questions: {})).to be_nil
  end

  it "is nil and warns when the backend fails" do
    expect_no_judgment("BackendError: the judge is asleep")
    backend = Samagotchi::SystemOne::FakeBackend.new(failing: true, error: "the judge is asleep")
    expect(client(backend).ask(state: "x", questions: { "a" => question("a") })).to be_nil
  end

  it "is nil and warns when the backend returns something that isn't answers" do
    backend = Object.new
    def backend.ask(state:, questions:, cancel_controller: nil) = nil

    expect_no_judgment("the backend returned nil")
    expect(client(backend).ask(state: "x", questions: { "a" => question("a") })).to be_nil
  end

  it "is nil and warns when a question gets no answer, or a malformed one" do
    expect_no_judgment("no answer for b")
    backend = Samagotchi::SystemOne::FakeBackend.new({ "a" => answer("a", 0.99) })
    expect(client(backend).ask(state: "x", questions: { "a" => question("a"), "b" => question("b") })).to be_nil

    expect_no_judgment("no answer for a")
    nil_answer = Samagotchi::SystemOne::FakeBackend.new({ "a" => nil })
    expect(client(nil_answer).ask(state: "x", questions: { "a" => question("a") })).to be_nil
  end

  it "refuses questions that aren't a hash of id => question" do
    expect { client(Samagotchi::SystemOne::FakeBackend.new).ask(state: "x", questions: "allow?") }
      .to raise_error(ArgumentError, /questions must be a hash/)
  end

  describe "from_config" do
    let(:config_dir) { Dir.mktmpdir("system-one-config") }

    def registry = Samagotchi::HostRegistry.new(hosts_config: { "splash" => { host: "127.0.0.1", port: 8000, api: :openai } })

    around do |example|
      with_config_home(config_dir) { example.run }
    ensure
      FileUtils.rm_rf(config_dir)
    end

    def write_config(settings)
      File.write(File.join(config_dir, "samagotchi", "config.yml"), YAML.dump({ "guardrails" => { "system_one" => settings } }))
    end

    it "is nil while the mode is off, the default" do
      expect(described_class.from_config(host_registry: registry)).to be_nil
    end

    it "is nil when no host is named, whatever the mode" do
      write_config({ "mode" => "audit" })
      expect(described_class.from_config(host_registry: registry)).to be_nil
    end

    it "builds a client for audit and on, with the host and model it reads" do
      write_config({ "mode" => "on", "host" => "splash", "model" => "Qwen3.8-Flash", "timeout_ms" => 1500 })
      client = described_class.from_config(host_registry: registry)
      expect(client).to have_attributes(mode: "on", host: "splash", model: "Qwen3.8-Flash")
      expect(client.backend).to be_a(Samagotchi::SystemOne::HttpBackend)
    end

    it "takes the model a run names over the configured one" do
      write_config({ "mode" => "audit", "host" => "splash", "model" => "configured-model" })
      client = described_class.from_config(host_registry: registry, model: "run-model")
      expect(client.model).to eq("run-model")
      expect(described_class.from_config(host_registry: registry).model).to eq("configured-model")
    end

    it "reads the settings again on every call, so config.yml changes take effect" do
      write_config({ "mode" => "audit", "host" => "splash" })
      expect(described_class.from_config(host_registry: registry)).not_to be_nil
      write_config({ "mode" => "off", "host" => "splash" })
      expect(described_class.from_config(host_registry: registry)).to be_nil
    end

    it "is nil for a mode the settings don't have, with config's own warning" do
      write_config({ "mode" => "sometimes", "host" => "splash" })
      expect(Samagotchi::Log).to receive(:warn).with(:config, "invalid_value",
                                                     hash_including(echo: /guardrails\.system_one\.mode/))
      expect(described_class.from_config(host_registry: registry)).to be_nil
    end
  end
end
