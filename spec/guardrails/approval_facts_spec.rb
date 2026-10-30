# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/guardrails"
require "samagotchi/pending_question"

RSpec.describe Samagotchi::Guardrails::ApprovalFacts do
  # A card as an older session.json saved it: string keys, only some of the
  # fields, nested preview with string keys, and a key this version doesn't know.
  let(:saved) do
    {
      "tool" => "edit", "paths" => ["/repo/a.rb"], "cwd" => "/repo", "repo_root" => "/repo", "repo_name" => "repo",
      "rule" => "edit-outside", "source" => "bundle guardrails", "reason" => "edits a file",
      "scopes" => %w[once session], "preview" => { "added" => 1, "removed" => 0, "text" => "+x" },
      "someday" => "a field from a newer chi"
    }
  end

  it "reads a saved card back (string keys, missing fields nil, unknown keys dropped) and writes the same hash" do
    facts = described_class.from_h(saved)
    expect(facts.tool).to eq("edit")
    expect(facts.scopes).to eq(%w[once session])
    expect(facts.command).to be_nil
    expect(facts.preview).to eq(saved["preview"])
    expect(facts.to_h).to eq(saved.except("someday").transform_keys(&:to_sym))
    expect(described_class.from_h(saved.transform_keys(&:to_sym))).to eq(facts)
  end

  it "takes facts as they are and nothing that isn't facts" do
    facts = described_class.new(tool: "execute")
    expect(described_class.from_h(facts)).to be(facts)
    expect(described_class.from_h(nil)).to be_nil
    expect(described_class.from_h("execute")).to be_nil
    expect(described_class.new.to_h).to eq({})
  end

  describe "an ask's card through the session file" do
    let(:dir) { File.realpath(Dir.mktmpdir("guard-facts")) }
    let(:call) { { name: "execute", content: "git push origin main" } }

    after { FileUtils.rm_rf(dir) }

    def payload
      v = Samagotchi::Guardrails::Verdict.new(call: call)
      v.ask!("git push publishes commits", scopes: %w[once session], rule: "git-push", source: "bundle guardrails")
      v.context = Samagotchi::Guardrails::Context.new(cwd: dir)
      v.targets = Samagotchi::Guardrails::Targets.for(call, v.context)
      Samagotchi::Guardrails::Approval.payload(v, author: "p:p_0123abcd", author_name: "Sam")
    end

    it "keeps the hash the card always carried, and loads back to the same facts" do
      built = payload
      facts = built[:approval]
      expect(facts).to be_a(described_class)
      wire = facts.to_h
      expect(wire.keys).to eq(%i[tool command cwd rule source reason scopes author author_name asked_by])
      expect(wire).to include(tool: "execute", command: "git push origin main", cwd: dir, scopes: ["once"])

      pending = Samagotchi::PendingQuestion.new(**built, approval: wire, id: "q1")
      file = JSON.parse(JSON.generate(pending.to_file))
      loaded = Samagotchi::PendingQuestion.from_file(file)
      expect(loaded.approval).to eq(JSON.parse(JSON.generate(wire)))
      expect(described_class.from_h(loaded.approval)).to eq(facts)
      expect(described_class.from_h(loaded.approval).to_h).to eq(wire)
    end
  end
end
