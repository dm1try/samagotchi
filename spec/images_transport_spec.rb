# frozen_string_literal: true

require "json"
require "net/http"
require "tmpdir"
require "samagotchi/session_manager"
require "samagotchi/worker"
require "samagotchi/bridge"
require "support/test_kernel"

# Images between a UI and the worker: refs only (never paths or bytes),
# through the Bridge, the input files, the worker and the snapshot.
RSpec.describe "Images in transport" do
  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    WebMock.allow_net_connect! if defined?(WebMock)
    example.run
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:tmpdir) { Dir.mktmpdir("images-transport") }
  let!(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.save(state_dir: tmpdir)
    end
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
  let(:ref) do
    Samagotchi::ImageStore.ingest(session_dir, path: File.expand_path("fixtures/images/tiny.png", __dir__),
                                               resizer: Samagotchi::ImageResizer.new(nil))
  end
  let(:wire_ref) { { file: ref[:file], name: "shot.png" } }
  let!(:engine) do
    Samagotchi::Engine.new(client: test_client,
                           kernel: test_kernel)
  end

  after { FileUtils.rm_rf(tmpdir) }

  def write_sidecar(format)
    FileUtils.mkdir_p(session_dir)
    File.write(File.join(session_dir, "bridge.json"), JSON.generate("port" => 1, "session_id" => session.id, "input_format" => format))
  end

  def queued_inputs
    Dir.glob(File.join(session_dir, "input", "*.json")).sort.map { |f| JSON.parse(File.read(f)) }
  end

  describe "SessionManager input files" do
    it "writes and reads a turn's image refs" do
      path = Samagotchi::SessionManager.write_turn_input(session.id, prompt: "look", images: [wire_ref], state_dir: tmpdir)
      expect(JSON.parse(File.read(path))["images"]).to eq([{ "file" => ref[:file], "name" => "shot.png" }])
      expect(Samagotchi::SessionInbox.input_has_images?(path)).to be(true)

      claimed = Samagotchi::SessionInbox.claim_input_file(path)
      expect(Samagotchi::SessionInbox.read_input(claimed)).to eq(Samagotchi::SessionInbox::Input.new(prompt: "look", images: [wire_ref]))
    end

    it "writes the refs whatever input format the sidecar advertises" do
      write_sidecar(2)
      path = Samagotchi::SessionManager.write_turn_input(session.id, prompt: "look", images: [wire_ref], state_dir: tmpdir)
      expect(Samagotchi::SessionInbox.input_has_images?(path)).to be(true)
    end
  end

  describe "Bridge POST /turn" do
    let(:events) { [] }

    before do
      engine.subscribe(observer: ->(event) { events << event })
      @bridge = Samagotchi::Bridge.new(engine: engine, state_dir: tmpdir, session_id: session.id,
                                       input_format: Samagotchi::SessionInbox::INPUT_FORMAT).start
      @port = JSON.parse(File.read(File.join(session_dir, "bridge.json")))["port"]
    end

    after { @bridge&.stop }

    def post(body)
      res = Net::HTTP.post(URI("http://127.0.0.1:#{@port}/session/#{session.id}/turn"),
                           body.is_a?(String) ? body : JSON.generate(body), "Content-Type" => "application/json")
      [res.code.to_i, (JSON.parse(res.body) rescue res.body)]
    end

    it "queues a ref to an uploaded image and announces it" do
      status, = post(session_id: session.id, prompt: "look", client_id: "web:1", images: [ref.merge(name: "shot.png")])

      expect(status).to eq(202)
      expect(queued_inputs.first["images"]).to eq([{ "file" => ref[:file], "name" => "shot.png" }])
      expect(events.find { |e| e[:type] == :turn_enqueued }[:images]).to eq([wire_ref])
    end

    it "refuses paths, traversal, unknown files and non-lists" do
      [[{ path: "/etc/passwd" }], [{ file: "../../etc/passwd" }], [{ file: "images/#{"0" * 16}.png" }], "images/x.png"].each do |images|
        status, body = post(session_id: session.id, prompt: "look", images: images)
        expect([status, body["error"]]).to eq([400, "bad_images"]), images.inspect
      end
      expect(queued_inputs).to be_empty
    end

    it "answers 413 to a body over 1 MB without reading it" do
      status, body = post(JSON.generate(session_id: session.id, prompt: "x" * 1_100_000))
      expect([status, body["error"]]).to eq([413, "too_large"])
    end
  end

  describe "the worker" do
    let(:turns) { Queue.new }

    before do
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
    end

    after do
      @thread&.kill
      @thread&.join(2)
    end

    def start_worker
      worker = Samagotchi::Worker.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir, idle_exit_minutes: 0, poll_interval: 0.05)
      @thread = Thread.new { worker.run }
      @thread.report_on_exception = false
      expect(wait_until { File.exist?(File.join(session_dir, "bridge.json")) }).to be_truthy
      sleep(0.1)
    end

    def queue_input(prompt, images: [])
      Samagotchi::SessionManager.write_turn_input(session.id, prompt: prompt, images: images, state_dir: tmpdir)
      sleep(0.002) # distinct timestamps keep the files in order
    end

    it "runs a queued image turn with its refs, and leaves image lines out of a mid-turn merge" do
      merged = Queue.new
      allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
        if prompt == "first"
          queue_input("steer")
          queue_input("look", images: [wire_ref])
          queue_input("after")
          merged << kwargs[:pending_input].call
        end
        turns << [prompt, kwargs[:images]]
        instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false)
      end
      start_worker
      queue_input("first")

      expect(merged.pop(timeout: 3)&.map(&:text)).to eq(["steer"])
      runs = Array.new(3) { turns.pop(timeout: 3) }
      expect(runs).to eq([["first", []], ["look", [wire_ref]], ["after", []]])
    end

    it "gives a failed image turn's refs back with its prompt" do
      events = Queue.new
      engine.subscribe(observer: ->(event) { events << event })
      allow(engine).to receive(:run_turn) { raise Samagotchi::LLM::VisionUnsupported.new("main: nope", host: "main") }
      start_worker
      queue_input("look", images: [wire_ref])

      restored = wait_until do
        list = []
        list << events.pop until events.empty?
        list.find { |e| e[:type] == :prompt_restored }
      end
      expect(restored).to include(prompt: "look", images: [wire_ref])
    end
  end

  describe Samagotchi::Bridge::TurnAccumulator do
    it "keeps images on queued turns, the current turn and its tool parts" do
      acc = described_class.new
      acc.call(type: :turn_enqueued, enqueued_id: "e1", client_id: "web:1", prompt: "look", images: [wire_ref])
      expect(acc.queued.first[:images]).to eq([wire_ref])

      acc.call(type: :turn_started, prompt: "look", origin: { enqueued_id: "e1" }, images: [ref])
      acc.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "read", params: "a.png")
      acc.call(type: :tool_call_completed, iteration: 1, call_index: 1, output: "Image a.png attached.", images: [ref])
      turn = acc.current_turn
      expect(turn[:images]).to eq([ref])
      expect(turn[:parts].first[:images]).to eq([ref])
      expect(acc.queued).to be_empty
    end
  end
end
