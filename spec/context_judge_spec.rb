# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/context_judge"
require "samagotchi/context_sources"
require "samagotchi/system_one/answer"
require "samagotchi/system_one/client"

RSpec.describe Samagotchi::ContextJudge do
  let(:settings) { described_class::Settings.new(mode: "audit", threshold: 0.8, offer_threshold: 0.6, reask_after_turns: 3) }

  def candidate(name = "pr-412", title: "#412 Fix the login redirect", describe: nil)
    Samagotchi::ContextSources::Candidate.new(name: name, url: nil, cmd: "printf x", title: title, describe: describe,
                                              mentions: [], proposed_by: "plugin:github-pr", at: "2026-10-31T10:00:00Z")
  end

  def judged(name, owner_prompts, stated: true)
    { "kind" => "judged", "session_id" => "s1", "name" => name, "owner_prompts" => owner_prompts, "stated" => stated }
  end

  def job(conversation: ["Fix the login redirect"], parent_attached: nil, describe: nil)
    described_class::Job.new(session_id: "s1", name: "pr-412", title: "#412 Fix the login redirect", describe: describe,
                             conversation: conversation, parent_attached: parent_attached, owner_prompts: 1, phase: "turn")
  end

  describe ".mode" do
    it "is off by default, and an unknown value reads as off" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      expect(described_class.mode).to eq("off")
      allow(Samagotchi::Config).to receive(:get).with("context.candidates.mode").and_return("loud")
      expect(described_class.mode).to eq("off")
      allow(Samagotchi::Config).to receive(:get).with("context.candidates.mode").and_return("Audit")
      expect(described_class.mode).to eq("audit")
    end
  end

  describe ".conversation" do
    it "keeps the first substantive prompt and the latest, each bounded" do
      long = "x" * 2000
      expect(described_class.conversation(["hi", "fix the bug", "and the test", long], skip: 1))
        .to eq(["fix the bug", "#{"x" * 1499}…"])
    end

    it "is one prompt when the first substantive one is the latest" do
      expect(described_class.conversation(["hi", "fix the bug"], skip: 1)).to eq(["fix the bug"])
      expect(described_class.conversation(["fix the bug"])).to eq(["fix the bug"])
    end

    it "falls back to the first prompt when every prompt was skipped" do
      expect(described_class.conversation(%w[hi hello], skip: 5)).to eq(%w[hi hello])
    end
  end

  describe ".state and .questions" do
    it "carries the candidate and the conversation only: no place facts, no why" do
      state = described_class.state(job(describe: "Redirect loops after SSO"))

      expect(state).to eq("candidate" => "#412 Fix the login redirect — Redirect loops after SSO",
                          "conversation" => ["Fix the login redirect"])
    end

    it "adds started_from for a delegate child, and the child's instructions say what it is" do
      state = described_class.state(job(parent_attached: ["#400 Epic: auth"]))
      expect(state["started_from"]).to eq("parent_attached" => ["#400 Epic: auth"])

      child = described_class.questions(child: true)
      plain = described_class.questions(child: false)
      expect(child["about"].instructions).to include("Is this session's work about the candidate?",
                                                     "first message is that session's request")
      expect(plain["about"].instructions).not_to include("started_from")
      expect(plain["task"].instructions).to include("Has the user stated a task yet?")
      expect(plain.values.map(&:type)).to all(eq(:noul))
    end

    it "keeps the instructions constant across candidates (the candidate lives in the state)" do
      expect(described_class.questions(child: false).values.map(&:instructions).join).not_to include("#412")
      expect(described_class::ABOUT).not_to match(/checkout|branch|found for/i)
    end
  end

  describe ".due?" do
    it "asks an unjudged candidate, and again after a deferred ask at a later prompt" do
      expect(described_class.due?([], "a", owner_prompts: 1, reask_after_turns: 3)).to be(true)
      deferred = [judged("a", 1, stated: false)]
      expect(described_class.due?(deferred, "a", owner_prompts: 1, reask_after_turns: 3)).to be(false)
      expect(described_class.due?(deferred, "a", owner_prompts: 2, reask_after_turns: 3)).to be(true)
    end

    it "re-asks once after reask_after_turns owner prompts, then is done" do
      once = [judged("a", 2)]
      expect(described_class.due?(once, "a", owner_prompts: 4, reask_after_turns: 3)).to be(false)
      expect(described_class.due?(once, "a", owner_prompts: 5, reask_after_turns: 3)).to be(true)
      expect(described_class.due?(once + [judged("a", 5)], "a", owner_prompts: 30, reask_after_turns: 3)).to be(false)
    end

    it "counts only the candidate's own asks" do
      expect(described_class.due?([judged("b", 1)], "a", owner_prompts: 1, reask_after_turns: 3)).to be(true)
    end
  end

  describe ".jobs" do
    it "takes the proposed candidates due an ask, skipping the prompts no ask found a task in" do
      rows = [[candidate("a"), "proposed"], [candidate("b"), "attached"], [candidate("c"), "declined"]]
      records = [judged("a", 1, stated: false)]

      jobs = described_class.jobs(rows, records, session_id: "s1", texts: ["hi", "fix the login redirect"],
                                                 parent_attached: nil, settings: settings, phase: "turn")

      expect(jobs.map(&:name)).to eq(["a"])
      expect(jobs.first.conversation).to eq(["fix the login redirect"])
      expect(jobs.first.owner_prompts).to eq(2)
    end

    it "keeps a delegate child's first prompt (the parent's request)" do
      jobs = described_class.jobs([[candidate("a"), "proposed"]], [judged("x", 1, stated: false)], session_id: "s1",
                                                                                                  texts: ["do the auth part", "go on"], parent_attached: [], settings: settings, phase: "turn")

      expect(jobs.first.conversation).to eq(["do the auth part", "go on"])
    end

    it "asks nothing before the owner's first prompt" do
      expect(described_class.jobs([[candidate, "proposed"]], [], session_id: "s1", texts: [], parent_attached: nil,
                                                                settings: settings, phase: "late")).to be_empty
    end
  end

  describe ".ask" do
    def answer(id, noul) = Samagotchi::SystemOne::Answer.new(id: id, type: :noul, noul: noul)

    it "logs a judged line with p, task p and what each threshold would do" do
      Dir.mktmpdir("context-judge") do |dir|
        log = Samagotchi::ContextCandidatesLog.log_for(File.join(dir, "sessions"))
        client = instance_double(Samagotchi::SystemOne::Client, host: "openrouter", model: "typesafe/jev-1.14")
        allow(client).to receive(:ask).and_return("about" => answer("about", 0.7), "task" => answer("task", 0.9))

        described_class.ask(client: client, job: job, log: log, settings: settings)

        expect(client).to have_received(:ask).with(hash_including(state: hash_including("candidate")))
        line = log.records.last
        expect(line).to include("kind" => "judged", "session_id" => "s1", "name" => "pr-412", "p" => 0.7,
                                "task_p" => 0.9, "stated" => true, "would" => "offer", "owner_prompts" => 1,
                                "host" => "openrouter", "model" => "typesafe/jev-1.14", "mode" => "audit")
        expect(line).not_to have_key("child")
      end
    end

    it "defers when no task is stated yet, and writes nothing without an answer" do
      Dir.mktmpdir("context-judge") do |dir|
        log = Samagotchi::ContextCandidatesLog.log_for(File.join(dir, "sessions"))
        client = instance_double(Samagotchi::SystemOne::Client, host: "h", model: nil)
        allow(client).to receive(:ask).and_return({ "about" => answer("about", 0.95), "task" => answer("task", 0.2) }, nil)

        described_class.ask(client: client, job: job, log: log, settings: settings)
        described_class.ask(client: client, job: job, log: log, settings: settings)

        expect(log.records.size).to eq(1)
        expect(log.records.last).to include("stated" => false, "p" => 0.95)
        expect(log.records.last).not_to have_key("would")
      end
    end
  end
end
