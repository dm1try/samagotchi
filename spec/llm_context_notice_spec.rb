# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm_context_notice"
require "samagotchi/llm_context_apply"
require "samagotchi/llm_context_edit"

RSpec.describe Samagotchi::LLMContextNotice do
  let(:root) { "/work/shop" }
  let(:conversation) do
    [{ role: "system", content: "chi" }, { role: "user", content: "go" }, *read(1, "#{root}/lib/a.rb"),
     *execute(2, "npm test"), *read(3, "#{root}/lib/b.rb"), *read(4, "#{root}/lib/a.rb")]
  end

  def call(id, name, args) = { id: "c#{id}", name: name, arguments: args }
  def model(*calls) = { role: "model", content: "", tool_calls: calls }
  def result(id, name, text) = { role: "tool_response", content: "[#{name}]\n#{text}", tool_call_id: "c#{id}", tool_ids: ["t#{id}"] }
  def read(id, path) = [model(call(id, "read", { "path" => path })), result(id, "read", "x" * 400)]
  def execute(id, command) = [model(call(id, "execute", { "command" => command })), result(id, "execute", "y" * 400)]

  def edit(id, kind, note, staged_at: "s1", keep: [])
    Samagotchi::LLMContextEdit.new(id: id, kind: kind, note: note, by: kind == :stale ? "chi" : "model",
                                   staged_at: staged_at, applied_at: "a", keep: keep)
  end

  def outcome(edits, freed: 16_400, tail: 800, why: :payoff, staged: 0)
    Samagotchi::LLMContextApply::Outcome.new(applied: edits, staged: staged, freed_chars: freed, tail_chars: tail, why: why)
  end

  it "groups the stale stubs and each forget call's outputs, its note once, and words the row" do
    edits = [edit("t1", :stale, "lib/a.rb: superseded by a later read"),
             edit("t2", :forget, "tests pass; NEXT: b.rb"), edit("t3", :forget, "tests pass; NEXT: b.rb", keep: [[12, 40], [50, 50]])]

    event = described_class.event(conversation, outcome(edits), moment: :request, cwd: root)

    expect(event).to eq(
      type: :llm_context_edited, moment: "request", why: "payoff", freed_tokens: 4100, tail_tokens: 200, staged: 0,
      text: "✂ forgot 2 outputs, stubbed 1 stale read · frees ~4.1k tokens (paid off)",
      groups: [
        { kind: "stale", items: [{ id: "t1", tool: "read", title: "lib/a.rb", note: "lib/a.rb: superseded by a later read" }] },
        { kind: "forget", note: "tests pass; NEXT: b.rb", by: "model",
          items: [{ id: "t2", tool: "execute", title: "npm test" },
                  { id: "t3", tool: "read", title: "lib/b.rb", kept: "12-40, 50" }] }
      ]
    )
  end

  it "keeps two forget calls apart (their staged_at), cuts a long note, and says what stays staged" do
    long = "n" * 400
    edits = [edit("t2", :forget, long, staged_at: "s1"), edit("t3", :forget, long, staged_at: "s2")]

    event = described_class.event(conversation, outcome(edits, freed: 0, why: :turn_end, staged: 1), moment: :turn_end)

    expect(event[:groups].map { |group| group[:items].map { |item| item[:id] } }).to eq([%w[t2], %w[t3]])
    expect(event[:groups].first[:note].length).to eq(300)
    expect(event[:groups].first[:note]).to end_with("…")
    expect(event[:text]).to eq("✂ forgot 2 outputs · frees nothing (at turn end) · 1 more staged")
  end

  it "words a next_request batch without a reason, and an output whose call it can't tell by its id" do
    event = described_class.event(conversation, outcome([edit("t9", :stale, "gone")], freed: 2000, why: :next_request),
                                  moment: :request)

    expect(event[:text]).to eq("✂ stubbed 1 stale read · frees ~500 tokens")
    expect(event[:groups]).to eq([{ kind: "stale", items: [{ id: "t9", note: "gone" }] }])
  end
end
