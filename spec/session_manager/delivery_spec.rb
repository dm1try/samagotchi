# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/worker_boot"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

  describe ".deliver_turn" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:locks) { [] }

    after do
      locks.each(&:release)
      described_class.forget_spawns
    end

    def input_files
      Dir.glob(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR, "*"))
    end

    def own(kind)
      locks << Samagotchi::OwnerLock.acquire(session_dir, kind: kind)
    end

    it "resumes and delivers to the new worker after a kill -9 left a sidecar naming another Bridge's port" do
      other = TCPServer.new("127.0.0.1", 0)
      Samagotchi::WorkerSidecar.new(port: other.local_address.ip_port, pid: Process.pid + 1).write(session_dir)
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      reached = []
      allow(Samagotchi::BridgeClient).to receive(:for_sidecar) { |_id, sidecar, **| (reached << sidecar.port) && bridge }
      allow(bridge).to receive(:post_turn).and_return(
        Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted","enqueued_id":"e1"}')
      )
      manager = Class.new do
        def self.resume_session(*) = nil
      end
      allow(manager).to receive(:resume_session) do
        own("worker")
        Samagotchi::WorkerSidecar.new(port: 5555, pid: Process.pid, protocol: Samagotchi::WorkerLink::PROTOCOL).write(session_dir)
      end

      result = described_class.deliver_turn(session.id, prompt: "hi", client_id: "cli:send", state_dir: tmpdir, manager: manager)

      expect(result).to have_attributes(status: :accepted, via: :bridge)
      expect(reached).to eq([5555])
      expect(input_files).to be_empty
    ensure
      other&.close
    end

    it "posts through a live Bridge and writes no file" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      allow(bridge).to receive(:post_turn).with(hash_including(prompt: "hi", client_id: "cli:send",
                                                               enqueued_id: kind_of(String))).and_return(
                                                                 Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted","enqueued_id":"e1","session_id":"s"}')
                                                               )

      result = described_class.deliver_turn(session.id, prompt: "hi", client_id: "cli:send", state_dir: tmpdir, bridge: -> { bridge })

      expect(result).to have_attributes(status: :accepted, via: :bridge,
                                        ack: { "status" => "accepted", "enqueued_id" => "e1", "session_id" => "s" })
      expect(input_files).to be_empty
    end

    it "carries a verified claim anchor through the Bridge and input-file fallback" do
      own("worker")
      verify = Samagotchi::VerifyAnchor.new(turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "the claim")
      anchors = Samagotchi::TurnAnchors.new(verify: verify)
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      allow(bridge).to receive(:post_turn).with(hash_including(prompt: "check", client_id: "web:1", anchors: anchors,
                                                               enqueued_id: kind_of(String))).and_return(
                                                                 Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}')
                                                               )

      expect(described_class.deliver_turn(session.id, prompt: "check", client_id: "web:1", anchors: anchors,
                                                       state_dir: tmpdir, bridge: -> { bridge }).status)
        .to eq(:accepted)

      allow(bridge).to receive(:post_turn).and_raise(Errno::ECONNREFUSED)
      described_class.deliver_turn(session.id, prompt: "check", client_id: "web:1", anchors: anchors,
                                            state_dir: tmpdir, bridge: -> { bridge })
      expect(JSON.parse(File.read(input_files.fetch(0)))["verify"])
        .to eq("turn_id" => verify.turn_id, "quote" => verify.quote)
    end

    it "carries a Revise turn's draft through the Bridge and input-file fallback" do
      own("worker")
      anchors = Samagotchi::TurnAnchors.new(revises: { turn_id: "123e4567-e89b-12d3-a456-426614174000" })
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      allow(bridge).to receive(:post_turn).with(hash_including(prompt: "shorter", client_id: "web:1", anchors: anchors,
                                                               enqueued_id: kind_of(String))).and_return(
                                                                 Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}')
                                                               )

      expect(described_class.deliver_turn(session.id, prompt: "shorter", client_id: "web:1", anchors: anchors,
                                                       state_dir: tmpdir, bridge: -> { bridge }).status)
        .to eq(:accepted)

      allow(bridge).to receive(:post_turn).and_raise(Errno::ECONNREFUSED)
      described_class.deliver_turn(session.id, prompt: "shorter", client_id: "web:1", anchors: anchors,
                                            state_dir: tmpdir, bridge: -> { bridge })
      expect(JSON.parse(File.read(input_files.fetch(0)))["revises"])
        .to eq("turn_id" => "123e4567-e89b-12d3-a456-426614174000")
    end

    it "posts the delivery the message carries, and only when it is not the default" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      allow(bridge).to receive(:post_turn)
        .with(hash_including(prompt: "later", client_id: "cli:send", delivery: "queue", enqueued_id: kind_of(String)))
        .and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}'))
      allow(bridge).to receive(:post_turn)
        .with(hash_including(prompt: "now", client_id: "cli:send", enqueued_id: kind_of(String)))
        .and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}'))

      expect(described_class.deliver_turn(session.id, prompt: "later", client_id: "cli:send", delivery: "queue",
                                                      state_dir: tmpdir, bridge: -> { bridge }).status)
        .to eq(:accepted)
      expect(described_class.deliver_turn(session.id, prompt: "now", client_id: "cli:send", state_dir: tmpdir,
                                                      bridge: -> { bridge }).status)
        .to eq(:accepted)
    end

    it "carries no_interrupt to the Bridge and into the fallback file, and only when it is set" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      allow(bridge).to receive(:post_turn)
        .with(hash_including(prompt: "long", client_id: "tui:1", no_interrupt: true, enqueued_id: kind_of(String)))
        .and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}'))

      expect(described_class.deliver_turn(session.id, prompt: "long", client_id: "tui:1", no_interrupt: true,
                                                      state_dir: tmpdir, bridge: -> { bridge }).status)
        .to eq(:accepted)

      allow(bridge).to receive(:post_turn).and_raise(Errno::ECONNREFUSED)
      described_class.deliver_turn(session.id, prompt: "long", client_id: "tui:1", no_interrupt: true,
                                               state_dir: tmpdir, bridge: -> { bridge })
      described_class.deliver_turn(session.id, prompt: "short", client_id: "tui:1", state_dir: tmpdir, bridge: -> { bridge })

      files = input_files.map { |path| JSON.parse(File.read(path)) }.sort_by { |input| input["prompt"] }
      expect(files.map { |input| [input["prompt"], input["no_interrupt"]] }).to eq([["long", true], ["short", nil]])
    end

    it "writes the delivery into the fallback file (queue only)" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      allow(bridge).to receive(:post_turn).and_raise(Errno::ECONNREFUSED)

      described_class.deliver_turn(session.id, prompt: "later", client_id: "cli:send", delivery: "queue",
                                               state_dir: tmpdir, bridge: -> { bridge })
      described_class.deliver_turn(session.id, prompt: "now", client_id: "cli:send", delivery: "cut",
                                               state_dir: tmpdir, bridge: -> { bridge })

      expect(input_files.sort.map { |path| JSON.parse(File.read(path))["delivery"] }).to eq(["queue", nil])
    end

    it "falls back to the input file when the Bridge refuses the connection" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      posted_id = nil
      allow(bridge).to receive(:post_turn) do |**args|
        posted_id = args.fetch(:enqueued_id)
        raise Errno::ECONNREFUSED
      end

      result = described_class.deliver_turn(session.id, prompt: "hi", client_id: "cli:send", state_dir: tmpdir, bridge: -> { bridge })

      expect(result).to have_attributes(status: :accepted, via: :file,
                                        ack: { "status" => "accepted", "enqueued_id" => kind_of(String), "session_id" => session.id })
      expect(posted_id).to eq(result.enqueued_id)
      expect(input_files.map { |path| JSON.parse(File.read(path)) })
        .to eq([{ "prompt" => "hi", "client_id" => "cli:send", "enqueued_id" => result.enqueued_id }])
    end

    it "queues the input file when nothing listens on the Bridge's port" do
      own("worker")
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      client = Samagotchi::BridgeClient.new(session_id: session.id, port: port, secret: nil, read_timeout: 0.3)

      result = described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { client })

      expect(result.status).to eq(:accepted)
      expect(input_files.size).to eq(1)
    end

    # The Bridge got to the request only after its deadline (a slow worker,
    # a clock step): the turn was dropped, so it is a timeout, and a file
    # would run it after all.
    it "reports a timeout and queues nothing when the Bridge dropped the turn as past its deadline" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      reply = Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}')
      allow(bridge).to receive(:post_turn).and_return(reply)

      result = described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { bridge })

      expect(result).to have_attributes(status: :timeout, ack: { "error" => "worker_timeout", "detail" => "the session's worker did not answer, so the message was not sent" })
      expect(input_files).to be_empty
    end

    # A P0-P2 worker answers a queue with 400 delivery_unavailable: a file
    # would merge at its next step, a silent steer. Any 4xx with an error
    # is a refusal; the 408 deadline_passed above stays a timeout.
    it "refuses on any 4xx the Bridge answers with an error, writing no file" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      reply = Samagotchi::BridgeClient::Response.new(status: 400, body: '{"error":"delivery_unavailable","detail":"old"}')
      allow(bridge).to receive(:post_turn).and_return(reply)

      result = described_class.deliver_turn(session.id, prompt: "later", delivery: "queue", state_dir: tmpdir,
                                                        bridge: -> { bridge })

      expect(result).to have_attributes(status: :refused, via: :bridge, code: 400, ack: { "error" => "delivery_unavailable", "detail" => "old" })
      expect(input_files).to be_empty
    end

    it "keeps the file fallback for a 5xx" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      allow(bridge).to receive(:post_turn).and_return(
        Samagotchi::BridgeClient::Response.new(status: 500, body: '{"error":"internal"}')
      )

      result = described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { bridge })

      expect(result.status).to eq(:accepted)
      expect(input_files.size).to eq(1)
    end

    # A prompt over the Bridge's body limit (chi send ID < big.log) still
    # goes in as a file, its delivery with it.
    it "keeps the file fallback for a 413 too_large, a queue's delivery kept in the file" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      allow(bridge).to receive(:post_turn).and_return(
        Samagotchi::BridgeClient::Response.new(status: 413, body: '{"error":"too_large","detail":"over"}')
      )

      plain = described_class.deliver_turn(session.id, prompt: "big", state_dir: tmpdir, bridge: -> { bridge })
      queued = described_class.deliver_turn(session.id, prompt: "big later", delivery: "queue", state_dir: tmpdir,
                                                        bridge: -> { bridge })

      expect([plain.status, queued.status]).to eq(%i[accepted accepted])
      expect(input_files.sort.map { |path| JSON.parse(File.read(path)).values_at("prompt", "delivery") })
        .to eq([["big", nil], ["big later", "queue"]])
    end

    describe "a queue to a live worker, by its sidecar's features" do
      # A client made from a sidecar naming +features+ (WorkerLink::Live#client).
      def client_naming(features) = instance_double(Samagotchi::BridgeClient, features: features)

      it "refuses it without posting when the worker doesn't name the delivery feature (it would steer)" do
        own("worker")
        bridge = client_naming(%w[restart task_stop reparent])
        expect(bridge).not_to receive(:post_turn)

        result = described_class.deliver_turn(session.id, prompt: "later", delivery: "queue", state_dir: tmpdir,
                                                          bridge: -> { bridge })

        expect(result).to have_attributes(status: :refused, code: 409,
                                          ack: { "error" => "delivery_unavailable", "detail" => a_string_including("restart it") })
        expect(input_files).to be_empty
      end

      it "refuses a participant's turn to a worker without the review boundary (review_turns), and posts it to one with" do
        own("worker")
        bridge = client_naming(%w[delivery])
        expect(bridge).not_to receive(:post_turn)
        result = described_class.deliver_turn(session.id, prompt: "q", delivery: "queue", author: "p:p_1", state_dir: tmpdir,
                                                          bridge: -> { bridge })
        expect(result).to have_attributes(status: :refused, code: 409, ack: Samagotchi::Delivery::REVIEW_UNAVAILABLE)
        expect(input_files).to be_empty

        posting = client_naming(%w[delivery review_turns])
        allow(posting).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}'))
        expect(described_class.deliver_turn(session.id, prompt: "q", delivery: "queue", author: "p:p_1", state_dir: tmpdir,
                                                        bridge: -> { posting }).status).to eq(:accepted)
        expect(posting).to have_received(:post_turn).with(hash_including(author: "p:p_1", delivery: "queue"))
      end

      it "refuses a Verify turn to a worker without the verify feature" do
        own("worker")
        bridge = client_naming(%w[delivery review_turns])
        expect(bridge).not_to receive(:post_turn)
        verify = Samagotchi::VerifyAnchor.new(turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "the claim")

        result = described_class.deliver_turn(session.id, prompt: "check", anchors: { verify: verify }, state_dir: tmpdir,
                                                          bridge: -> { bridge })

        expect(result).to have_attributes(status: :refused, code: 409, ack: Samagotchi::VerifyAnchor::UNAVAILABLE)
        expect(input_files).to be_empty
      end

      it "refuses a Revise turn to a worker without the revise feature" do
        own("worker")
        bridge = client_naming(%w[delivery review_turns verify])
        expect(bridge).not_to receive(:post_turn)

        result = described_class.deliver_turn(session.id, prompt: "shorter", state_dir: tmpdir, bridge: -> { bridge },
                                                          anchors: { revises: { turn_id: "123e4567-e89b-12d3-a456-426614174000" } })

        expect(result).to have_attributes(status: :refused, code: 409, ack: Samagotchi::ReviseAnchor::UNAVAILABLE)
        expect(input_files).to be_empty
      end

      it "counts a participant's waiting files against their pending limit when no worker runs" do
        allow(described_class).to receive(:resume_session)
        2.times do
          expect(described_class.deliver_turn(session.id, prompt: "q", delivery: "queue", author: "p:p_1", pending_limit: 2,
                                                          state_dir: tmpdir, bridge: -> {}).status).to eq(:accepted)
        end
        result = described_class.deliver_turn(session.id, prompt: "q", delivery: "queue", author: "p:p_1", pending_limit: 2,
                                                          state_dir: tmpdir, bridge: -> {})
        expect(result).to have_attributes(status: :refused, code: 429)
        expect(result.ack["error"]).to eq("too_many_turns")
        expect(input_files.size).to eq(2)
      end

      # L-P4: two of a participant's turns at once (two chi web threads)
      # can't both count the same waiting files and pass the limit.
      it "counts and writes a participant's file under one lock, so two at once can't pass their pending limit" do
        allow(described_class).to receive(:resume_session)
        writing = Queue.new
        release = Queue.new
        calls = 0
        allow(described_class).to receive(:write_turn_input).and_wrap_original do |original, *args, **options|
          first = (calls += 1) == 1
          if first
            writing << true
            pop!(release, "the first turn's release", timeout: 30)
          end
          original.call(*args, **options)
        end
        deliver = lambda do
          described_class.deliver_turn(session.id, prompt: "q", delivery: "queue", author: "p:p_1", pending_limit: 1,
                                                   state_dir: tmpdir, bridge: -> {})
        end
        first = Thread.new { deliver.call }
        pop!(writing, "the first turn's write")
        second = Thread.new { deliver.call }
        # wait-ok: unlocked, the second turn writes now; locked, it waits for the first (at most 0.5 s, fine to cut short)
        wait_until(timeout: 0.5) { calls > 1 }
        release << true

        statuses = [join!(first, "the first turn").value, join!(second, "the second turn").value].map(&:status)
        expect(statuses).to eq(%i[accepted refused])
        expect(input_files.size).to eq(1)
      end

      it "writes no participant's file while a worker holds the session with its Bridge gone (it may be an older one)" do
        own("worker")
        result = described_class.deliver_turn(session.id, prompt: "q", delivery: "queue", author: "p:p_1", state_dir: tmpdir,
                                                          bridge: -> {})
        expect(result).to have_attributes(status: :timeout)
        expect(result.ack["detail"]).to include("exiting")
        expect(input_files).to be_empty
      end

      it "posts it when the worker names the feature; a next_step or cut posts either way" do
        own("worker")
        accepted = Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}')
        bridge = client_naming(%w[restart])
        allow(bridge).to receive(:post_turn).and_return(accepted)
        expect(described_class.deliver_turn(session.id, prompt: "now", delivery: "cut", state_dir: tmpdir,
                                                        bridge: -> { bridge }).status).to eq(:accepted)

        queuing = client_naming(%w[restart delivery])
        allow(queuing).to receive(:post_turn).and_return(accepted)
        expect(described_class.deliver_turn(session.id, prompt: "later", delivery: "queue", state_dir: tmpdir,
                                                        bridge: -> { queuing }).status).to eq(:accepted)
        expect(bridge).to have_received(:post_turn).once
        expect(queuing).to have_received(:post_turn).once
      end
    end

    it "reports a timeout and queues nothing when the Bridge takes the request but never answers" do
      own("worker")
      server = TCPServer.new("127.0.0.1", 0)
      accepted = []
      acceptor = Thread.new { loop { accepted << server.accept } }
      client = Samagotchi::BridgeClient.new(session_id: session.id, port: server.addr[1], secret: nil, read_timeout: 0.3)

      result = described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { client })

      expect(result).to have_attributes(status: :timeout, ack: { "error" => "worker_timeout", "detail" => "the session's worker did not answer, so the message was not sent" })
      expect(input_files).to be_empty
    ensure
      acceptor&.kill
      accepted&.each(&:close)
      server&.close
    end

    it "withdraws the file and raises OwnedByTUI when a TUI took the session after the write" do
      allow(Process).to receive(:spawn).and_return(20_002)
      bridge = lambda do
        own("tui")
        nil
      end

      expect do
        described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: bridge)
      end.to raise_error(described_class::OwnedByTUI)
      expect(input_files).to be_empty
    end

    it "wakes a worker for a session nobody owns" do
      allow(Process).to receive(:spawn).and_return(20_002)
      # The first worker is gone by the write (it idle-exited): its waiter is
      # dead. A real Process.detach of the made-up pid dies on ECHILD only
      # once its thread gets to run, which may be after the second resume.
      allow(Process).to receive(:detach).and_return(instance_double(Thread, alive?: false))

      result = described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> {})

      expect(result.status).to eq(:accepted)
      # Once by the resume, once more since still nobody owns it after the write.
      expect(Process).to have_received(:spawn).twice
      expect(input_files.size).to eq(1)
    end

    it "refuses a chi scratch session, live worker or not, in its one wording, and queues nothing" do
      session.scratch = true
      session.save(state_dir: tmpdir)
      own("worker")
      allow(Process).to receive(:spawn)

      expect do
        described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { raise "not reached" })
      end.to raise_error(described_class::ScratchSession, Samagotchi::Session::SCRATCH_REFUSED)
      expect { described_class.resume_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::OwnedByTUI, Samagotchi::Session::SCRATCH_REFUSED)
      expect(input_files).to be_empty
      expect(Process).not_to have_received(:spawn)
    end

    it "raises OwnedByTUI up front for a one-shot's session and queues nothing" do
      own("tui")

      expect do
        described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { raise "not reached" })
      end.to raise_error(described_class::OwnedByTUI)
      expect(input_files).to be_empty
    end
  end

  describe "structured input" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:input_dir) { File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR) }

    def write_sidecar(record)
      FileUtils.mkdir_p(session_dir)
      File.write(File.join(session_dir, "bridge.json"), JSON.generate(record))
    end

    it "writes a JSON input file carrying the sender's ids" do
      path = described_class.write_turn_input(session.id, prompt: "hi", client_id: "web:1", enqueued_id: "e1", state_dir: tmpdir)

      expect(path).to end_with(".json")
      expect(JSON.parse(File.read(path))).to eq("prompt" => "hi", "client_id" => "web:1", "enqueued_id" => "e1")
    end

    it "writes JSON whatever input format the sidecar advertises (no worker from before format 2 or 3 is left)" do
      [{}, { "input_format" => 2 }].each do |advertised|
        write_sidecar({ "port" => 1, "session_id" => session.id }.merge(advertised))

        path = described_class.write_turn_input(session.id, prompt: "hi", client_id: "web:1", state_dir: tmpdir)

        expect(JSON.parse(File.read(path))).to eq("prompt" => "hi", "client_id" => "web:1")
      end
    end

    def run_worker_with(engine)
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0, messages_checkpoint: [])
      allow(engine).to receive(:claim_enqueued_id).and_return(true)
      allow(engine).to receive(:finish_enqueued_id)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end.to raise_error(SystemExit)
    end

    it "runs queued turns with their origin, or none" do
      described_class.write_turn_input(session.id, prompt: "from web", client_id: "web:1", enqueued_id: "e1", state_dir: tmpdir)
      described_class.write_turn_input(session.id, prompt: "plain", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, origin:, **|
        runs << [prompt, origin.wire]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if runs.size == 2
        instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false)
      end

      run_worker_with(engine)

      expect(runs).to eq([["from web", { client_id: "web:1", enqueued_id: "e1" }], ["plain", nil]])
    end

    it "runs a turn queued with no_interrupt under the raised iteration limit" do
      described_class.write_turn_input(session.id, prompt: "long", client_id: "tui:1", no_interrupt: true, state_dir: tmpdir)
      described_class.write_turn_input(session.id, prompt: "short", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, max_iterations:, **|
        runs << [prompt, max_iterations]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if runs.size == 2
        instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false)
      end

      run_worker_with(engine)

      expect(runs).to eq([["long", 1000], ["short", Samagotchi::IterationLimit::DEFAULT]])
    end

    it "marks the session running on disk while a turn runs, and stops before the next queued turn" do
      described_class.write_turn_input(session.id, prompt: "one", state_dir: tmpdir)
      described_class.write_turn_input(session.id, prompt: "two", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, **|
        runs << [prompt, Samagotchi::Session.load(session.id, state_dir: tmpdir).status]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false)
      end

      run_worker_with(engine)

      expect(runs).to eq([%w[one running]])
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq("stopped")
      # Still queued for whoever resumes the session.
      expect(Dir.children(input_dir).map { |f| JSON.parse(File.read(File.join(input_dir, f)))["prompt"] }).to eq(["two"])
    end

    it "announces who sent input merged into a running turn" do
      engine = instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommands.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil, live_conversation: nil)
      announced = []
      allow(engine).to receive(:announce) { |event| announced << event }
      drained = nil
      described_class.write_turn_input(session.id, prompt: "first", state_dir: tmpdir)
      allow(engine).to receive(:run_turn) do |_session, _prompt, pending_input:, **|
        described_class.write_turn_input(session.id, prompt: "steer", client_id: "tui:1", enqueued_id: "e2", state_dir: tmpdir)
        drained = pending_input.call
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false)
      end

      run_worker_with(engine)

      expect(drained).to eq([Samagotchi::Steer::Line.new(text: "steer", source: nil)])
      expect(announced).to eq([{ type: :input_merged, count: 1, origins: [{ client_id: "tui:1", enqueued_id: "e2" }] }])
    end
  end
end
