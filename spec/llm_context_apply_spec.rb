# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm_context_apply"

RSpec.describe Samagotchi::LLMContextApply do
  let(:now) { "2026-10-07T18:00:00.000Z" }
  let(:root) { "/work/shop" }
  let(:head) { { role: "system", content: "You are chi." } }
  let(:big) { (1..200).map { |n| "#{n}: line #{n} of the cart" }.join("\n") }
  let(:small) { (1..10).map { |n| "#{n}: line #{n}" }.join("\n") }

  def call(id, name, args) = { id: "c#{id}", name: name, arguments: args }
  def model(*calls) = { role: "model", content: "", tool_calls: calls }
  def result(id, name, text) = { role: "tool_response", content: "[#{name}]\n#{text}", tool_call_id: "c#{id}", tool_ids: ["t#{id}"] }
  def read(id, path, text) = [model(call(id, "read", { "path" => path })), result(id, "read", text)]

  def edit(id, path)
    [model(call(id, "edit", { "path" => path, "old_text" => "a", "new_text" => "b" })), result(id, "edit", "Edited #{path}")]
  end

  def run(conversation, rule:, moment: :request, protect_steps: 0, top_bucket: false, changes: true)
    described_class.run!(conversation, layers: [:stale], rule: rule, moment: moment, protect_steps: protect_steps,
                                       top_bucket: top_bucket, root: root, now: now, changes: changes)
  end

  def applied_ids(conversation)
    conversation.flat_map { |entry| Samagotchi::LLMContextEdit.on(entry).values.select(&:applied?).map(&:id) }
  end

  # t1 a big read a later read superseded, t3 a big read an edit (t4) superseded, then a long tail.
  def session(tail: [])
    [head, { role: "user", content: "go" }, *read(1, "lib/cart.rb", big), *read(2, "lib/cart.rb", big),
     *read(3, "lib/tax.rb", big), *edit(4, "lib/tax.rb"), *tail]
  end

  it "does nothing without a layer" do
    conversation = session

    outcome = described_class.run!(conversation, layers: [], rule: :next_request, moment: :turn_end, protect_steps: 0)

    expect(outcome).to eq(described_class::Outcome.none)
    expect(applied_ids(conversation)).to be_empty
  end

  it "stubs only a read a later read superseded unless edit-driven stubs are on (llm_context.stale_edits)" do
    conversation = session

    expect(run(conversation, rule: :turn_end, moment: :turn_end, changes: false).applied.map(&:id)).to eq(%w[t1])
    expect(run(conversation, rule: :turn_end, moment: :turn_end, changes: false)).to eq(described_class::Outcome.none)
  end

  it "measures a payoff batch once" do
    allow(described_class).to receive(:sent_chars).and_call_original

    run(session, rule: :payoff)

    expect(described_class).to have_received(:sent_chars).exactly(3).times
  end

  describe "next_request" do
    it "applies a read a later read superseded at once, and stages one only an edit superseded until turn end" do
      conversation = session

      outcome = run(conversation, rule: :next_request)

      expect(outcome.applied.map(&:id)).to eq(%w[t1])
      expect(outcome.applied.first).to have_attributes(applied_at: now, note: "lib/cart.rb: superseded by a later read")
      expect(outcome).to have_attributes(staged: 1, why: :next_request)
      expect(applied_ids(conversation)).to eq(%w[t1])

      expect(run(conversation, rule: :next_request, moment: :turn_end)).to have_attributes(staged: 0, why: :turn_end)
      expect(applied_ids(conversation)).to eq(%w[t1 t3])
      stub = Samagotchi::LLMContextEdit.on(conversation[7])["t3"]
      expect(stub.note).to eq("lib/tax.rb: superseded by a later edit")
    end
  end

  describe "turn_end" do
    it "stages everything at a request, saving nothing, and applies it all in one batch at turn end" do
      conversation = session

      expect(run(conversation, rule: :turn_end)).to have_attributes(applied: [], staged: 2, why: nil)
      expect(conversation.select { |entry| entry.key?(:edits) }).to be_empty

      outcome = run(conversation, rule: :turn_end, moment: :turn_end)

      expect(outcome.applied.map(&:id)).to eq(%w[t1 t3])
      expect(outcome.freed_chars).to be > (2 * big.length) - 200
      expect(run(conversation, rule: :turn_end, moment: :turn_end)).to eq(described_class::Outcome.none)
    end
  end

  describe "payoff" do
    it "applies the batch at a request once it frees at least the tail it makes the server read again" do
      conversation = session

      outcome = run(conversation, rule: :payoff)

      expect(outcome.why).to eq(:payoff)
      expect(outcome.freed_chars).to be >= outcome.tail_chars
      expect(applied_ids(conversation)).to eq(%w[t1 t3])
    end

    it "holds it back while the tail is longer, measured, until turn end" do
      tail = (5..8).flat_map { |id| read(id, "lib/other#{id}.rb", big) }
      conversation = session(tail: tail)

      outcome = run(conversation, rule: :payoff)

      expect(outcome).to have_attributes(applied: [], staged: 2, why: :held)
      expect(outcome.tail_chars).to be > outcome.freed_chars
      expect(applied_ids(conversation)).to be_empty
      expect(run(conversation, rule: :payoff, moment: :turn_end).why).to eq(:turn_end)
      expect(applied_ids(conversation)).to eq(%w[t1 t3])
    end

    it "applies it anyway in the top bucket" do
      conversation = session(tail: (5..8).flat_map { |id| read(id, "lib/other#{id}.rb", big) })

      expect(run(conversation, rule: :payoff, top_bucket: true).why).to eq(:top_bucket)
      expect(applied_ids(conversation)).to eq(%w[t1 t3])
    end
  end

  describe "protect_steps" do
    it "keeps every read of a file the last steps edited: an earlier range the edit falls in too (review H1)" do
      ranged = lambda do |id, first, last|
        [model(call(id, "read", { "path" => "lib/a.rb", "start_line" => first, "end_line" => last })), result(id, "read", big)]
      end
      conversation = [head, { role: "user", content: "go" }, *ranged.call(1, 1, 100), *ranged.call(2, 300, 305),
                      *edit(3, "lib/a.rb")]

      expect(run(conversation, rule: :payoff, protect_steps: 3).applied).to be_empty
      expect(run(conversation, rule: :payoff, moment: :turn_end, protect_steps: 3).applied).to be_empty
    end

    it "keeps a protected read's edit saved unapplied staged too" do
      conversation = session
      Samagotchi::LLMContextEdit.store(conversation[7], Samagotchi::LLMContextEdit.new(
        id: "t3", kind: :stale, note: "kept for later", by: "chi",
        staged_at: now, applied_at: nil
      ))

      outcome = run(conversation, rule: :turn_end, moment: :turn_end, protect_steps: 3)

      expect(outcome.applied.map(&:id)).to eq(%w[t1])
    end

    it "never stubs the latest read of a file the last steps edited, at turn end either, until the steps pass" do
      conversation = session

      outcome = run(conversation, rule: :turn_end, moment: :turn_end, protect_steps: 3)

      expect(outcome.applied.map(&:id)).to eq(%w[t1])
      expect(outcome.staged).to eq(0)

      conversation.concat((5..7).flat_map { |id| read(id, "lib/other#{id}.rb", small) })
      expect(run(conversation, rule: :turn_end, moment: :turn_end, protect_steps: 3).applied.map(&:id)).to eq(%w[t3])
    end
  end

  it "applies a later layer's edit saved unapplied, as staged" do
    conversation = session
    Samagotchi::LLMContextEdit.store(conversation[3], Samagotchi::LLMContextEdit.new(
      id: "t1", kind: :stale, note: "kept for later", by: "chi",
      staged_at: now, applied_at: nil
    ))

    outcome = run(conversation, rule: :turn_end, moment: :turn_end, protect_steps: 3)

    expect(outcome.applied.map { |edit| [edit.id, edit.note] }).to eq([["t1", "kept for later"]])
  end

  it "keeps the entries it doesn't apply to, and replaces an entry's edits Hash, never changes it" do
    conversation = session
    shared = { "t9" => { "kind" => "stale", "note" => "x", "applied_at" => now } }
    conversation[3][:edits] = shared

    run(conversation, rule: :next_request)

    expect(shared.keys).to eq(%w[t9])
    expect(conversation[3][:edits].keys).to eq(%w[t9 t1])
  end
end
