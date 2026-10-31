# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/context_candidates_log"
require "samagotchi/context_sources"

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
               { "kind" => "withdrawn", "name" => "c" }]

    expect(described_class.statuses(records)).to eq("a" => "attached", "b" => "declined")
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
end
