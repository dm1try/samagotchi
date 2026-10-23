# frozen_string_literal: true

require "spec_helper"
require "samagotchi/working_set_steer"
require "samagotchi/prompt"

RSpec.describe Samagotchi::WorkingSetSteer do
  let(:now) { "2026-10-23T10:00:00.000Z" }
  let(:root) { "/work/shop" }
  let(:cart) { "/work/shop/lib/cart.rb" }
  let(:head) { { role: "system", content: "You are chi." } }
  let(:body) { (1..40).map { |n| "#{n}: line #{n} of the cart" }.join("\n") }

  def chat_model(id, name, args) = { role: "model", content: "", tool_calls: [{ id: id, name: name, arguments: args }] }

  def chat_result(id, name, text, tool_id, edits: nil)
    { role: "tool_response", content: "[#{name}]\n#{text}", tool_call_id: id, tool_ids: [tool_id], edits: edits }.compact
  end

  def read_turn(path, id, tool_id, **options)
    [chat_model(id, "read", { "path" => path }), chat_result(id, "read", body, tool_id, **options)]
  end

  def target(word) = described_class.target(word, cwd: root)
  def drop(conversation, word, strategy: :none) = described_class.drop(conversation, target(word), strategy: strategy, cwd: root, now: now)

  def undrop(conversation, word, strategy: :none, sent: true)
    described_class.undrop(conversation, target(word), strategy: strategy, cwd: root, sent: sent)
  end

  def states(conversation, strategy: :none)
    Samagotchi::WorkingSet.build(conversation, cwd: root, strategy: strategy, stat: ->(_) { raise Errno::ENOENT })
                          .items.to_h { |item| [item.key, item.state] }
  end

  def refusal(&) = expect(&).to(raise_error(described_class::Refused))

  describe ".target" do
    it "reads a path (the session's folder's or absolute), memory:NAME and a URL" do
      expect(target("lib/cart.rb")).to have_attributes(kind: "file", key: cart, label: "lib/cart.rb")
      expect(target("/etc/hosts")).to have_attributes(kind: "file", key: "/etc/hosts", label: "/etc/hosts")
      expect(target("memory:style")).to have_attributes(kind: "memory", key: "style", label: "memory style")
      expect(target("https://x.dev/a")).to have_attributes(kind: "url", key: "https://x.dev/a")
    end
  end

  describe ".drop" do
    it "saves an applied user drop on every sent output of the item, and the view sends the stubs under none" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1"), *read_turn(cart, "c2", "t2")]

      done = drop(conversation, "lib/cart.rb")

      expect(done).to have_attributes(op: "drop", ids: %w[t1 t2], free: false)
      expect(done.freed_chars).to be > 0
      expect(done.tail_chars).to be > 0
      edit = Samagotchi::LLMContextEdit.on(conversation[2])["t1"]
      expect(edit).to have_attributes(kind: :drop, by: "user", applied_at: now, was: nil)
      sent = Samagotchi::LLMContextView.new.messages(conversation)
      expect(sent[2][:content]).to eq("[read] #{Samagotchi::LLMContextEdit::DROP_STUB}")
      expect(states(conversation)).to eq(cart => "dropped")
    end

    it "stays dropped through a strategy switch" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1")]
      drop(conversation, "lib/cart.rb")

      expect(states(conversation, strategy: %i[stale forget])).to eq(cart => "dropped")
    end

    it "keeps the edit an output held (a forget, sent whole under none) and undrop puts it back" do
      forget = { "kind" => "forget", "note" => "totals", "by" => "model", "staged_at" => now, "applied_at" => now }
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1", edits: { "t1" => forget })]

      drop(conversation, "lib/cart.rb")
      expect(conversation[2][:edits]["t1"]).to include("kind" => "drop", "was" => forget)

      done = undrop(conversation, "lib/cart.rb")
      expect(done).to have_attributes(op: "undrop", ids: %w[t1], free: false)
      expect(done.tail_chars).to be > 0
      expect(conversation[2][:edits]).to eq("t1" => forget)
    end

    it "is refused with WorkingSetSteer::Refused's words: edit-only, unknown, derived, already dropped, not sent" do
      edited = [head, chat_model("c1", "write", { "path" => "lib/new.rb", "content" => "x" }),
                chat_result("c1", "write", "Wrote", "t1")]
      legacy = [head, chat_model("c1", "read", { "path" => "lib/cart.rb" }),
                { role: "tool_response", content: "[read]\n#{body}", tool_call_id: "c1" }]
      forgotten = [head, *read_turn("lib/cart.rb", "c1", "t1", edits: { "t1" => { "kind" => "forget", "note" => "x", "by" => "model",
                                                                                  "staged_at" => now, "applied_at" => now } })]
      dropped = [head, *read_turn("lib/cart.rb", "c1", "t1")]
      drop(dropped, "lib/cart.rb")

      { [edited, "lib/new.rb", :none] => :only_edited, [edited, "lib/other.rb", :none] => :not_in_set,
        [legacy, "lib/cart.rb", :none] => :derived, [dropped, "lib/cart.rb", :none] => :already_dropped,
        [forgotten, "lib/cart.rb", %i[forget]] => :not_sent }.each do |(conversation, word, strategy), reason|
        expect { drop(conversation, word, strategy: strategy) }.to raise_error(described_class::Refused) { |e|
          expect(e.reason).to eq(reason)
          expect(e.message).to eq(described_class::Refused.text(reason))
        }
      end
    end
  end

  describe ".undrop" do
    it "takes the drop off; free when it never reached a request" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1")]
      drop(conversation, "lib/cart.rb")

      done = undrop(conversation, "lib/cart.rb", sent: false)

      expect(done).to have_attributes(free: true, tail_chars: 0)
      expect(conversation[2]).not_to have_key(:edits)
      expect(Samagotchi::LLMContextView.new.messages(conversation)).to equal(conversation)
    end

    it "refuses an item not dropped, or not in the set" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1")]

      expect { undrop(conversation, "lib/cart.rb") }.to raise_error(described_class::Refused, "not dropped")
      expect { undrop(conversation, "lib/x.rb") }.to raise_error(described_class::Refused, "not in the working set")
    end
  end

  describe ".pin and .unpin" do
    let(:pins) { [Samagotchi::WorkingSetPin.new(kind: "file", key: cart)] }

    def pin(conversation, word, pins: []) = described_class.pin(conversation, pins, target(word), strategy: :none, cwd: root)

    it "pins an item of the set (its outputs' ids), changing nothing sent; unpin takes it off" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1"), *read_turn(cart, "c2", "t2")]
      before = conversation.map(&:dup)

      done = pin(conversation, "lib/cart.rb")

      expect(done).to have_attributes(op: "pin", ids: %w[t1 t2], free: true, undone: nil)
      expect(conversation).to eq(before)
      expect(described_class.pinning([], done)).to eq(pins)
      expect(described_class.pinning(pins, described_class.unpin(pins, target("lib/cart.rb")))).to eq([])
    end

    it "refuses with WorkingSetSteer::Refused's words: not in the set, already pinned, not pinned, a sent drop" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1")]

      expect { pin(conversation, "lib/x.rb") }.to raise_error(described_class::Refused, "not in the working set")
      expect { pin(conversation, "lib/cart.rb", pins: pins) }.to raise_error(described_class::Refused, "already pinned")
      expect { described_class.unpin([], target("lib/cart.rb")) }.to raise_error(described_class::Refused, "not pinned")
      # A drop sent (no pending note): undrop it first.
      drop(conversation, "lib/cart.rb")
      expect { pin(conversation, "lib/cart.rb") }
        .to raise_error(described_class::Refused, described_class::Refused.text(:undrop_first))
    end

    it "takes a pending drop off first (free), and a drop of a pinned item asks for an unpin first" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1")]
      messages = described_class.record!(conversation, drop(conversation, "lib/cart.rb"))

      done = pin(messages, "lib/cart.rb")

      expect(done.undone).to have_attributes(op: "undrop", ids: %w[t1], free: true)
      expect(states(messages)).to eq(cart => "live")
      expect(described_class.pending_ops(described_class.record!(messages, done.undone))).to eq([])
      expect { described_class.drop(messages, target("lib/cart.rb"), strategy: :none, cwd: root, pins: pins) }
        .to raise_error(described_class::Refused, "pinned by the user: unpin it first")
    end

    it "notes a pin and an unpin; an unpin of a pending pin cancels both" do
      conversation = [head, *read_turn("lib/cart.rb", "c1", "t1"), *read_turn("lib/tax.rb", "c2", "t2")]
      messages = described_class.record!(conversation, pin(conversation, "lib/cart.rb"))
      messages = described_class.record!(messages, described_class.unpin([Samagotchi::WorkingSetPin.new(kind: "file", key: "/work/shop/lib/tax.rb")],
                                                                         target("lib/tax.rb")))

      expect(messages.last[:content]).to eq("[WORKING SET: since your last turn the user pinned lib/cart.rb: forget_outputs " \
                                            "won't forget it; the user unpinned lib/tax.rb: you may forget it again.]")
      messages = described_class.record!(messages, described_class.unpin(pins, target("lib/cart.rb")))
      expect(described_class.pending_ops(messages).map { |op| op["op"] }).to eq(%w[unpin])
    end
  end

  describe "the tail note" do
    let(:conversation) { [head, { role: "user", content: "go" }, *read_turn("lib/cart.rb", "c1", "t1"), { role: "model", content: "done" }] }

    it "lists the ops since the last turn in one escaped system note; an inverse op cancels its op" do
      messages = described_class.record!(conversation, drop(conversation, "lib/cart.rb"))
      note = messages.last

      expect(messages.size).to eq(conversation.size + 1)
      expect(note).to include(role: "system", kind: "working_set")
      expect(note[:content]).to start_with("[WORKING SET: since your last turn the user dropped lib/cart.rb")
      expect(Samagotchi::Prompt::ESCAPED_KINDS).to include("working_set")
      expect(described_class.pending?(messages, "drop", target("lib/cart.rb"))).to be(true)

      back = described_class.record!(messages, undrop(messages, "lib/cart.rb", sent: false))
      expect(back).to eq(conversation)
    end

    it "is one note per turn: a later op joins it, behind other tail notes; after a turn a new one starts" do
      conversation.insert(-2, *read_turn("lib/tax.rb", "c2", "t2"))
      messages = described_class.record!(conversation, drop(conversation, "lib/cart.rb"))
      messages << { role: "system", kind: "note", content: "[CONTEXT NOTE]" }
      messages = described_class.record!(messages, drop(messages, "lib/tax.rb"))

      expect(messages.count { |m| m[:kind] == "working_set" }).to eq(1)
      expect(described_class.pending_ops(messages).map { |op| op["label"] }).to eq(%w[lib/cart.rb lib/tax.rb])

      after = messages + [{ role: "user", content: "next" }, { role: "model", content: "ok" }]
      expect(described_class.pending_note_index(after)).to be_nil
      undone = described_class.record!(after, undrop(after, "lib/cart.rb"))
      expect(undone.last[:content]).to include("the user brought back lib/cart.rb")
      expect(undone.count { |m| m[:kind] == "working_set" }).to eq(2)
    end
  end
end
