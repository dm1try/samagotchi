# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_inbox"
require "samagotchi/session_manager"
require "samagotchi/bridge"
require "samagotchi/bridge_client"
require "samagotchi/guardrail_wiring"
require "samagotchi/web/app"

# A turn's author (who wrote it when it isn't the session's owner) rides
# with the turn: chi web's principal → SessionManager.deliver_turn → the
# Bridge or the input file → the turn's origin → GuardrailWiring. An
# owner's turn carries none anywhere, so its input file and its session
# are byte for byte what they were (the prompt-caching invariants).
RSpec.describe "a turn's author" do
  let(:state_dir) { Dir.mktmpdir("turn-author") }

  after { FileUtils.rm_rf(state_dir) }

  def read_file(path) = JSON.parse(File.read(path))

  describe Samagotchi::SessionInbox do
    let(:session_dir) { File.join(state_dir, "s1") }

    it "writes an author into the input file and reads it into the origin" do
      path = described_class.write_input(session_dir, prompt: "hi", client_id: "web:t", enqueued_id: "e1", author: "p:p_1")

      expect(read_file(path)).to eq("prompt" => "hi", "client_id" => "web:t", "enqueued_id" => "e1", "author" => "p:p_1")
      expect(described_class.read_input(path).origin).to eq(client_id: "web:t", enqueued_id: "e1", author: "p:p_1")
    end

    it "writes no author for the owner (nil), so the file and the origin are as before" do
      path = described_class.write_input(session_dir, prompt: "hi", client_id: "web:t", enqueued_id: "e1", author: nil)

      expect(File.read(path)).to eq('{"prompt":"hi","client_id":"web:t","enqueued_id":"e1"}')
      expect(described_class.read_input(path).origin).to eq(client_id: "web:t", enqueued_id: "e1")
    end
  end

  describe Samagotchi::SessionManager, ".deliver_turn" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: state_dir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: state_dir) }
    let(:bridge) { instance_double(Samagotchi::BridgeClient) }
    let(:accepted) { Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}') }

    before { @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker") }

    after do
      @lock.release
      described_class.forget_spawns
    end

    def deliver(**options)
      described_class.deliver_turn(session.id, prompt: "hi", client_id: "web:t", state_dir: state_dir, bridge: -> { bridge },
                                               **options)
    end

    def input_files = Dir.glob(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR, "*")).map { |p| read_file(p) }

    it "posts the author to the Bridge only when there is one" do
      allow(bridge).to receive(:post_turn).with(prompt: "hi", client_id: "web:t", author: "p:p_1").and_return(accepted)
      allow(bridge).to receive(:post_turn).with(prompt: "hi", client_id: "web:t").and_return(accepted)

      expect(deliver(author: "p:p_1").status).to eq(:accepted)
      expect(deliver(author: nil).status).to eq(:accepted)
      expect(bridge).to have_received(:post_turn).twice
    end

    it "writes the author into the fallback file only when there is one" do
      allow(bridge).to receive(:post_turn).and_raise(Errno::ECONNREFUSED)

      deliver(author: "p:p_1")
      deliver(author: nil)

      expect(input_files.map { |input| input["author"] }).to contain_exactly("p:p_1", nil)
      expect(input_files.map(&:keys)).to contain_exactly(%w[prompt client_id enqueued_id author],
                                                         %w[prompt client_id enqueued_id])
    end
  end

  describe Samagotchi::Bridge, "POST /session/:id/turn" do
    let(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
    let(:session_dir) { Samagotchi::Session.session_dir("s1", state_dir: state_dir) }

    before do
      WebMock.allow_net_connect! if defined?(WebMock)
      @bridge = described_class.new(engine: engine, state_dir: state_dir, session_id: "s1", heartbeat_interval: 0.2).start
      @client = Samagotchi::BridgeClient.new(session_id: "s1", port: read_file(File.join(session_dir, "bridge.json"))["port"])
    end

    after do
      @bridge.stop
      WebMock.disable_net_connect! if defined?(WebMock)
    end

    def queued
      Samagotchi::SessionInbox.find_new_input_files(session_dir).sort.map { |path| read_file(path) }
    end

    it "carries a posted author into the input file, and writes none without one" do
      expect(@client.post_turn(prompt: "theirs", client_id: "web:t", author: "p:p_1").status).to eq(202)
      expect(@client.post_turn(prompt: "mine", client_id: "web:t").status).to eq(202)

      theirs, mine = queued
      expect(theirs).to include("prompt" => "theirs", "author" => "p:p_1")
      expect(mine.keys).to eq(%w[prompt client_id enqueued_id])
    end

    it "drops an author that isn't a non-empty string" do
      @client.send(:post, "turn", { session_id: "s1", prompt: "odd", author: { "kind" => "x" }, deadline: Time.now.to_f + 5 },
                   read_body: true)
      @client.send(:post, "turn", { session_id: "s1", prompt: "empty", author: "", deadline: Time.now.to_f + 5 }, read_body: true)

      expect(queued.map(&:keys)).to all(eq(%w[prompt enqueued_id]))
    end
  end

  describe Samagotchi::Web::App, "POST /api/sessions/:id/turn" do
    let(:app) { described_class.new(state_dir: state_dir, bridge_wait_timeout: 0) }

    it "delivers the owner's turn with no author (the principal's, never the body's)" do
      result = Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: { "status" => "accepted" })
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return(result)
      env = Rack::MockRequest.env_for("/api/sessions/s1/turn", "HTTP_HOST" => "127.0.0.1", method: "POST",
                                                               input: JSON.generate(prompt: "hi", author: "p:forged", history: false))

      expect(app.call(env).first).to eq(202)
      expect(Samagotchi::SessionManager).to have_received(:deliver_turn).with("s1", hash_including(author: nil))
    end
  end

  describe Samagotchi::Engine, "#run_turn" do
    around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

    let(:client) { test_client }
    let(:kernel) { test_kernel(client: client) }
    let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
    let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }

    let(:result) do
      Samagotchi::LLM::ModelResult.new(text: "done", conversation: [{ role: "model", content: "done" }], exhausted: false,
                                       pending_tool_calls: false, tool_activity: [], canceled: false)
    end

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(kernel).to receive(:run).and_return(result)
    end

    def wiring = engine.instance_variable_get(:@guardrail_wiring)

    it "hands the origin's author to the guardrails and the boundary events" do
      authors = []
      allow(kernel).to receive(:run) do
        authors << wiring.turn_author
        result
      end
      events = []
      origin = { client_id: "review:p_1", enqueued_id: "e1", author: "p:p_1" }

      engine.run_turn(session, "hi", origin: origin, on_event: ->(e) { events << e })

      expect(authors).to eq(["p:p_1"])
      expect(events.find { |e| e[:type] == :turn_started }).to include(origin: origin)
    end

    it "leaves an owner's turn without one: no author for the guardrails, none in the saved session" do
      engine.run_turn(session, "hi", origin: { client_id: "web:t", enqueued_id: "e1" })

      expect(wiring.turn_author).to be_nil
      expect(JSON.generate(session.to_h)).not_to include("author")
    end
  end
end
