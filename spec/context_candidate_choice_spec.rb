# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/context_candidate_choice"
require "samagotchi/context_judge"
require "samagotchi/session"

RSpec.describe Samagotchi::ContextCandidateChoice do
  let(:dir) { Dir.mktmpdir("candidate-choice") }
  let(:state_dir) { File.join(dir, "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir).tap { |s| s.save(state_dir: state_dir) }
  end
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }
  let(:log) { Samagotchi::ContextCandidatesLog.log_for(state_dir) }
  let(:settings) { Samagotchi::ContextJudge::Settings.new(mode: "on", threshold: 0.8, offer_threshold: 0.6, reask_after_turns: 3) }
  let(:cards) { [] }
  let(:show_card) { ->(**card) { cards << card } }

  after { FileUtils.rm_rf(dir) }

  def propose(name = "pr-412", title: "#412 Fix the login redirect")
    own.add_candidate(Samagotchi::ContextSources::Candidate.new(name: name, url: nil, cmd: "printf x", title: title, describe: nil,
                                                                mentions: [], proposed_by: "plugin:test", at: "2026-10-31T10:00:00Z"))
  end

  def job(name = "pr-412")
    Samagotchi::ContextJudge::Job.new(session_id: session.id, name: name, title: "t", describe: nil, conversation: ["x"],
                                      parent_attached: nil, owner_prompts: 1, phase: "turn")
  end

  def judged(p, would, stated: true) = { "p" => p, "stated" => stated, "would" => would }

  def after_judged(fields, mode: "on", name: "pr-412")
    described_class.after_judged(job: job(name), fields: fields, settings: settings.with(mode: mode), project_root: dir,
                                 state_dir: state_dir, log: log, show_card: show_card)
  end

  def kinds = log.records.map { |line| line["kind"] }

  describe ".after_judged" do
    it "attaches a candidate at or over the threshold quietly, its why naming the judge without a number" do
      propose

      expect(after_judged(judged(0.9, "attach"))).to eq(:attached)

      source = own.source("pr-412")
      expect(source).to have_attributes(why: "it looks related to your task", title: "#412 Fix the login redirect")
      expect(cards).to be_empty
      expect(log.records.last).to include("kind" => "judge_attached", "name" => "pr-412", "p" => 0.9)
    end

    it "shows one card in the middle band, once per candidate (the log remembers it)" do
      propose

      expect(after_judged(judged(0.7, "offer"))).to eq(:carded)
      expect(after_judged(judged(0.7, "offer"))).to be_nil

      expect(cards.size).to eq(1)
      expect(cards.first).to include(source: "context", id: "context-candidate-pr-412", title: "#412 Fix the login redirect")
      expect(cards.first[:actions]).to eq([{ label: "Attach", command: "/context attach pr-412" },
                                           { label: "Not here", command: "/context decline pr-412" }])
      expect(kinds).to eq(["carded"])
      expect(own.sources).to eq([])
    end

    it "writes no carded line when the card wasn't shown" do
      propose
      described_class.after_judged(job: job, fields: judged(0.7, "offer"), settings: settings, project_root: dir,
                                   state_dir: state_dir, log: log, show_card: ->(**) {})
      expect(kinds).to eq([])
    end

    it "closes an earlier card when a later ask attaches" do
      propose
      after_judged(judged(0.7, "offer"))
      after_judged(judged(0.9, "attach"))

      expect(cards.last).to include(id: "context-candidate-pr-412", actions: [], body: "Attached: it looks related to your task.")
    end

    it "does nothing below the offer threshold, in audit, with no task stated, or for a candidate no longer proposed" do
      propose
      expect(after_judged(judged(0.3, "none"))).to be_nil
      expect(after_judged(judged(0.9, "attach"), mode: "audit")).to be_nil
      expect(after_judged(judged(0.9, nil, stated: false))).to be_nil
      expect(after_judged(nil)).to be_nil
      own.decline("pr-412", "")
      expect(after_judged(judged(0.9, "attach"))).to be_nil

      expect(own.sources).to eq([])
      expect(cards).to be_empty
    end
  end

  describe ".choose" do
    def choose(action, name) = described_class.choose(action, name, session: session, state_dir: state_dir, show_card: show_card)

    it "attaches a proposed candidate with the owner's why, and closes its card" do
      propose

      expect(choose(:attach, "pr-412")).to eq([:ok, "attached pr-412: its text comes with your next message"])
      expect(own.source("pr-412").why).to eq("you attached it")
      expect(cards.last).to include(id: "context-candidate-pr-412", actions: [], body: "Attached.")
      expect(log.records.last).to include("kind" => "attached", "by" => "command")
      expect(choose(:attach, "pr-412")).to eq([:error, "pr-412 is attached already"])
      expect(choose(:decline, "pr-412")).to eq([:error, "pr-412 is attached; chi context rm pr-412 removes it"])
    end

    it "declines a proposed candidate: never proposed or judged again here" do
      propose

      expect(choose(:decline, "pr-412")).to eq([:ok, "declined pr-412: not proposed again in this session"])
      expect(Samagotchi::ContextCandidates.with_status(session.id, project_root: dir, state_dir: state_dir).map(&:last))
        .to eq(["declined"])
      expect(log.records.last).to include("kind" => "declined", "by" => "command")
      expect(cards.last).to include(body: "Not attached here.", actions: [])
      expect(choose(:attach, "pr-412").first).to eq(:error)
    end

    it "refuses an unknown name, a missing one and a review session" do
      expect(choose(:attach, "nope")).to eq([:error, "no candidate nope in this session (see /context)"])
      expect(choose(:attach, "../x")).to eq([:error, "no candidate ../x in this session (see /context)"])
      expect(choose(:attach, "")).to eq([:error, described_class::USAGE])
      propose
      session.review = { "subjects" => ["a.md"] }
      expect(choose(:attach, "pr-412")).to eq([:error, "a review session takes no context candidates"])
      expect(own.sources).to eq([])
    end
  end
end
