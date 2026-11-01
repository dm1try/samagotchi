# frozen_string_literal: true

require "tmpdir"
require "samagotchi/context_candidate_choice"
require "samagotchi/context_candidates_log"
require "samagotchi/context_judge"
require "samagotchi/system_one"
require "samagotchi/session"

# The owner's say on a judged candidate, as a label on the latest ask's run.
RSpec.describe "Context candidates: labels on the saved runs" do
  let(:dir) { Dir.mktmpdir("context-runs") }
  let(:sessions) { File.join(dir, "sessions") }
  let(:store) { Samagotchi::SystemOne::RunsStore.new(dir) }
  let(:log) { Samagotchi::ContextCandidatesLog.log_for(sessions) }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir).tap { |s| s.save(state_dir: sessions) }
  end
  let(:candidate) do
    Samagotchi::ContextSources::Candidate.new(name: "pr-1", url: nil, cmd: "printf x", title: "PR 1", describe: nil,
                                              mentions: [], proposed_by: "plugin:test", at: "2026-10-31T10:00:00Z")
  end

  before do
    FileUtils.mkdir_p(sessions)
    Samagotchi::ContextSources.session_location(session.id, state_dir: sessions).add_candidate(candidate)
  end

  after { FileUtils.rm_rf(dir) }

  def judged(run_id, name: "pr-1")
    Samagotchi::ContextCandidatesLog.event("judged", session_id: session.id, name: name, log: log, run_id: run_id, stated: true, owner_prompts: 1)
  end

  def labels = store.names.flat_map { |name| store.lines(name) }.select { |line| line["kind"] == "label" }
  def choose(action) = Samagotchi::ContextCandidateChoice.choose(action, "pr-1", session: session, state_dir: sessions, show_card: ->(**) {})

  it "labels the latest ask on /context attach, question about, by command" do
    judged("context.candidate/old")
    judged("context.candidate/new")
    expect(choose(:attach).first).to eq(:ok)
    expect(labels.size).to eq(1)
    expect(labels.first).to include("run_id" => "context.candidate/new", "value" => "attached", "by" => "command", "question" => "about")
  end

  it "labels on /context decline" do
    judged("context.candidate/1")
    choose(:decline)
    expect(labels.first).to include("value" => "declined", "by" => "command")
  end

  it "labels a removal #look sees, by user, not an attach by hand" do
    judged("context.candidate/1")
    records = Samagotchi::ContextCandidatesLog.records_for(log, session.id)
    Samagotchi::ContextCandidatesLog.look(log, session.id, [[candidate, "declined"]], records)
    expect(labels.first).to include("run_id" => "context.candidate/1", "value" => "declined", "by" => "user")

    FileUtils.rm_rf(File.join(dir, "system_one"))
    records = Samagotchi::ContextCandidatesLog.records_for(log, session.id)
    Samagotchi::ContextCandidatesLog.look(log, session.id, [[candidate, "attached"]], records)
    expect(labels).to be_empty
  end

  it "labels nothing with no ask, and another candidate's ask is not this one's" do
    judged("context.candidate/other", name: "pr-2")
    choose(:attach)
    expect(labels).to be_empty
  end

  it "keeps the run id on the judged line" do
    answer = ->(id, p) { Samagotchi::SystemOne::Answer.new(id: id, type: :noul, noul: p) }
    client = instance_double(Samagotchi::SystemOne::Client, host: "h", model: "m")
    seen = nil
    allow(client).to receive(:ask) do |run_id:, **|
      seen = run_id
      { "about" => answer.call("about", 0.9), "task" => answer.call("task", 0.9) }
    end
    job = Samagotchi::ContextJudge::Job.new(session_id: session.id, name: "pr-1", title: "PR 1", describe: nil, conversation: ["fix it"],
                                            parent_attached: nil, owner_prompts: 1, phase: "turn")
    settings = Samagotchi::ContextJudge::Settings.new(mode: "audit", threshold: 0.8, offer_threshold: 0.5, reask_after_turns: 2)
    Samagotchi::ContextJudge.ask(client: client, job: job, log: log, settings: settings)
    expect(seen).to start_with("context.candidate/")
    expect(Samagotchi::ContextCandidatesLog.records_for(log, session.id).last["run_id"]).to eq(seen)
  end
end
