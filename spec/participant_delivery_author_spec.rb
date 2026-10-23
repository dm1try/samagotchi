# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/worker"
require "samagotchi/bridge"
require "samagotchi/bridge_client"
require "samagotchi/queued_command"
require "samagotchi/participants"
require "samagotchi/web/app"
require "samagotchi/session_access/remote"
require "samagotchi/session_access/web_bridge_client"
require_relative "support/remote_backend"

# A participant's author survives every way their input reaches a
# session: merged mid-turn (the drain), a /word input file or POST /turn
# that becomes a command, a queued turn's announcement. The owner's
# events and commands carry no author key.
RSpec.describe "a participant's author on delivery" do
  let(:tmpdir) { Dir.mktmpdir("delivery-author") }

  after { FileUtils.rm_rf(tmpdir) }

  def read_file(path) = JSON.parse(File.read(path))

  describe Samagotchi::QueuedCommand do
    it "names a participant's author in its events, the owner's none" do
      expect(described_class.mint("/model x", client_id: "web:t", author: "p:p_1").event_fields).to include(author: "p:p_1")
      expect(described_class.mint("/model x", client_id: "web:t").event_fields.keys).to eq(%i[command_id client_id line])
    end
  end

  describe Samagotchi::Worker do
    around do |example|
      WebMock.allow_net_connect! if defined?(WebMock)
      with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run }
    ensure
      WebMock.disable_net_connect! if defined?(WebMock)
    end

    let!(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let!(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
    let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }
    let(:drained) { Queue.new }
    let(:events) { Queue.new }
    let(:grant) do
      grants = Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: tmpdir))
      Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: tmpdir).grant
    end

    before do
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive_messages(start_idle: nil, stop_idle: nil)
      engine.subscribe(observer: ->(event) { events << event if %i[command_queued].include?(event[:type]) })
    end

    after do
      @thread&.kill
      @thread&.join(2)
    end

    def start_worker
      worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                   idle_exit_minutes: 0, poll_interval: 0.02)
      @thread = Thread.new { worker.run }
      @thread.report_on_exception = false
    end

    it "merges a participant's line mid-turn as their own message, with author and name, apart from the owner's" do
      author = grant.author
      engine.session_state_dir = tmpdir
      allow(engine).to receive(:run_turn) do |turn_session, _prompt, **kwargs|
        engine.instance_variable_get(:@participants).refresh!(turn_session)
        Samagotchi::SessionInbox.write_input(session_dir, prompt: "owner steer", client_id: "web:o")
        Samagotchi::SessionInbox.write_input(session_dir, prompt: "is step 3 safe?", client_id: "web:t", author: author)
        drained << kwargs[:pending_input].call
        result
      end
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "first", client_id: "web:o", enqueued_id: "e1")

      lines = pop!(drained, "the drain's lines")
      expect(lines.map { |l| [l.text, l.author, l.author_name] })
        .to eq([["owner steer", nil, nil], ["is step 3 safe?", author, "Alex"]])
      expect(Samagotchi::Steer.merge(lines).messages)
        .to eq([{ role: "user", kind: "input", content: "owner steer" },
                { role: "user", kind: "input", content: "is step 3 safe?", author: author, author_name: "Alex" }])
    end

    it "saves a participant's prompt as theirs before the loop's first boundary (a worker killed there keeps the author)" do
      author = grant.author
      engine.session_state_dir = tmpdir
      saved = Queue.new
      allow(engine).to receive(:run_turn) do |turn_session, _prompt, **|
        saved << Samagotchi::Session.load(turn_session.id, state_dir: tmpdir).messages.last
        result
      end
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "is step 3 safe?", client_id: "web:t", author: author)

      expect(pop!(saved, "the running save's last message"))
        .to eq(role: "user", content: "is step 3 safe?", author: author, author_name: "Alex")
    end

    it "queues a participant's /word input file as a command that names its author; the owner's names none" do
      allow(engine).to receive(:run_turn).and_return(result)
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "/title theirs", client_id: "web:t", author: "p:p_1")

      theirs = pop!(events, "the participant's command_queued")
      expect(theirs).to include(line: "/title theirs", author: "p:p_1")

      Samagotchi::SessionInbox.write_input(session_dir, prompt: "/title mine", client_id: "web:o")
      mine = pop!(events, "the owner's command_queued")
      expect(mine).to include(line: "/title mine")
      expect(mine).not_to have_key(:author)
    end
  end

  describe Samagotchi::Bridge, "POST /session/:id/turn" do
    let(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
    let(:session_dir) { Samagotchi::Session.session_dir("s1", state_dir: tmpdir) }
    let(:announced) { [] }
    let(:commands) { [] }

    before do
      WebMock.allow_net_connect! if defined?(WebMock)
      engine.subscribe(observer: ->(event) { announced << event })
      @bridge = described_class.new(engine: engine, state_dir: tmpdir, session_id: "s1", heartbeat_interval: 0.2,
                                    on_command: lambda { |command, **|
                                      commands << command
                                      :anytime
                                    }).start
      @client = Samagotchi::BridgeClient.new(session_id: "s1", port: read_file(File.join(session_dir, "bridge.json"))["port"])
    end

    after do
      @bridge.stop
      WebMock.disable_net_connect! if defined?(WebMock)
    end

    def of_type(type) = announced.select { |event| event[:type] == type }

    it "announces a participant's queued turn with its author, the owner's without" do
      @client.post_turn(prompt: "theirs", client_id: "web:t", author: "p:p_1")
      @client.post_turn(prompt: "mine", client_id: "web:o")

      theirs, mine = of_type(:turn_enqueued)
      expect(theirs).to include(prompt: "theirs", author: "p:p_1")
      expect(mine).not_to have_key(:author)
    end

    it "keeps the author on a /word sent as a message: the command and its command_queued name it" do
      expect(@client.post_turn(prompt: "/title x", client_id: "web:t", author: "p:p_1").status).to eq(202)
      @client.post_turn(prompt: "/title y", client_id: "web:o")

      expect(commands.map(&:author)).to eq(["p:p_1", nil])
      theirs, mine = of_type(:command_queued)
      expect(theirs).to include(line: "/title x", author: "p:p_1")
      expect(mine).not_to have_key(:author)
    end
  end

  describe Samagotchi::Bridge::TurnAccumulator do
    it "keeps the author on its queued turn and queued command rows" do
      accumulator = described_class.new
      accumulator.call({ type: :turn_enqueued, enqueued_id: "e1", client_id: "web:t", prompt: "x", author: "p:p_1" })
      accumulator.call({ type: :turn_enqueued, enqueued_id: "e2", client_id: "web:o", prompt: "y" })
      accumulator.call({ type: :command_queued, command_id: "c1", client_id: "web:t", line: "/model a", waits: "turn_end",
                         author: "p:p_1" })
      accumulator.call({ type: :command_queued, command_id: "c2", client_id: "web:o", line: "/model b", waits: "turn_end" })

      expect(accumulator.queued).to eq([{ enqueued_id: "e1", client_id: "web:t", prompt: "x", author: "p:p_1" },
                                        { enqueued_id: "e2", client_id: "web:o", prompt: "y" }])
      expect(accumulator.queued_commands).to eq([{ command_id: "c1", client_id: "web:t", line: "/model a", author: "p:p_1" },
                                                 { command_id: "c2", client_id: "web:o", line: "/model b" }])
    end
  end

  describe Samagotchi::SessionAccess::WebBridgeClient do
    let(:app) { RemoteBackend.app(state_dir: tmpdir) }
    let(:remote) { RemoteBackend.access(state_dir: tmpdir, app: app) }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap { |s| s.save(state_dir: tmpdir) }
    end
    let(:bridge) { instance_double(Samagotchi::BridgeClient) }

    it "takes an author but never sends it: the remote chi web stamps the author from its token" do
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      allow(app).to receive_messages(live_bridge_client: bridge, bridge_client: bridge)
      allow(bridge).to receive(:post_turn)
        .and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: JSON.generate(status: "accepted")))
      client = remote.attach_client(session.id, worker: { "epoch" => "e1", "started_at" => "t" })

      expect(client.post_turn(prompt: "go", client_id: "tui:1@mac", author: "p:p_forged").status).to eq(202)
      expect(bridge).to have_received(:post_turn).with(prompt: "go", client_id: "tui:1@mac")
    end
  end
end
