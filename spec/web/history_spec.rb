# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/prompt_history"

# The web composer shares the TUI's prompt history (PromptHistory): the
# routes record what the page sent once the worker took it, and
# GET /api/history hands the list to the page for ↑/↓.
RSpec.describe Samagotchi::Web::App, "prompt history" do
  let(:manager) do
    Class.new do
      attr_reader :spawned

      def retention_sweep_if_due(**) = nil
      def resume_session(*, **) = nil

      def spawn_session(prompt:, state_dir: nil, **)
        (@spawned ||= []) << prompt
        Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: Dir.pwd)
      end
    end.new
  end
  let(:bridge) { instance_double(Samagotchi::BridgeClient) }
  let(:app) do
    described_class.new(manager: manager, state_dir: @dir, bridge_wait_timeout: 0).tap do |app|
      allow(app).to receive(:live_bridge_client).and_return(bridge)
    end
  end

  around do |example|
    Dir.mktmpdir("web-history") do |dir|
      @dir = dir
      with_env("SAMAGOTCHI_HISTORY_FILE" => File.join(dir, "history.json"), "SAMAGOTCHI_DEFAULT_MODEL" => "TestModel") do
        example.run
      end
    end
  end

  def call(path, method: "GET", body: nil)
    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: method, input: body)
    status, _headers, chunks = app.call(env)
    text = +""
    chunks.each { |c| text << c }
    [status, text.empty? ? nil : JSON.parse(text)]
  end

  def history = Samagotchi::PromptHistory.entries

  def turn(body, result)
    allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(result)
    call("/api/sessions/s1/turn", method: "POST", body: JSON.generate(body)).first
  end

  def command(line, status, extra = {})
    reply = Samagotchi::BridgeClient::Response.new(status: status, body: '{"status":"accepted"}')
    allow(bridge).to receive(:post_command).and_return(reply)
    call("/api/sessions/s1/command", method: "POST", body: JSON.generate({ line: line }.merge(extra))).first
  end

  let(:accepted) { { status: :accepted, ack: { "status" => "accepted" } } }

  describe "GET /api/history" do
    it "returns the entries, oldest first" do
      Samagotchi::PromptHistory.append("first")
      Samagotchi::PromptHistory.append("second")

      expect(call("/api/history")).to eq([200, { "entries" => %w[first second] }])
    end

    it "returns an empty list without a file" do
      expect(call("/api/history")).to eq([200, { "entries" => [] }])
    end
  end

  describe "POST /turn" do
    it "records an accepted prompt" do
      expect(turn({ prompt: "fix the tests" }, accepted)).to eq(202)
      expect(history).to eq(["fix the tests"])
    end

    it "records nothing when the turn wasn't taken" do
      expect(turn({ prompt: "a" }, { status: :refused, code: 409, ack: { "error" => "busy" } })).to eq(409)
      expect(turn({ prompt: "b" }, { status: :timeout, ack: { "detail" => "late" } })).to eq(504)
      expect(turn({ prompt: "c" }, { status: :failed })).to eq(500)

      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_raise(Samagotchi::SessionManager::OwnedByTUI, "s1")
      expect(call("/api/sessions/s1/turn", method: "POST", body: '{"prompt":"d"}').first).to eq(409)

      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_raise(ArgumentError, "Session not found")
      expect(call("/api/sessions/s1/turn", method: "POST", body: '{"prompt":"e"}').first).to eq(404)

      expect(history).to eq([])
    end

    it "records nothing with history: false (an image-only send)" do
      expect(turn({ prompt: "[image: cat.png]", history: false }, accepted)).to eq(202)
      expect(history).to eq([])
    end

    it "never fails the send when the history can't be written" do
      allow(Samagotchi::PromptHistory).to receive(:append).and_raise(Errno::EACCES)

      expect(turn({ prompt: "hi" }, accepted)).to eq(202)
    end
  end

  describe "POST /command" do
    it "records a shell line the worker took" do
      expect(command("!ls", 202)).to eq(202)
      expect(history).to eq(["!ls"])
    end

    it "records neither a /command nor !rollback" do
      expect(command("/model x", 202)).to eq(202)
      expect(command("!rollback", 202)).to eq(202)
      expect(history).to eq([])
    end

    it "records nothing when the command wasn't taken, or with history: false" do
      expect(command("!ls", 408)).to eq(504)
      expect(command("!pwd", 202, history: false)).to eq(202)
      expect(history).to eq([])
    end
  end

  describe "POST /api/sessions" do
    def create(body) = call("/api/sessions", method: "POST", body: JSON.generate(body)).first

    it "records a first shell line, not an idle session nor a /command" do
      expect(create({ idle: true, preview: "hello" })).to eq(201)
      expect(create({ prompt: "/model x" })).to eq(201)
      expect(create({ prompt: "!ls" })).to eq(201)

      expect(history).to eq(["!ls"])
    end
  end
end
