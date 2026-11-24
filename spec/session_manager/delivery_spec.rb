# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/worker_boot"
require "samagotchi/bridge"
require "support/bridge_parts"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"
  include BridgeParts

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

    it "posts and writes the caller's enqueued_id when given" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      posted = []
      allow(bridge).to receive(:post_turn) do |**args|
        posted << args.fetch(:enqueued_id)
        raise Errno::ECONNREFUSED
      end
      id = "0b6c1e9a-1111-5222-8333-444455556666"

      result = described_class.deliver_turn(session.id, prompt: "hi", client_id: "cli:send", state_dir: tmpdir,
                                                        bridge: -> { bridge }, enqueued_id: id)

      expect(posted).to eq([id])
      expect(result.enqueued_id).to eq(id)
      expect(input_files.map { |path| JSON.parse(File.read(path))["enqueued_id"] }).to eq([id])
    end

    it "queues the input file when nothing listens on the Bridge's port" do
      own("worker")
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      client = Samagotchi::BridgeClient.new(session_id: session.id, port: port, secret: nil, read_timeout: 0.3)

      result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> { client })

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

      result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> { bridge })

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

      result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "later", delivery: "queue", state_dir: tmpdir,
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

      result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> { bridge })

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

      plain = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "big", state_dir: tmpdir, bridge: -> { bridge })
      queued = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "big later", delivery: "queue", state_dir: tmpdir,
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

        result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "later", delivery: "queue", state_dir: tmpdir,
                                                          bridge: -> { bridge })

        expect(result).to have_attributes(status: :refused, code: 409,
                                          ack: { "error" => "delivery_unavailable", "detail" => a_string_including("restart it") })
        expect(input_files).to be_empty
      end

      it "refuses a participant's turn to a worker that would run it read-only or unbounded (no pair_turns), and posts it to one with" do
        own("worker")
        [%w[delivery], %w[delivery review_turns]].each do |features|
          bridge = client_naming(features)
          expect(bridge).not_to receive(:post_turn)
          result = described_class.deliver_turn(session.id, client_id: "participant:p_1", prompt: "q", delivery: "queue", author: "p:p_1", state_dir: tmpdir,
                                                            bridge: -> { bridge })
          expect(result).to have_attributes(status: :refused, code: 409, ack: Samagotchi::Delivery::PAIR_UNAVAILABLE)
        end
        expect(input_files).to be_empty

        posting = client_naming(%w[delivery review_turns pair_turns])
        allow(posting).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}'))
        expect(described_class.deliver_turn(session.id, client_id: "participant:p_1", prompt: "q", delivery: "queue", author: "p:p_1", state_dir: tmpdir,
                                                        bridge: -> { posting }).status).to eq(:accepted)
        expect(posting).to have_received(:post_turn).with(hash_including(author: "p:p_1", delivery: "queue"))
      end

      # compat shim review_client_id: a worker from before participant:<id>
      # reads a participant's turn only by review:<id>.
      it "sends a participant's turn as review:<id> to a worker without participant_client_id, participant:<id> to one with" do
        own("worker")
        sent = {}
        [%w[delivery review_turns pair_turns], %w[delivery review_turns pair_turns participant_client_id]].each do |features|
          bridge = client_naming(features)
          allow(bridge).to receive(:post_turn) { |**options| (sent[features.size] = options[:client_id]) && Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}') }
          expect(described_class.deliver_turn(session.id, client_id: "participant:p_1", prompt: "q", author: "p:p_1", state_dir: tmpdir,
                                                          bridge: -> { bridge }).status).to eq(:accepted)
        end
        expect(sent).to eq(3 => "review:p_1", 4 => "participant:p_1")
        expect(Samagotchi::Bridge::FEATURES).to include(Samagotchi::Delivery::PARTICIPANT_ID_FEATURE)
      end

      # compat shim agent_client_id: a worker from before agent: senders
      # reads an agent's line as chi send's.
      it "sends an agent's turn as cli:send to a worker without agent_sender, agent:<name> to one with" do
        own("worker")
        sent = {}
        [%w[delivery], %w[delivery agent_sender]].each do |features|
          bridge = client_naming(features)
          allow(bridge).to receive(:post_turn) { |**options| (sent[features.size] = options[:client_id]) && Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}') }
          expect(described_class.deliver_turn(session.id, client_id: "agent:claude", prompt: "q", state_dir: tmpdir,
                                                          bridge: -> { bridge }).status).to eq(:accepted)
        end
        expect(sent).to eq(1 => "cli:send", 2 => "agent:claude")
        expect(Samagotchi::Bridge::FEATURES).to include(Samagotchi::Delivery::AGENT_FEATURE)
      end

      it "refuses another session's question to a worker without ask_session, posts it to one with" do
        own("worker")
        old = client_naming(%w[delivery])
        expect(old).not_to receive(:post_turn)
        expect(described_class.deliver_turn(session.id, client_id: "session:ab12cd34", prompt: "q", delivery: "queue",
                                                        state_dir: tmpdir, bridge: -> { old }))
          .to have_attributes(status: :refused, code: 409, ack: Samagotchi::Delivery::ASK_UNAVAILABLE)
        posting = client_naming(%w[delivery ask_session])
        allow(posting).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}'))
        expect(described_class.deliver_turn(session.id, client_id: "session:ab12cd34", prompt: "q", delivery: "queue",
                                                        state_dir: tmpdir, bridge: -> { posting }).status).to eq(:accepted)
        expect(Samagotchi::Bridge::FEATURES).to include(Samagotchi::Delivery::ASK_FEATURE)
        # No readable Bridge while a worker holds it: an older one may read the file, so not sent.
        expect(described_class.deliver_turn(session.id, client_id: "session:ab12cd34", prompt: "q", state_dir: tmpdir,
                                                        bridge: -> {}).status).to eq(:timeout)
        expect(input_files).to be_empty
      end

      # A current worker's Bridge that can't take the body (a big piped chi
      # send: 413), a 5xx or a socket error: the file keeps the agent's id,
      # never the owner's (which would run a ! line and reset the budget).
      it "keeps an agent's id in the file when a current worker's Bridge answers 413, a 5xx or a socket error" do
        own("worker")
        [413, 500, :socket].each do |answer|
          bridge = client_naming(Samagotchi::Bridge::FEATURES)
          if answer == :socket
            allow(bridge).to receive(:post_turn).and_raise(Errno::ECONNRESET)
          else
            allow(bridge).to receive(:post_turn)
              .and_return(Samagotchi::BridgeClient::Response.new(status: answer, body: '{"error":"too_large"}'))
          end
          expect(described_class.deliver_turn(session.id, client_id: "agent:claude", prompt: "!ls", state_dir: tmpdir,
                                                          bridge: -> { bridge }).status).to eq(:accepted), answer.to_s
        end
        expect(input_files.map { |path| JSON.parse(File.read(path))["client_id"] }).to eq(%w[agent:claude] * 3)
      end

      it "writes an agent's file as cli:send to an older worker's: its Bridge's features, else its sidecar's" do
        own("worker")
        old = client_naming(%w[delivery])
        allow(old).to receive(:post_turn)
          .and_return(Samagotchi::BridgeClient::Response.new(status: 413, body: '{"error":"too_large"}'))
        described_class.deliver_turn(session.id, client_id: "agent:claude", prompt: "a", state_dir: tmpdir, bridge: -> { old })
        Samagotchi::WorkerSidecar.new(port: 1, pid: Process.pid, features: %w[delivery]).write(session_dir)
        described_class.deliver_turn(session.id, client_id: "agent:claude", prompt: "b", state_dir: tmpdir, bridge: -> {})
        Samagotchi::WorkerSidecar.new(port: 1, pid: Process.pid, features: Samagotchi::Bridge::FEATURES).write(session_dir)
        described_class.deliver_turn(session.id, client_id: "agent:claude", prompt: "c", state_dir: tmpdir, bridge: -> {})
        clients = input_files.to_h { |path| JSON.parse(File.read(path)).values_at("prompt", "client_id") }
        expect(clients).to eq("a" => "cli:send", "b" => "cli:send", "c" => "agent:claude")
      end

      it "refuses an agent's file while a worker with no Bridge and no sidecar holds the session (exiting: unknown)" do
        own("worker")
        expect(described_class.deliver_turn(session.id, client_id: "agent:claude", prompt: "q", state_dir: tmpdir, bridge: -> {}))
          .to have_attributes(status: :timeout, ack: include("error" => "worker_timeout"))
        expect(input_files).to be_empty
      end

      it "refuses a participant's Revise to a worker without participant_revise in their words; the owner's goes" do
        own("worker")
        revises = { revises: { turn_id: "123e4567-e89b-12d3-a456-426614174001" } }
        bridge = client_naming(%w[delivery review_turns pair_turns revise])
        expect(bridge).not_to receive(:post_turn)
        result = described_class.deliver_turn(session.id, client_id: "participant:p_1", prompt: "q", delivery: "queue", author: "p:p_1",
                                                          anchors: revises, state_dir: tmpdir, bridge: -> { bridge })
        expect(result).to have_attributes(status: :refused, code: 409, ack: Samagotchi::ReviseAnchor::PARTICIPANT_UNAVAILABLE)
        expect(result.ack["detail"]).to eq(Samagotchi::ParticipantMessages::REVISE_UNAVAILABLE)
        expect(input_files).to be_empty

        posting = client_naming(%w[delivery review_turns revise])
        allow(posting).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}'))
        expect(described_class.deliver_turn(session.id, client_id: "web:o", prompt: "q", delivery: "queue", anchors: revises,
                                            state_dir: tmpdir, bridge: -> { posting }).status).to eq(:accepted)
      end

      it "refuses a Verify turn to a worker without the verify feature" do
        own("worker")
        bridge = client_naming(%w[delivery review_turns])
        expect(bridge).not_to receive(:post_turn)
        verify = Samagotchi::VerifyAnchor.new(turn_id: "123e4567-e89b-12d3-a456-426614174000", quote: "the claim")

        result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "check", anchors: { verify: verify }, state_dir: tmpdir,
                                                          bridge: -> { bridge })

        expect(result).to have_attributes(status: :refused, code: 409, ack: Samagotchi::VerifyAnchor::UNAVAILABLE)
        expect(input_files).to be_empty
      end

      describe "an ask's reply_for (a vouched anchor)" do
        let(:voice) { { reply_for: { "formatting" => "plain", "room" => "short", "choices" => 3, "detail" => false } } }

        it "is refused by a live worker without the feature (409 reply_for_unavailable), nothing posted or written" do
          own("worker")
          bridge = client_naming(Samagotchi::Bridge::FEATURES - [Samagotchi::ReplyFor::FEATURE])
          expect(bridge).not_to receive(:post_turn)

          result = described_class.deliver_turn(session.id, client_id: "web:unnamed", prompt: "hi", anchors: voice, state_dir: tmpdir,
                                                            bridge: -> { bridge })

          expect(result).to have_attributes(status: :refused, code: 409, ack: Samagotchi::ReplyFor::UNAVAILABLE)
          expect(result.ack["detail"]).to include("update chi if needed").and include("restart")
          expect(input_files).to be_empty
        end

        it "posts it to a worker with the feature, which queues it as its own turn" do
          own("worker")
          bridge = client_naming(Samagotchi::Bridge::FEATURES)
          allow(bridge).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted"}'))

          expect(described_class.deliver_turn(session.id, client_id: "web:unnamed", prompt: "hi", anchors: voice, state_dir: tmpdir,
                                                          bridge: -> { bridge }).status).to eq(:accepted)
          expect(bridge).to have_received(:post_turn).with(hash_including(anchors: Samagotchi::TurnAnchors.from(voice)))
        end

        it "writes no file with no Bridge unless the sidecar vouches: none is a retry, one without it the 409" do
          allow(described_class).to receive(:resume_session)
          own("worker")
          expect(described_class.deliver_turn(session.id, client_id: "web:unnamed", prompt: "a", anchors: voice, state_dir: tmpdir,
                                                          bridge: -> {}))
            .to have_attributes(status: :timeout, ack: include("error" => "worker_timeout"))
          Samagotchi::WorkerSidecar.new(port: 1, pid: Process.pid, features: Samagotchi::Bridge::FEATURES - %w[reply_for]).write(session_dir)
          expect(described_class.deliver_turn(session.id, client_id: "web:unnamed", prompt: "b", anchors: voice, state_dir: tmpdir,
                                                          bridge: -> {}))
            .to have_attributes(status: :refused, code: 409, ack: Samagotchi::ReplyFor::UNAVAILABLE)
          expect(input_files).to be_empty

          Samagotchi::WorkerSidecar.new(port: 1, pid: Process.pid, features: Samagotchi::Bridge::FEATURES).write(session_dir)
          expect(described_class.deliver_turn(session.id, client_id: "web:unnamed", prompt: "c", anchors: voice, state_dir: tmpdir,
                                                          bridge: -> {}).status).to eq(:accepted)
          expect(input_files.map { |path| JSON.parse(File.read(path)).values_at("prompt", "reply_for") })
            .to eq([["c", voice[:reply_for]]])
        end

        it "never takes a leftover sidecar no worker holds (a dead worker's) as vouching: a retry, no file" do
          allow(described_class).to receive(:resume_session)
          Samagotchi::WorkerSidecar.new(port: 1, pid: Process.pid, features: Samagotchi::Bridge::FEATURES).write(session_dir)

          expect(described_class.deliver_turn(session.id, client_id: "web:unnamed", prompt: "a", anchors: voice, state_dir: tmpdir,
                                                          bridge: -> {}))
            .to have_attributes(status: :timeout, ack: include("error" => "worker_timeout"))
          Samagotchi::WorkerSidecar.new(port: 1, pid: Process.pid, features: Samagotchi::Bridge::FEATURES - %w[reply_for]).write(session_dir)
          expect(described_class.deliver_turn(session.id, client_id: "web:unnamed", prompt: "b", anchors: voice, state_dir: tmpdir,
                                                          bridge: -> {}))
            .to have_attributes(status: :timeout, ack: include("error" => "worker_timeout"))
          expect(input_files).to be_empty
        end

        it "leaves a message without one as it was: the file goes with no sidecar" do
          allow(described_class).to receive(:resume_session)
          expect(described_class.deliver_turn(session.id, client_id: "web:unnamed", prompt: "plain", state_dir: tmpdir,
                                                          bridge: -> {}).status).to eq(:accepted)
          expect(input_files.size).to eq(1)
        end
      end

      it "refuses a Revise turn to a worker without the revise feature" do
        own("worker")
        bridge = client_naming(%w[delivery review_turns verify])
        expect(bridge).not_to receive(:post_turn)

        result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "shorter", state_dir: tmpdir, bridge: -> { bridge },
                                                          anchors: { revises: { turn_id: "123e4567-e89b-12d3-a456-426614174000" } })

        expect(result).to have_attributes(status: :refused, code: 409, ack: Samagotchi::ReviseAnchor::UNAVAILABLE)
        expect(input_files).to be_empty
      end

      it "counts a participant's waiting files against their pending limit when no worker runs" do
        allow(described_class).to receive(:resume_session)
        2.times do
          expect(described_class.deliver_turn(session.id, client_id: "participant:p_1", prompt: "q", delivery: "queue", author: "p:p_1", pending_limit: 2,
                                                          state_dir: tmpdir, bridge: -> {}).status).to eq(:accepted)
        end
        result = described_class.deliver_turn(session.id, client_id: "participant:p_1", prompt: "q", delivery: "queue", author: "p:p_1", pending_limit: 2,
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
          described_class.deliver_turn(session.id, client_id: "participant:p_1", prompt: "q", delivery: "queue", author: "p:p_1", pending_limit: 1,
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
        result = described_class.deliver_turn(session.id, client_id: "participant:p_1", prompt: "q", delivery: "queue", author: "p:p_1", state_dir: tmpdir,
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
        expect(described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "now", delivery: "cut", state_dir: tmpdir,
                                                        bridge: -> { bridge }).status).to eq(:accepted)

        queuing = client_naming(%w[restart delivery])
        allow(queuing).to receive(:post_turn).and_return(accepted)
        expect(described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "later", delivery: "queue", state_dir: tmpdir,
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

      result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> { client })

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
        described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: bridge)
      end.to raise_error(described_class::OwnedByTUI)
      expect(input_files).to be_empty
    end

    # A deleter holds the owner lock (kind deleting) while the session's
    # files go: a send is refused (DeliverResult::DELETING), also when the
    # lock came after its check (the bridge seam runs between the check and
    # the write), and never reported accepted for a file the delete removes.
    describe "a session being deleted" do
      let(:deleting) { described_class::DeliverResult::DELETING }

      before { allow(described_class).to receive(:resume_session) }

      def send_it(bridge) = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi",
                                                                      state_dir: tmpdir, bridge: bridge)

      it "refuses a send before writing anything, in its one wording" do
        own(Samagotchi::OwnerLock::DELETING)

        result = send_it(-> { raise "a deleting session has no Bridge to ask" })

        expect(result).to have_attributes(status: :refused, code: 409, ack: deleting)
        expect(result.refusal_text).to eq("refused: #{deleting["detail"]}")
        expect(input_files).to be_empty
        expect(described_class).not_to have_received(:resume_session)
      end

      it "takes its file back and refuses when the deleting lock came after its check" do
        result = send_it(lambda do
          own(Samagotchi::OwnerLock::DELETING)
          nil
        end)

        expect(result).to have_attributes(status: :refused, code: 409, ack: deleting)
        expect(input_files).to be_empty
      end

      it "refuses, leaving no folder behind, when the session went between its check and its write" do
        result = send_it(lambda do
          FileUtils.rm_f(Samagotchi::Session.session_file(session.id, state_dir: tmpdir))
          FileUtils.rm_rf(session_dir)
          nil
        end)

        expect(result).to have_attributes(status: :refused, ack: deleting)
        expect(Dir.exist?(session_dir)).to be(false)
      end

      it "stays accepted when a worker claimed the file before the send could take it back" do
        allow(described_class).to receive(:write_turn_input).and_wrap_original do |original, *args, **options|
          original.call(*args, **options).tap { |path| File.rename(path, "#{path}.processing") }
        end

        result = send_it(lambda do
          own(Samagotchi::OwnerLock::DELETING)
          nil
        end)

        expect(result).to have_attributes(status: :accepted, via: :file)
      end
    end

    it "wakes a worker for a session nobody owns" do
      allow(Process).to receive(:spawn).and_return(20_002)
      # The first worker is gone by the write (it idle-exited): its waiter is
      # dead. A real Process.detach of the made-up pid dies on ECHILD only
      # once its thread gets to run, which may be after the second resume.
      allow(Process).to receive(:detach).and_return(instance_double(Thread, alive?: false))

      result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> {})

      expect(result.status).to eq(:accepted)
      # Once by the resume, once more since still nobody owns it after the write.
      expect(Process).to have_received(:spawn).twice
      expect(input_files.size).to eq(1)
    end

    # P5: a send pins the id it names (docs/sessions.md, Which link): an
    # archived link that was continued gets the message, and its own worker.
    it "pins a send to the link it names, an archived one that was continued too" do
      Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir)
      head = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp",
                                             continues: session.id)
      head.save(state_dir: tmpdir)
      allow(described_class).to receive(:resume_session)

      result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> {})

      expect(result).to have_attributes(status: :accepted, via: :file)
      expect(result.ack["session_id"]).to eq(session.id)
      expect(input_files.size).to eq(1)
      expect(Samagotchi::SessionInbox.find_new_input_files(Samagotchi::Session.session_dir(head.id, state_dir: tmpdir)))
        .to be_empty
      expect(described_class).to have_received(:resume_session).with(session.id, state_dir: tmpdir).twice
      expect(described_class).not_to have_received(:resume_session).with(head.id, anything)
    end

    # The two liveness checks read WakePolicy's send row: a session a worker
    # holds, or one being started, gets no second start.
    it "starts no worker when one holds the session, or one is being started" do
      allow(described_class).to receive(:resume_session)
      own("worker")
      described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "a", state_dir: tmpdir, bridge: -> {})
      locks.pop.release
      Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)
      described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "b", state_dir: tmpdir, bridge: -> {})

      expect(described_class).not_to have_received(:resume_session)
      expect(input_files.size).to eq(2)
    end

    # A send un-stops, also when the stop landed while a worker is leaving
    # (its Bridge closed, the lock held for its recap): the input is left to
    # the leaving worker's respawn (WorkerBoot's leave row), which a stop
    # would drop, so the send clears the stop as resume_session would.
    it "clears a stop that landed while a worker is leaving, so the leave's respawn serves the input" do
      allow(described_class).to receive(:resume_session)
      own("worker")
      locks.last.mark_leaving(wait: 5)
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      result = described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> {})

      expect(result).to have_attributes(status: :accepted, via: :file)
      expect(input_files.size).to eq(1)
      expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)).to be(false)
      expect(described_class).not_to have_received(:resume_session)
    end

    it "leaves a stop alone while a worker that isn't leaving holds the session" do
      own("worker")
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> {})

      expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)).to be(true)
    end

    # Pick 1 (R3): the sender's kind picks the wake row. A person (chi send,
    # a web tab, a terminal) un-stops and un-archives; a schedule, a plugin,
    # a delegate follow-up, a participant and an unknown sender don't.
    describe "who may wake a stopped or archived session" do
      unattended = {
        "a schedule firing" => "system:schedule:s1", "a plugin send" => "plugin",
        "a delegate follow-up" => "delegate:abcdef12", "a participant turn" => "participant:p_1",
        "an unknown sender" => "bot:x"
      }

      unattended.each do |who, client_id|
        it "keeps a stopped session stopped for #{who}" do
          allow(described_class).to receive(:resume_session)
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

          result = described_class.deliver_turn(session.id, prompt: "hi", client_id: client_id, state_dir: tmpdir,
                                                            bridge: -> {})

          expect(result).to have_attributes(status: :refused, code: 409)
          expect(result.ack).to eq(described_class::DeliverResult::STOPPED)
          expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)).to be(true)
          expect(described_class).not_to have_received(:resume_session)
          expect(input_files).to be_empty
        end

        it "keeps an archived link archived for #{who}" do
          allow(described_class).to receive(:resume_session)
          Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir)

          result = described_class.deliver_turn(session.id, prompt: "hi", client_id: client_id, state_dir: tmpdir,
                                                            bridge: -> {})

          expect(result).to have_attributes(status: :refused, code: 409)
          expect(result.ack).to eq(described_class::DeliverResult::ARCHIVED)
          expect(described_class).not_to have_received(:resume_session)
          expect(input_files).to be_empty
        end
      end

      %w[cli:send web:tab1 tui:42].each do |client_id|
        it "un-stops and un-archives for #{client_id}" do
          allow(described_class).to receive(:resume_session)
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
          Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir)

          result = described_class.deliver_turn(session.id, prompt: "hi", client_id: client_id, state_dir: tmpdir,
                                                            bridge: -> {})

          expect(result).to have_attributes(status: :accepted, via: :file)
          expect(described_class).to have_received(:resume_session).with(session.id, state_dir: tmpdir).twice
        end
      end

      it "leaves a stop that landed while a worker is leaving to win for an unattended sender" do
        allow(described_class).to receive(:resume_session)
        own("worker")
        locks.last.mark_leaving(wait: 5)
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

        result = described_class.deliver_turn(session.id, prompt: "hi", client_id: "plugin", state_dir: tmpdir,
                                                          bridge: -> {})

        expect(result).to have_attributes(status: :accepted, via: :file)
        expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)).to be(true)
      end

      it "reads a refusal as refused, in its one wording" do
        result = described_class::DeliverResult.new(status: :refused, code: 409, ack: described_class::DeliverResult::STOPPED)

        expect(result.refusal_text).to eq("refused: #{described_class::DeliverResult::STOPPED["detail"]}")
      end

      it "reads an old worker's unavailable ask feature as refused" do
        ack = Samagotchi::Delivery::ASK_UNAVAILABLE
        result = described_class::DeliverResult.new(status: :refused, code: 409, ack: ack)

        expect(result.refusal_text).to eq("refused: #{ack["detail"]}")
      end

      it "reads an old worker's unavailable pair feature as refused" do
        ack = Samagotchi::Delivery::PAIR_UNAVAILABLE
        result = described_class::DeliverResult.new(status: :refused, code: 409, ack: ack)

        expect(result.refusal_text).to eq("refused: #{ack["detail"]}")
      end
    end

    it "needs the sender's client_id" do
      expect { described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir) }
        .to raise_error(ArgumentError, /client_id/)
      expect { described_class.deliver_turn(session.id, prompt: "hi", client_id: nil, state_dir: tmpdir) }
        .to raise_error(ArgumentError, /client_id/)
      expect { described_class.write_turn_input(session.id, prompt: "hi", state_dir: tmpdir) }
        .to raise_error(ArgumentError, /client_id/)
    end

    # chi web's turn route names no state dir: the default one's session.
    it "posts to a live worker of a session in the default state dir, no state_dir given" do
      default = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      default.save
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(default.id), kind: "worker")
      bridge = instance_double(Samagotchi::BridgeClient, features: Samagotchi::Bridge::FEATURES)
      allow(bridge).to receive(:post_turn).and_return(
        Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted","enqueued_id":"e1"}')
      )

      expect(described_class.deliver_turn(default.id, client_id: "cli:send", prompt: "hi", bridge: -> { bridge }))
        .to have_attributes(status: :accepted, via: :bridge)
    end

    it "refuses a chi scratch session, live worker or not, in its one wording, and queues nothing" do
      session.scratch = true
      session.save(state_dir: tmpdir)
      own("worker")
      allow(Process).to receive(:spawn)

      expect do
        described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> { raise "not reached" })
      end.to raise_error(described_class::ScratchSession, Samagotchi::Session::SCRATCH_REFUSED)
      expect { described_class.resume_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::OwnedByTUI, Samagotchi::Session::SCRATCH_REFUSED)
      expect(input_files).to be_empty
      expect(Process).not_to have_received(:spawn)
    end

    it "raises OwnedByTUI up front for a one-shot's session and queues nothing" do
      own("tui")

      expect do
        described_class.deliver_turn(session.id, client_id: "cli:send", prompt: "hi", state_dir: tmpdir, bridge: -> { raise "not reached" })
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
      allow(engine).to receive_messages(messages_checkpoint: [])
      expect do
        Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir)
      end.to raise_error(SystemExit)
    end

    it "runs queued turns with their origin, or none" do
      described_class.write_turn_input(session.id, prompt: "from web", client_id: "web:1", enqueued_id: "e1", state_dir: tmpdir)
      described_class.write_turn_input(session.id, client_id: nil, prompt: "plain", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, **idle_engine_parts, announce_participants: nil, command_registry: Samagotchi::SessionCommandCatalog.builtin_registry, peer_sources: nil, peer_registry: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, "block_fix_ready=": nil, apply_block_fixes: 0, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil)
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
      described_class.write_turn_input(session.id, client_id: nil, prompt: "short", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, **idle_engine_parts, announce_participants: nil, command_registry: Samagotchi::SessionCommandCatalog.builtin_registry, peer_sources: nil, peer_registry: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, "block_fix_ready=": nil, apply_block_fixes: 0, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil)
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
      described_class.write_turn_input(session.id, client_id: nil, prompt: "one", state_dir: tmpdir)
      described_class.write_turn_input(session.id, client_id: nil, prompt: "two", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, **idle_engine_parts, announce_participants: nil, command_registry: Samagotchi::SessionCommandCatalog.builtin_registry, peer_sources: nil, peer_registry: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, "block_fix_ready=": nil, apply_block_fixes: 0, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil)
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
      event_log = Samagotchi::SessionObserver.new
      engine = instance_double(Samagotchi::Engine, **idle_engine_parts, event_log: event_log, announce_participants: nil, command_registry: Samagotchi::SessionCommandCatalog.builtin_registry, peer_sources: nil, peer_registry: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, "block_fix_ready=": nil, apply_block_fixes: 0, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil, live_conversation: nil)
      announced = []
      event_log.subscribe(observer: ->(event) { announced << event.except(:event_seq) })
      drained = nil
      described_class.write_turn_input(session.id, client_id: nil, prompt: "first", state_dir: tmpdir)
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
