# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/worker_link"
require "samagotchi/archive_store"
require "samagotchi/peer_mailbox"

# chi web's …/peers routes: the peers model from the two stores (no
# worker), a message's text, Unpair, and the remote's pair and say (the
# say's wait on the server). All the owner's.
RSpec.describe Samagotchi::Web::App, "peers" do
  let(:tmpdir) { Dir.mktmpdir("web-peers") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: tmpdir).tap do |s|
      s.messages = [{ role: "user", content: "hi" }]
      s.save(state_dir: state_dir)
    end
  end
  let(:app) { described_class.new(state_dir: state_dir, session_class: Samagotchi::Session, bridge_wait_timeout: 0) }
  let(:base) { "/api/sessions/#{session.id}/peers" }
  let(:worker) { Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", started_at: nil) }

  before do
    allow(Samagotchi::SessionManager).to receive(:session_owner).and_return(worker)
    allow(Samagotchi::WorkerLink).to receive(:live_features).and_return([Samagotchi::PeerMailbox::FEATURE])
  end

  after { FileUtils.rm_rf(tmpdir) }

  def call(path, method: "GET", body: nil)
    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: method,
                                          input: body && JSON.generate(body), "CONTENT_TYPE" => "application/json")
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.to_a.join)]
  end

  def post_message(text, **fields)
    Samagotchi::PeerMailbox.post(session.id, "claude", text: text, summary: fields[:summary], wake: fields.fetch(:wake, true),
                                                       re: fields[:re], state_dir: state_dir)
  end

  def receipts(peers)
    path = Samagotchi::PeerReceipts.path(session.id, state_dir: state_dir)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate("peers" => peers))
  end

  it "says it has chi peer in /api/info's features" do
    expect(call("/api/info").last["features"]).to include(Samagotchi::PeerMailbox::FEATURE)
  end

  describe "GET …/peers" do
    it "gives each mailbox peer its link, its newest messages with their receipts, and its answers as exchanges" do
      Samagotchi::PeerMailbox.pair(session.id, "claude", address: "/tmp/c.sock", from: "claude-code", state_dir: state_dir)
      Samagotchi::PeerExchanges.append(session.id, { t: "sent", peer: "claude", id: "s-a", kind: "validate", title: "plan",
                                                     by: "model" }, state_dir: state_dir)
      post_message("private answer", summary: "VERDICT OK", re: "s-a")
      post_message("second", summary: "more", wake: false)
      receipts("claude" => { "box" => "a1b2c3", "taken" => 2, "receipts" => [
        { "serial" => 1, "state" => "ended", "outcome" => "completed", "turn" => "t1", "at" => "x" },
        { "serial" => 2, "state" => "held", "reason" => "peer_turns", "at" => "x" }
      ] })

      status, body = call(base)
      expect(status).to eq(200)
      peer = body["peers"].find { |row| row["name"] == "claude" }
      expect(peer).to include("label" => "Claude", "from" => "claude-code", "can_send" => true, "inbox" => false, "outbox" => false)
      expect(peer["paired_at"]).to match(/\A\d{4}-/)
      expect(peer["messages"].map { |m| [m["serial"], m.dig("receipt", "state")] }).to eq([[2, "held"], [1, "ended"]])
      expect(peer["exchanges"].find { |row| row["id"] == "s-a" }).to include("state" => "answered",
                                                                             "answer" => include("serial" => 1, "verdict" => "OK"))
      expect(JSON.generate(body)).not_to include("private answer")
    end

    it "lists a peer that is not paired but has messages, can_send false" do
      post_message("hi")
      peer = call(base).last["peers"].first
      expect(peer).to include("name" => "claude", "paired_at" => nil, "can_send" => false)
      expect(peer["messages"].size).to eq(1)
    end

    it "keeps the context legs' rows as they were" do
      own = Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir)
      own.add(Samagotchi::ContextSources::Source.new(name: "codex-outbox", cmd: nil, every_seconds: nil, why: nil, hint: nil,
                                                     scope: "session", added_by: "cli", created_at: nil))
      expect(call(base).last["peers"]).to contain_exactly(include("name" => "codex", "outbox" => true, "messages" => []))
    end
  end

  describe "GET …/peers/NAME/messages/SERIAL" do
    it "gives one message's text and its receipt" do
      post_message("the text", summary: "s")
      status, body = call("#{base}/claude/messages/1")
      expect(status).to eq(200)
      expect(body).to include("serial" => 1, "text" => "the text", "summary" => "s", "receipt" => nil)
    end

    it "answers 404 for none and 400 for a bad name" do
      expect(call("#{base}/claude/messages/9")).to eq([404, { "error" => "no_message", "detail" => "no message 9 from claude" }])
      expect(call("#{base}/Claude/messages/1").first).to eq(400)
    end
  end

  describe "DELETE …/peers/NAME" do
    it "unpairs, keeping the messages; a second time says there was none" do
      Samagotchi::PeerMailbox.pair(session.id, "claude", address: nil, from: nil, state_dir: state_dir)
      post_message("kept")
      expect(call("#{base}/claude", method: "DELETE")).to eq([200, { "unpaired" => true }])
      expect(Samagotchi::PeerMailbox.link(session.id, "claude", state_dir: state_dir)).to be_nil
      expect(Samagotchi::PeerMailbox.serials(session.id, "claude", state_dir: state_dir)).to eq([1])
      expect(call("#{base}/claude", method: "DELETE")).to eq([200, { "unpaired" => false }])
    end
  end

  describe "POST …/peers/NAME/pair" do
    it "pairs" do
      status, body = call("#{base}/claude/pair", method: "POST", body: { address: "/tmp/s", from: "ssh" })
      expect(status).to eq(200)
      expect(body).to include("status" => "paired", "link" => include("peer" => "claude", "address" => "/tmp/s", "from" => "ssh"))
    end

    it "refuses an old worker (409) and a continued session with the next id" do
      allow(Samagotchi::WorkerLink).to receive(:live_features).and_return(["restart"])
      expect(call("#{base}/claude/pair", method: "POST", body: {})).to match([409, include("status" => "old_worker")])

      allow(Samagotchi::WorkerLink).to receive(:live_features).and_return(nil)
      Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)
      successor = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir,
                                                  continues: session.id).tap { |s| s.save(state_dir: state_dir) }
      expect(call("#{base}/claude/pair", method: "POST", body: {}))
        .to match([409, include("status" => "continued", "next_id" => successor.id)])
    end

    it "answers 404 for no session" do
      expect(call("/api/sessions/11111111-2222-3333-4444-555555555555/peers/claude/pair", method: "POST", body: {}).first).to eq(404)
    end
  end

  describe "POST …/peers/NAME/say" do
    before { Samagotchi::PeerMailbox.pair(session.id, "claude", address: nil, from: nil, state_dir: state_dir) }

    it "writes the message and waits on the server for the receipt, answering the finished line" do
      allow_any_instance_of(Samagotchi::SessionAccess::Local).to receive(:sleep) do
        receipts("claude" => { "box" => "a1b2c3", "taken" => 1, "receipts" => [{ "serial" => 1, "state" => "woke", "turn" => "t", "at" => "x" }] })
      end
      status, body = call("#{base}/claude/say", method: "POST", body: { text: "hi", summary: "s", wake: true, re: "s-1", wait: 8 })
      expect(status).to eq(200)
      expect(body).to include("status" => "received", "serial" => 1, "line" => "#1 received · woke chi")
      expect(Samagotchi::PeerMailbox.message(session.id, "claude", 1, state_dir: state_dir).re).to eq("s-1")
    end

    it "refuses with 409 and the PeerSay; a bad text is 400" do
      Samagotchi::PeerMailbox.unpair(session.id, "claude", state_dir: state_dir)
      expect(call("#{base}/claude/say", method: "POST", body: { text: "hi", wake: true }))
        .to match([409, include("status" => "not_paired", "line" => "not paired: run the pair script")])
      expect(call("#{base}/claude/say", method: "POST", body: { text: "", wake: true }).first).to eq(400)
      expect(call("#{base}/claude/say", method: "POST", body: { text: "hi", wake: true, wait: 99 }).first).to eq(400)
    end
  end
end
