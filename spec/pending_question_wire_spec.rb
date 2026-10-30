# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/question_desk"
require "samagotchi/session"

# The pending question's shapes outside the process, pinned: the session
# file's "pending_question" record (key order included), the
# :question_requested event's and a sync handler's Hash. Written before
# PendingQuestion replaced the Hash in memory and kept unchanged after it.
RSpec.describe "the pending question on the wire and on disk" do
  let(:tmpdir) { Dir.mktmpdir("pending-wire") }
  let(:events) { [] }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap { |s| s.save(state_dir: tmpdir) }
  end
  let(:desk) do
    Samagotchi::QuestionDesk.new(session: -> { session }, state_dir: -> { tmpdir }, emit: ->(e) { events << e },
                                 cancel_controller: -> {}, interface: -> { :worker }, user_input: ->(_sid) {})
  end
  let(:approval) do
    { question: "execute: ls", options: ["Allow once", "Deny"], header: "Approve tool call?", multi_select: false,
      allow_freeform: true, kind: "approval", approval: { tool: "execute", command: "ls", scopes: ["once"] } }
  end
  let(:saved_shapes) { JSON.parse(File.read(File.expand_path("fixtures/pending_question/saved_shapes.json", __dir__))) }

  after { FileUtils.rm_rf(tmpdir) }

  def saved_record = JSON.parse(File.read(Dir.glob(File.join(tmpdir, "**", "#{session.id}.json")).first))["pending_question"]

  def requested = events.find { |e| e[:type] == :question_requested }&.dig(:pending_question)

  def open_in_background(fields)
    thread = Thread.new { desk.open_question(fields) }
    thread.report_on_exception = false
    wait_for("the question to be published", timeout: 2) { requested }
    thread
  end

  it "saves and announces an approval with its keys in today's order, the relay mark last" do
    thread = open_in_background(approval)
    id = requested[:id]

    expect(requested.keys).to eq(%i[id question options header multi_select allow_freeform kind approval status created_at])
    expect(requested).to include(id: id, kind: "approval", status: "pending", approval: approval[:approval])
    expect(saved_record.keys).to eq(%w[id question options header multi_select allow_freeform kind approval status created_at])
    expect(saved_record["approval"]).to eq("tool" => "execute", "command" => "ls", "scopes" => ["once"])

    desk.annotate(id, relayed_to: { parent_id: "p-1", parent_short: "p-1", relay_id: "r-1" })
    expect(saved_record.keys.last).to eq("relayed_to")
    expect(saved_record["relayed_to"]).to eq("parent_id" => "p-1", "parent_short" => "p-1", "relay_id" => "r-1")

    desk.cancel("user", id: id)
    join!(thread, "the question")
    expect(saved_record).to be_nil
  end

  it "hands a sync handler the Hash the event carries (symbol keys, same order)" do
    seen = []
    desk.sync_handler = lambda { |pending|
      seen << pending
      "inline"
    }
    desk.open_question({ question: "Which?", options: %w[A B], multi_select: false, allow_freeform: false })

    expect(seen.first).to be_a(Hash)
    expect(seen.first.keys).to eq(%i[id question options multi_select allow_freeform status created_at])
    expect(seen.first).to eq(requested)
  end

  it "saves and announces a standing step-limit question with its keys and values" do
    fields = { kind: "continue", header: "Step limit", question: "Continue it?", options: %w[Continue Stop],
               multi_select: false, allow_freeform: true, limit: 3, context: { original_prompt: "go" } }
    desk.post(fields, on_answer: ->(_answer, client_id:) {})

    expect(requested.keys).to match_array(%i[id kind header question options multi_select allow_freeform limit context status
                                             created_at])
    expect(requested).to include(**fields, status: "pending")
    expect(saved_record).to include("kind" => "continue", "limit" => 3, "context" => { "original_prompt" => "go" })
    expect(saved_record.keys).to match_array(requested.keys.map(&:to_s))
  end

  # Session files saved before PendingQuestion: each kind loads and saves
  # back the same record. The step-limit question's keys come back in
  # PendingQuestion's member order (same keys and values).
  it "loads a session file of today's shape and writes each kind's record back unchanged" do
    saved_shapes.each do |kind, record|
      data = JSON.parse(JSON.generate(session.to_h.merge("pending_question" => record)))
      written = Samagotchi::Session.from_h(data).to_h["pending_question"]

      expect(written).to eq(record), kind
      expect(JSON.pretty_generate(written)).to eq(JSON.pretty_generate(record)), kind unless kind == "continue"
    end
  end
end
