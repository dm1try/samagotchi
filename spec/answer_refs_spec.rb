# frozen_string_literal: true

require "samagotchi/answer_refs"

RSpec.describe Samagotchi::AnswerRefs do
  let(:answer) { { role: "model", content: "see JIRA-1" } }
  let(:event) { { hook: "links.rb (bundle x)" } }
  let(:jira) do
    { match: "JIRA-1", kind: "issue", target: { id: "JIRA-1" },
      actions: [{ id: "open", label: "Open in Jira", url: "https://jira.test/browse/JIRA-1" }] }
  end
  let(:rejections) { [] }

  before do
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    allow(Samagotchi::Log).to receive(:warn).with(:hooks, "refs_rejected", anything) { |_, _, **f| rejections << f }
  end

  def refs_for(messages = [answer], cwd: "/proj") = described_class.new(messages, cwd: cwd)

  it "adds a ref and returns true; the stored shape is {match:, kind:, target:, label:, actions:}" do
    refs = refs_for
    expect(refs.adder(event).call(**jira, label: " JIRA-1 Login fails ")).to be(true)

    expect(refs).to be_added
    expect(refs.to_a).to eq([{ match: "JIRA-1", kind: "issue", target: { id: "JIRA-1" }, label: "JIRA-1 Login fails",
                               actions: [{ id: "open", label: "Open in Jira", url: "https://jira.test/browse/JIRA-1" }] }])
    expect(rejections).to be_empty
  end

  it "returns nil when the turn has no answer (a turn note is last)" do
    refs = refs_for([answer, { role: "system", kind: "turn_note", content: "[SYSTEM: cancelled]" }])

    expect(refs.adder(event).call(**jira)).to be_nil
    expect(refs).not_to be_added
  end

  it "keeps a duplicate once, and it doesn't count" do
    refs = refs_for
    add = refs.adder(event)

    expect([add.call(**jira), add.call(**jira)]).to eq([true, true])
    expect(refs.count).to eq(1)
  end

  it "refuses the 201st ref, logging the cap once for that hook" do
    refs = refs_for
    add = refs.adder(event)
    described_class::MAX_REFS.times { |i| expect(add.call(match: "J-#{i}", kind: "issue", target: { id: "J-#{i}" })).to be(true) }

    expect(add.call(match: "J-x", kind: "issue", target: { id: "J-x" })).to be(false)
    expect(add.call(match: "J-y", kind: "issue", target: { id: "J-y" })).to be(false)
    expect(rejections).to eq([{ echo: "[samagotchi:hooks] links.rb (bundle x): ref over the cap (200 refs); dropped",
                                hook: "links.rb (bundle x)", reason: "over the cap (200 refs)" }])
    expect(refs.adder({ hook: "other.rb" }).call(match: "J-z", kind: "issue", target: { id: "J-z" })).to be(false)
    expect(rejections.map { |f| f[:hook] }).to eq(["links.rb (bundle x)", "other.rb"])
    expect(refs.count).to eq(200)
  end

  it "refuses a ref that would take the list's JSON over the byte cap" do
    refs = refs_for
    add = refs.adder(event)
    big = ->(i) { { match: "m#{i}", kind: "issue", target: { id: "i#{i}" }, label: "L" * 200, actions: Array.new(8) { |a| { id: "a#{a}", label: "A" * 100, url: "https://x.test/#{"u" * 1_900}" } } } }
    added = (0...described_class::MAX_REFS).take_while { |i| add.call(**big.call(i)) }

    expect(added.length).to be < described_class::MAX_REFS
    expect(JSON.generate(refs.to_a).bytesize).to be <= described_class::MAX_BYTES
    expect(rejections.map { |f| f[:reason] }).to eq(["over the cap (256 KiB)"])
    expect(add.call(match: "small", kind: "issue", target: { id: "s" })).to be(true)
  end

  it "refuses invalid refs (false), each logged with the hook's name" do
    add = refs_for.adder(event)

    expect(add.call(**jira, kind: "Bad Kind")).to be(false)
    expect(add.call(match: "x", kind: "issue")).to be(false)
    expect(add.call(**jira, actions: [{ id: "a", label: "A", url: "javascript:alert(1)" }])).to be(false)
    expect(add.call(**jira, match: "  ")).to be(false)
    expect(add.call(**jira, match: "m" * 501)).to be(false)
    expect(add.call(jira)).to be(false)
    expect(add.call(**jira, url: "https://x.test")).to be(false)
    expect(rejections.length).to eq(7)
    expect(rejections).to all(include(hook: "links.rb (bundle x)"))
    expect(rejections.map { |f| f[:reason] }).to include(/kind/, /target/, /http/, /match/, /at most 500/, /keywords/, /unknown keys/)
  end

  it "says each reason once per hook per answer; the same again goes to debug with its count" do
    debug = []
    allow(Samagotchi::Log).to receive(:debug).and_call_original
    allow(Samagotchi::Log).to receive(:debug).with(:hooks, "refs_rejected", anything) { |_, _, **f| debug << f }
    add = refs_for.adder(event)

    3.times { |i| expect(add.call(**jira, kind: "Bad Kind #{i}")).to be(false) }
    expect(add.call(**jira, match: " ")).to be(false)
    expect(refs_for.adder(event).call(**jira, kind: "Bad")).to be(false)

    expect(rejections.map { |f| f[:reason] }).to eq([%(a ref's kind is a short lowercase word ("Bad Kind 0")), "a ref needs a match (the text it stands for)",
                                                     %(a ref's kind is a short lowercase word ("Bad"))])
    expect(debug.map { |f| f.slice(:hook, :count) }).to eq([{ hook: "links.rb (bundle x)", count: 2 }, { hook: "links.rb (bundle x)", count: 3 }])
  end

  it "returns nil once the list is stored (close!): a late call would be lost" do
    refs = refs_for
    add = refs.adder(event)
    refs.close!

    expect(add.call(**jira)).to be_nil
    expect(refs.count).to eq(0)
    expect(refs).not_to be_added
    expect(rejections).to be_empty
  end

  it "accepts a 500-character match" do
    expect(refs_for.adder(event).call(**jira, match: "m" * 500)).to be(true)
  end

  it "resolves a relative file path against the session folder; an absolute one stays" do
    refs = refs_for(cwd: "/proj")
    add = refs.adder(event)

    expect(add.call(match: "a.rb:3", kind: "file", target: { "path" => "lib/a.rb", "line" => 3 })).to be(true)
    expect(add.call(match: "b.rb", kind: "file", target: { path: "/elsewhere/b.rb" })).to be(true)
    expect(add.call(match: "~x", kind: "file", target: { path: "~nosuchuser/c.rb" })).to be(true)
    expect(refs.to_a.map { |r| r[:target][:path] }).to eq(["/proj/lib/a.rb", "/elsewhere/b.rb", "/proj/~nosuchuser/c.rb"])
  end

  it "refuses a relative file path when the session has no folder" do
    expect(refs_for(cwd: nil).adder(event).call(match: "a.rb", kind: "file", target: { path: "lib/a.rb" })).to be(false)
    expect(rejections.map { |f| f[:reason] }).to eq(["relative path, no session folder"])
  end

  it "starts from the refs the answer has (string keys, as Session.load leaves them), so none are lost" do
    stored = { "match" => "JIRA-1", "kind" => "issue", "target" => { "id" => "JIRA-1" },
               "actions" => [{ "id" => "open", "label" => "Open in Jira", "url" => "https://jira.test/browse/JIRA-1" }] }
    refs = refs_for([answer.merge(display_refs: [stored])])

    expect(refs.count).to eq(1)
    expect(refs).not_to be_added
    expect(refs.adder(event).call(**jira)).to be(true)
    expect(refs).not_to be_added
    expect(refs.adder(event).call(match: "JIRA-2", kind: "issue", target: { id: "JIRA-2" })).to be(true)
    expect(refs.to_a.map { |r| r[:match] }).to eq(%w[JIRA-1 JIRA-2])
  end

  describe ".for_display" do
    it "rebuilds stored refs with either key type" do
      symbols = jira.merge(label: "L")
      strings = JSON.parse(JSON.generate(jira.merge(match: "JIRA-1 again")))

      expect(described_class.for_display([symbols, strings]).map { |r| r[:match] }).to eq(["JIRA-1", "JIRA-1 again"])
      expect(described_class.for_display([strings]).first[:actions].first).to eq(id: "open", label: "Open in Jira", url: "https://jira.test/browse/JIRA-1")
    end

    it "drops invalid entries, a relative path and what is over the caps, and never raises" do
      bad_url = jira.merge(match: "x", actions: [{ id: "a", label: "A", url: "javascript:alert(1)" }])
      relative = { match: "a.rb", kind: "file", target: { path: "lib/a.rb" } }
      many = Array.new(201) { |i| { match: "J-#{i}", kind: "issue", target: { id: "J-#{i}" } } }

      expect(described_class.for_display([jira, bad_url, relative, 42, { kind: nil }])).to eq([AnswerRefsSpec.shape(jira)])
      expect(described_class.for_display(many).length).to eq(200)
      expect(described_class.for_display("junk")).to eq([])
      expect(described_class.for_display(nil)).to eq([])
    end
  end
end

module AnswerRefsSpec
  def self.shape(ref) = Samagotchi::AnswerRef.from(ref).to_h
end
