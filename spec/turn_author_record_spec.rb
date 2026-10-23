# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/participants"

# A participant's turn is on the record: its opening message carries
# author: and the name it had (participants.json), last_turn and the
# turn's analytics record carry the author. The owner's turns and old
# session files are byte for byte what they were.
RSpec.describe "a turn's author on the record" do
  let(:state_dir) { Dir.mktmpdir("turn-author-record") }

  after { FileUtils.rm_rf(state_dir) }

  describe "a pre-P3 session file" do
    let(:id) { "1b1a8963-0bdd-418b-ac29-ad63559379a3" }
    let(:fixture) { File.expand_path("fixtures/sessions/#{id}.json", __dir__) }

    it "loads and saves byte for byte the same (but its save time)" do
      FileUtils.cp(fixture, state_dir)
      session = Samagotchi::Session.load(id, state_dir: state_dir)

      expect(session.last_turn.author).to be_nil
      expect(session.messages.each_index.map { |i| Samagotchi::Steer.author_at(session.messages, i) }.uniq).to eq([nil])

      session.save(state_dir: state_dir)
      without_save_time = ->(text) { text.sub(/"updated_at": "[^"]*"/, '"updated_at": ""') }
      expect(without_save_time.call(File.read(File.join(state_dir, "#{id}.json")))).to eq(without_save_time.call(File.read(fixture)))
    end
  end

  describe Samagotchi::Engine, "#run_turn" do
    around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

    let(:client) { test_client }
    let(:kernel) { test_kernel(client: client) }
    let(:engine) do
      described_class.new(client: client, kernel: kernel, profile: "gemma4").tap { |e| e.session_state_dir = state_dir }
    end
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd).tap do |s|
        s.save(state_dir: state_dir)
      end
    end
    let(:sent) { [] }

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(kernel).to receive(:run) do |messages, **|
        sent << messages
        Samagotchi::LLM::ModelResult.new(text: "done", conversation: messages.drop(1) + [{ role: "model", content: "done" }],
                                         exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
      end
    end

    # A worker's session has its dir (the owner lock, inputs); the sidecar goes there.
    def invite(name)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))
      grants = Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state_dir))
      Samagotchi::Participants.invite(grants, session_id: session.id, name: name, state_dir: state_dir).grant
    end

    def analytics = Samagotchi::AnalyticsFile.read(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))

    it "saves a participant's opening message with author and name, and puts the author in last_turn and analytics" do
      grant = invite("Alex")
      events = []
      engine.run_turn(session, "Is step 3 safe?", origin: { client_id: "review:#{grant.id}", enqueued_id: "e1", author: grant.author },
                                                  on_event: ->(e) { events << e })

      opening = session.messages.find { |m| m[:role] == "user" }
      expect(opening).to include(content: "Is step 3 safe?", author: grant.author, author_name: "Alex")
      expect(session.last_turn).to have_attributes(author: grant.author, origin: "review")
      expect(session.to_h["last_turn"]).to include("author" => grant.author)
      expect(analytics["turn_records"].last).to include("author" => grant.author)
      expect(sent.last.last).to include(author: grant.author, author_name: "Alex")
      expect(events.find { |e| e[:type] == :turn_started }).to include(author: grant.author, author_name: "Alex")
    end

    it "names a participant the sidecar doesn't know by id only (the header says the id)" do
      engine.run_turn(session, "hi", origin: { client_id: "review:p_0000abcd", author: "p:p_0000abcd" })

      opening = session.messages.find { |m| m[:role] == "user" }
      expect(opening).to include(author: "p:p_0000abcd")
      expect(opening).not_to have_key(:author_name)
      expect(Samagotchi::Steer.header(opening)).to start_with("[Review contribution from p_0000abcd (participant")
    end

    it "marks the analytics record of a turn no person sent automatic (a participant's page hides its prompt); a person's carries no mark" do
      engine.run_turn(session, "task finished", origin: { client_id: "task:20261023-abcd1234", enqueued_id: "e1" })
      engine.run_turn(session, "hi", origin: { client_id: "web:t", enqueued_id: "e2" })
      engine.run_turn(session, "from chi send", origin: { client_id: "cli:send" })

      first, *people = analytics["turn_records"].last(3)
      expect(first).to include("automatic" => true)
      people.each { |record| expect(record).not_to have_key("automatic") }
    end

    it "keeps the owner's turn free of any author: message, last_turn, analytics, even with participants invited" do
      invite("Alex")
      events = []
      engine.run_turn(session, "hi", origin: { client_id: "web:t", enqueued_id: "e1" }, on_event: ->(e) { events << e })

      expect(session.messages.find { |m| m[:role] == "user" }.keys).to eq(%i[role content turn_id])
      expect(session.to_h["last_turn"]).not_to have_key("author")
      expect(analytics["turn_records"].last).not_to have_key("author")
      expect(events.find { |e| e[:type] == :turn_started }.keys).not_to include(:author, :author_name)
    end
  end
end
