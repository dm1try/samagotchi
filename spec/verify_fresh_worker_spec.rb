# frozen_string_literal: true

require "spec_helper"
require "support/worker_fixtures"
require "support/test_kernel"
require "tmpdir"
require "json"

require "samagotchi/engine"
require "samagotchi/worker"
require "samagotchi/participants"
require "samagotchi/analytics_file"
require "samagotchi/verify_fresh"
require "samagotchi/web/grants"

# A Verify fresh child's worker: its turns are its requester's (their
# author, the parent's participants.json, their cap counted across the
# parent), its verdict goes to the parent's inbox, and the parent's worker
# takes it onto the card without touching its conversation.
RSpec.describe Samagotchi::Worker, "Verify fresh" do
  around do |example|
    WebMock.allow_net_connect! if defined?(WebMock)
    with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run }
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
  end

  let(:tmpdir) { Dir.mktmpdir("fresh-worker") }
  let(:source_turn) { "11111111-2222-3333-4444-555555555555" }
  let(:check_turn) { "22222222-3333-4444-5555-666666666666" }
  let(:anchor) { { turn_id: source_turn, quote: "the cache key ignores the model" } }
  let!(:parent) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
      s.messages << { role: "user", content: "audit", turn_id: source_turn }
      s.verdicts = [{ anchor: anchor, verdict: "unclear", reason: "?", by: nil, check_turn_id: check_turn }]
      s.save(state_dir: tmpdir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: tmpdir))
    end
  end
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: tmpdir)) }
  let!(:grant) do
    Samagotchi::Participants.invite(grants, session_id: parent.id, name: "Alex", mode: "pair", state_dir: tmpdir).grant
  end
  let!(:child) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir,
                                    parent_id: parent.id, delegate: true).tap do |s|
      s.verify_fresh = Samagotchi::VerifyFreshOrigin.new(author: grant.author, mode: "pair", of: check_turn,
                                                         anchor: Samagotchi::VerifyAnchor.from(anchor))
      s.last_prompt = Samagotchi::VerifyFresh.prompt_for(anchor[:quote])
      s.first_turn_id = SecureRandom.uuid
      s.status = Samagotchi::Session::STATUS_RUNNING
      s.save(state_dir: tmpdir)
    end
  end
  let(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }

  before do
    allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    allow(engine).to receive_messages(start_idle: nil, stop_idle: nil)
  end

  after do
    @thread&.kill
    @thread&.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: tmpdir)

  def start_worker(session)
    FileUtils.mkdir_p(File.join(dir_of(session.id), Samagotchi::SessionInbox::INPUT_DIR))
    worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: dir_of(session.id),
                                 idle_exit_minutes: 0, poll_interval: 0.02)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
  end

  def parent_audit
    path = File.join(dir_of(parent.id), Samagotchi::Participants::LOG)
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  it "runs its first prompt as the requester's Verify turn and forwards its verdict to the parent" do
    turns = Queue.new
    allow(engine).to receive(:run_turn) do |session, prompt, **kwargs|
      turns << [prompt, kwargs[:origin]&.author, kwargs[:verify]&.to_h]
      record = { anchor: anchor, verdict: "confirmed", reason: "keys.rb hashes it", by: grant.author,
                 check_turn_id: "33333333-3333-4444-5555-666666666666" }
      session.verdicts = session.verdicts + [record]
      session.status = Samagotchi::Session::STATUS_IDLE
      result
    end
    start_worker(child)

    prompt, author, verify = pop!(turns, "the child's first turn")
    expect(prompt).to start_with("Claim:\n> the cache key ignores the model")
    expect([author, verify]).to eq([grant.author, anchor])
  end

  it "refuses the requester's turn once the parent's spend reached their cap, audited in the parent" do
    File.write(Samagotchi::AnalyticsFile.path(dir_of(parent.id)),
               JSON.generate({ "turn_records" => [{ "id" => "t", "author" => grant.author, "cost" => 2.5 }] }))
    allow(engine).to receive(:run_turn).and_return(result)
    start_worker(child)

    wait_for("the parent's audit of the refusal") do
      parent_audit.any? { |line| line["event"] == "turn" && line["reason"] == "cap_reached" }
    end
    expect(engine).not_to have_received(:run_turn)
  end

  it "refuses every turn once the requester's link in the parent is revoked, the owner's typed ones too" do
    Samagotchi::Participants.revoke(grants, session_id: parent.id, id: grant.id, state_dir: tmpdir)
    allow(engine).to receive(:run_turn).and_return(result)
    child.last_prompt = ""
    child.status = Samagotchi::Session::STATUS_IDLE
    child.save(state_dir: tmpdir)
    start_worker(child)
    Samagotchi::SessionInbox.write_input(dir_of(child.id), prompt: "owner here", client_id: "web:o", enqueued_id: "e1")

    wait_for("the refusal") { parent_audit.any? { |line| line["event"] == "turn" && line["reason"] == "revoked" } }
    expect(engine).not_to have_received(:run_turn)
  end
end
