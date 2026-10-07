# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "samagotchi/tool_ids"
require "samagotchi/session"

RSpec.describe Samagotchi::ToolIds do
  def native(content, ids: nil)
    { role: "tool_response", content: content, tool_ids: ids }.compact
  end

  describe ".next_ids" do
    it "starts at t1 in a conversation without ids" do
      expect(described_class.next_ids([{ role: "user", content: "hi" }], 2)).to eq(%w[t1 t2])
    end

    it "goes one past the highest stored id, whatever the order, ignoring derived and foreign ids" do
      conversation = [native("[read] a", ids: %w[t7]), native("[read] b", ids: %w[t3 t9]),
                      native("[read] legacy"), { role: "user", content: "x", tool_ids: %w[t99] },
                      native("[read] c", ids: %w[e2.1 x5])]

      expect(described_class.next_ids(conversation, 1)).to eq(%w[t10])
    end
  end

  describe ".refs" do
    it "gives the stored ids, not derived" do
      refs = described_class.refs(native("[read] a\n\n---\n\n[write] b", ids: %w[t4 t5]), 3)

      expect(refs.map(&:id)).to eq(%w[t4 t5])
      expect(refs.map(&:run)).to eq([0, 1])
      expect(refs).to all(satisfy { |ref| !ref.derived? })
    end

    it "derives a legacy native entry's ids from its index and each run's place, marked derived" do
      content = "[read] a\n\n---\n\n[execute]\nb\n\n---\n\nmore of b\n\n---\n\n[write] c"
      refs = described_class.refs(native(content), 12)

      expect(refs.map(&:id)).to eq(%w[e12.1 e12.2 e12.3])
      expect(refs).to all(be_derived)
    end

    it "derives one id for a legacy chat result, whatever its text holds" do
      entry = { role: "tool_response", content: "[read] a\n\n---\n\n[write] b", tool_call_id: "c1" }

      expect(described_class.refs(entry, 4).map(&:id)).to eq(%w[e4.1])
    end

    it "derives one id for an empty legacy entry" do
      expect(described_class.refs(native(""), 2).map(&:id)).to eq(%w[e2.1])
    end
  end

  it "keeps tool_ids through a session's save and load" do
    Dir.mktmpdir do |dir|
      session = Samagotchi::Session.new_session(mode: "repl", model_name: "m", working_directory: dir)
      session.messages = [{ role: "user", content: "go" }, { role: "model", content: "calls" },
                          native("[read] a\n\n---\n\n[write] b", ids: %w[t1 t2]),
                          { role: "tool_response", content: "[read] c", tool_call_id: "c1", tool_ids: %w[t3] }]
      session.save(state_dir: dir)

      loaded = Samagotchi::Session.load(session.id, state_dir: dir)

      expect(loaded.messages[2][:tool_ids]).to eq(%w[t1 t2])
      expect(loaded.messages[3][:tool_ids]).to eq(%w[t3])
      expect(described_class.next_ids(loaded.messages, 1)).to eq(%w[t4])
    end
  end
end
