# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/context_candidates_log"
require "samagotchi/context_sources"
require "samagotchi/session_manager"

RSpec.describe Samagotchi::ContextCandidatesLog do
  def candidate(name)
    Samagotchi::ContextSources::Candidate.new(name: name, url: nil, cmd: "date", title: name.upcase, describe: nil,
                                              mentions: [], proposed_by: "plugin:x", at: "2026-10-31T10:00:00Z")
  end

  it "sits beside the sessions folder" do
    expect(described_class.path("/state/samagotchi/sessions")).to eq("/state/samagotchi/context_candidates.jsonl")
  end

  it "reads the status each candidate's lines left it in" do
    records = [{ "kind" => "proposed", "name" => "a" }, { "kind" => "mentioned", "name" => "a" },
               { "kind" => "proposed", "name" => "b" }, { "kind" => "judged", "name" => "b" },
               { "kind" => "declined", "name" => "b" }, { "kind" => "proposed", "name" => "c" },
               { "kind" => "withdrawn", "name" => "c" }, { "kind" => "proposed", "name" => "d" },
               { "kind" => "carded", "name" => "d" }, { "kind" => "proposed", "name" => "e" },
               { "kind" => "judge_attached", "name" => "e" }]

    expect(described_class.statuses(records)).to eq("a" => "attached", "b" => "declined", "d" => "proposed", "e" => "attached")
  end

  it "logs what the user changed since the last line: attached, declined, detached" do
    Dir.mktmpdir("candidates-log") do |dir|
      log = described_class.log_for(File.join(dir, "sessions"))
      records = [{ "kind" => "mentioned", "name" => "c" }, { "kind" => "proposed", "name" => "d" }]
      rows = [[candidate("a"), "attached"], [candidate("b"), "declined"], [candidate("c"), "proposed"],
              [candidate("d"), "proposed"]]

      kinds = described_class.look(log, "s1", rows, records)

      expect(kinds).to eq(%w[attached declined detached])
      expect(log.records.map { |line| line.values_at("kind", "name", "by", "session_id") })
        .to eq([%w[attached a user s1], %w[declined b user s1], %w[detached c user s1]])
      expect(described_class.look(log, "s1", rows, described_class.records_for(log, "s1"))).to eq([])
    end
  end

  it "keeps a logged prompt to one short line" do
    expect(described_class.short("a\n  b")).to eq("a b")
    expect(described_class.short("x" * 300).length).to eq(described_class::PROMPT_MAX)
  end

  it "chi sessions delete drops the session's lines, and no other session's" do
    Dir.mktmpdir("candidates-log") do |dir|
      state = File.join(dir, "sessions")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir).tap { |s| s.save(state_dir: state) }
      described_class.event("proposed", session_id: session.id, name: "a", state_dir: state)
      described_class.event("judged", session_id: session.id, name: "a", state_dir: state, run_id: "r1",
                            prompt: described_class.short("work on the fence " * 40))
      described_class.event("proposed", session_id: "other", name: "b", state_dir: state)

      Samagotchi::SessionManager.delete_session(session.id, state_dir: state)

      log = described_class.log_for(state)
      expect(log.records.map { |line| line["session_id"] }).to eq(["other"])
      expect(File.read(log.path)).not_to include("fence")
    end
  end

  it "leaves the log alone when an empty session is discarded (purge_runs: false)" do
    Dir.mktmpdir("candidates-log") do |dir|
      state = File.join(dir, "sessions")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: dir).tap { |s| s.save(state_dir: state) }
      described_class.event("proposed", session_id: "other", name: "b", state_dir: state)
      log = described_class.log_for(state)
      before = File.stat(log.path).mtime
      expect(described_class).not_to receive(:purge_session)

      Samagotchi::SessionManager.delete_session(session.id, state_dir: state, purge_runs: false)

      expect(File.stat(log.path).mtime).to eq(before)
    end
  end
end
