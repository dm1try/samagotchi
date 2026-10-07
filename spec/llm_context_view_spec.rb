# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm_context_view"
require "samagotchi/llm_context_strategy"
require "samagotchi/kernel_loop"
require "samagotchi/model_profile"
require "samagotchi/llm/chat_loop"
require "samagotchi/session"
require "tmpdir"
require_relative "support/fake_chat_adapter"
require_relative "support/test_kernel"

RSpec.describe Samagotchi::LLMContextView do
  let(:conversation) do
    [{ role: "system", content: "base" }, { role: "user", content: "hi" },
     { role: "model", content: "<|tool_call>call:read{}<tool_call|>" },
     { role: "tool_response", content: "[read] lib/x.rb\n1: x", tool_ids: ["t1"] }]
  end

  it "is none by default, and under none returns the conversation it was given" do
    view = described_class.new

    expect(view).to be_none
    expect(view.messages(conversation)).to equal(conversation)
    expect(view.messages(conversation).map(&:object_id)).to eq(conversation.map(&:object_id))
  end

  # A view that records what it was asked for, and the formatter's input:
  # under none the formatter gets the very Array the view was given.
  def spy_view(kernel)
    seen = []
    view = described_class.new
    allow(view).to receive(:messages).and_wrap_original do |original, messages|
      seen << messages
      original.call(messages)
    end
    allow(kernel).to receive(:llm_context_view).and_return(view)
    seen
  end

  def formatted_inputs
    inputs = []
    allow(Samagotchi::Prompt).to receive(:format_with_images).and_wrap_original do |original, messages, **options|
      inputs << messages
      original.call(messages, **options)
    end
    inputs
  end

  describe "the native loop" do
    let(:client) { instance_double(Samagotchi::Client) }
    let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.qwen36) }

    before do
      allow(client).to receive(:complete) do |_prompt, on_chunk: nil, **|
        on_chunk&.call(content: "Answer", payload: { "content" => "Answer" })
        "Answer"
      end
    end

    it "formats every request's prompt from the view's messages, unchanged under none" do
      seen = spy_view(kernel)
      inputs = formatted_inputs

      kernel.run(conversation.first(2))

      expect(seen).not_to be_empty
      expect(inputs.length).to eq(seen.length)
      inputs.zip(seen).each { |input, viewed| expect(input).to equal(viewed) }
    end

    it "formats the turn-end warm-up from the view's messages too" do
      first = kernel.run(conversation.first(2))
      seen = spy_view(kernel)
      inputs = formatted_inputs

      kernel.warmup_prompt(first.conversation)

      expect(seen.length).to eq(1)
      expect(inputs).to eq(seen)
      expect(inputs.first).to equal(seen.first)
    end

    it "formats the warm-up under the strategy it is given (the next turn's), not the last turn's" do
      kernel.run(conversation.first(2))
      stale = Samagotchi::LLMContextStrategy::Resolved.new(layers: [:stale], strategy: [:stale], source: :model_setting)
      edits = { "t1" => { "kind" => "stale", "note" => "lib/x.rb: superseded by a later edit", "by" => "chi",
                          "staged_at" => "now", "applied_at" => "now" } }
      messages = conversation + [{ role: "model", content: "Read it." }]
      messages[3] = messages[3].merge(edits: edits)

      under_none, = kernel.warmup_prompt(messages)
      under_stale, = kernel.warmup_prompt(messages, llm_context: stale)

      expect(under_none).to include("[read] lib/x.rb\n1: x")
      expect(under_stale).to include("[read] lib/x.rb: superseded by a later edit")
      expect(under_stale).not_to include("1: x")
    end

    it "runs under the turn's strategy (TurnSettings#llm_context), none without one" do
      expect(kernel.llm_context_view).to be_none
      resolved = Samagotchi::LLMContextStrategy::Resolved.new(layers: [:stale], strategy: [:stale], source: :config)
      kernel.turn_settings = Samagotchi::LLM::TurnSettings.none.with(llm_context: resolved)

      expect(kernel.llm_context_view.layers).to eq([:stale])
    end
  end

  describe "the chat loop" do
    let(:kernel) { test_kernel }
    let(:backend) do
      Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(FakeChatAdapter.text("hello back")))
    end

    it "builds the wire messages from the view's messages, the same as without it under none" do
      plain = backend.wire_messages(conversation)
      seen = spy_view(kernel)

      expect(backend.wire_messages(conversation)).to eq(plain)
      expect(seen).to eq([conversation])
      expect(seen.first).to equal(conversation)
    end
  end

  describe "a strategy's edits" do
    let(:now) { "2026-10-07T18:00:00.000+02:00" }
    let(:batch) do
      { role: "tool_response",
        content: "[read] lib/x.rb\n1: x\n\n---\n\n[shot] two images\n\n---\n\n[execute]\nok\n\n---\n\nstill ok",
        images: [{ file: "a.png", name: "a.png" }, { file: "b.png", name: "b.png" }, { file: "c.png", name: "c.png" }],
        image_counts: [1, 2, 0],
        tool_ids: %w[t1 t2 t3] }
    end

    def edit(kind, note, applied: true)
      { "kind" => kind, "note" => note, "by" => "chi", "staged_at" => now, "applied_at" => applied ? now : nil }
    end

    it "sends an applied edit's run as its stub, keeping its [name] lead, the other runs as they are" do
      entry = batch.merge(edits: { "t1" => edit("stale", "lib/x.rb 1-1: superseded by t9") })
      sent = described_class.new(strategy: [:stale]).messages([entry]).first

      expect(sent[:content]).to eq("[read] lib/x.rb 1-1: superseded by t9\n\n---\n\n[shot] two images\n\n---\n\n" \
                                   "[execute]\nok\n\n---\n\nstill ok")
      expect(sent[:images].map { |image| image[:file] }).to eq(%w[b.png c.png])
      expect(sent[:image_counts]).to eq([0, 2, 0])
      expect(sent[:tool_ids]).to eq(%w[t1 t2 t3])
      expect(entry[:content]).to start_with("[read] lib/x.rb\n1: x")
    end

    it "drops a stubbed run's images, and the images keys once none are left" do
      entry = batch.merge(edits: { "t2" => edit("forget", "two screenshots of the login page"),
                                   "t1" => edit("forget", "x is one line") })
      sent = described_class.new(strategy: %i[stale forget]).messages([entry]).first

      expect(sent).not_to have_key(:images)
      expect(sent).not_to have_key(:image_counts)
      expect(Samagotchi::ToolResponse.split(sent[:content]).map(&:name)).to eq(%w[read shot execute])
      expect(sent[:content]).to include("[shot] [#t2] (forgotten) two screenshots of the login page [restore: t2]")
    end

    it "keeps the Gemma prompt's response:NAME blocks, and an image line only for the runs not stubbed" do
      entry = batch.merge(edits: { "t2" => edit("stale", "superseded") })
      messages = [{ role: "user", content: "go" }, { role: "model", content: "<|tool_call>call:read{}<tool_call|>" }, entry]
      prompt, = Samagotchi::Prompt.format_with_images(described_class.new(strategy: [:stale]).messages(messages),
                                                      profile: Samagotchi::ModelProfile.gemma4)

      expect(prompt.scan(/response:(\w+)\{/).flatten).to eq(%w[read shot execute])
      expect(prompt).to include('response:shot{value:<|"|>superseded<|"|>}')
      expect(prompt.scan("[image ").size).to eq(1)
      expect(prompt).to include("[image a.png")
    end

    it "sends an edit that isn't applied yet, or of a layer not on, and every edit under none, as the original" do
      staged = batch.merge(edits: { "t1" => edit("stale", "superseded", applied: false) })
      other = batch.merge(edits: { "t1" => edit("forget", "gone") })
      conversation = [staged, other]

      expect(described_class.new(strategy: [:stale]).messages(conversation)).to eq(conversation)
      expect(described_class.new.messages(conversation)).to equal(conversation)
    end

    it "sends an entry whole when its runs don't match its ids, or its images can't be told apart" do
      short = batch.merge(tool_ids: %w[t1 t2], edits: { "t1" => edit("stale", "superseded") })
      uncounted = batch.except(:image_counts).merge(edits: { "t1" => edit("stale", "superseded") })
      view = described_class.new(strategy: [:stale])

      expect(view.messages([short]).first).to equal(short)
      expect(view.messages([uncounted]).first).to equal(uncounted)
    end

    it "stubs a legacy entry's run by its derived id, the same with or without the system head" do
      legacy = { role: "tool_response", content: "[read] a\n\n---\n\n[read] b",
                 edits: { "e3.2" => edit("stale", "superseded") } }
      stored = [{ role: "user", content: "go" }, { role: "model", content: "calls" }, legacy]
      view = described_class.new(strategy: [:stale])

      [stored, Samagotchi::ContextNote.with_system_head(stored, { role: "system", content: "base" })].each do |sent|
        expect(view.messages(sent).last[:content]).to eq("[read] a\n\n---\n\n[read] superseded")
      end
    end

    describe "with the forget layer on" do
      let(:forget) { described_class.new(strategy: %i[stale forget]) }

      def result(id, text, edits = {})
        { role: "tool_response", content: text, tool_call_id: "c#{id}", tool_ids: ["t#{id}"], edits: edits }
      end

      it "shows each stored id after its output's lead, never a legacy entry's derived one, and none under stale" do
        legacy = { role: "tool_response", content: "[read] a\n\n---\n\n[read] b" }
        conversation = [{ role: "user", content: "go" }, batch, legacy]

        sent = forget.messages(conversation)

        expect(sent[1][:content]).to eq("[read] [#t1] lib/x.rb\n1: x\n\n---\n\n[shot] [#t2] two images\n\n---\n\n" \
                                         "[execute]\n[#t3] ok\n\n---\n\nstill ok")
        expect(sent[1][:images]).to eq(batch[:images])
        expect(sent[2]).to equal(legacy)
        expect(described_class.new(strategy: [:stale]).messages(conversation)[1]).to equal(batch)
      end

      it "puts a forget's note on the first of its outputs in a row, a pointer on the rest, and a restore hint off reads" do
        one = edit("forget", "facts: x is one line")
        other = edit("forget", "another call's note").merge("staged_at" => "later")
        conversation = [result(1, "[read] a", "t1" => one), result(2, "[execute]\nok", "t2" => one),
                        result(3, "[execute]\nkept"), result(4, "[execute]\nagain", "t4" => one),
                        result(5, "[execute]\nmore", "t5" => one), result(6, "[read] b", "t6" => other)]

        sent = forget.messages(conversation).map { |entry| entry[:content] }

        expect(sent).to eq(["[read] [#t1] (forgotten) facts: x is one line",
                            "[execute] [#t2] (forgotten with t1: see its note) [restore: t2]",
                            "[execute]\n[#t3] kept",
                            "[execute] [#t4] (forgotten) facts: x is one line [restore: t4]",
                            "[execute] [#t5] (forgotten with t4: see its note) [restore: t5]",
                            "[read] [#t6] (forgotten) another call's note"])
      end

      it "sends a forget's kept lines under its stub, a range past the output's end cut to it" do
        kept = edit("forget", "the spec's setup").merge("keep" => [[2, 3], [5, 99], [40, 50]])
        text = "[read]\nline 1\nline 2\nline 3\nline 4\nline 5\nline 6\n"

        sent = forget.messages([result(1, text, "t1" => kept)]).first[:content]

        expect(sent).to eq("[read] [#t1] (forgotten) the spec's setup\nlines 2-3 kept:\nline 2\nline 3\n" \
                           "lines 5-6 kept:\nline 5\nline 6")
      end
    end

    it "keeps a chat call and its result paired: the stub goes as the tool message's content" do
      kernel = test_kernel
      backend = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new)
      call = { role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: { "path" => "x" } }] }
      result = { role: "tool_response", content: "[read] lib/x.rb\n1: x", tool_call_id: "c1", tool_ids: %w[t5],
                 images: [{ file: "a.png" }], edits: { "t5" => edit("forget", "x is one line") } }
      allow(kernel).to receive(:llm_context_view).and_return(described_class.new(strategy: [:forget]))

      wire = backend.wire_messages([{ role: "user", content: "go" }, call, result])

      expect(wire[1][:tool_calls].map { |c| c[:id] }).to eq(["c1"])
      expect(wire[2]).to eq(role: "tool", content: "[read] [#t5] (forgotten) x is one line", tool_call_id: "c1")
      expect(wire.size).to eq(3)
    end
  end
end

RSpec.describe Samagotchi::LLMContextEdit do
  let(:saved) do
    { "kind" => "forget", "note" => "x is one line", "by" => "model", "staged_at" => "2026-10-07T18:00:00.000+02:00",
      "applied_at" => nil }
  end

  it "reads an edit as saved, string or symbol keys, and writes it back the same" do
    edit = described_class.from_h("t4", saved)

    expect(edit).to have_attributes(id: "t4", kind: :forget, note: "x is one line", by: "model")
    expect(edit).not_to be_applied
    expect(edit.to_h).to eq(saved)
    expect(described_class.from_h(:t4, saved.transform_keys(&:to_sym))).to eq(edit)
  end

  it "stores an edit in a new edits Hash, so a shallow copy of the entry (a checkpoint, a fork) keeps its own" do
    entry = { role: "tool_response", content: "[read] a", tool_ids: %w[t1 t2], edits: { "t1" => saved } }
    checkpoint = entry.dup
    stale = described_class.new(id: "t2", kind: :stale, note: "superseded by t9", by: "chi", staged_at: "now",
                                applied_at: nil)

    expect(described_class.store(entry, stale)).to equal(entry)
    expect(described_class.on(entry).keys).to eq(%w[t1 t2])
    expect(described_class.on(checkpoint).keys).to eq(%w[t1])
  end

  it "saves a forget's kept line ranges only when it has some, reads back only well-formed ones, and removes an edit" do
    kept = described_class.from_h("t4", saved.merge("keep" => [[3, 9], [5, 2], [0, 1], "x", [1, 1]]))

    expect(kept.keep).to eq([[3, 9], [1, 1]])
    expect(kept.to_h).to eq(saved.merge("keep" => [[3, 9], [1, 1]]))
    expect(described_class.from_h("t4", saved).to_h).not_to have_key("keep")

    entry = { role: "tool_response", edits: { "t4" => saved, "t5" => saved } }
    shared = entry[:edits]
    described_class.remove(entry, "t4")
    expect(entry[:edits].keys).to eq(%w[t5])
    expect(shared.keys).to eq(%w[t4 t5])
    expect(described_class.remove(entry, "t5")).not_to have_key(:edits)
  end

  it "skips an edit of no known kind" do
    entry = { role: "tool_response", edits: { "t1" => saved.merge("kind" => "summarize"), "t2" => saved, "t3" => "x" } }

    expect(described_class.on(entry).keys).to eq(%w[t2])
    expect(described_class.on({ role: "tool_response" })).to eq({})
  end

  it "keeps an entry's edits through a session's save and load, and the chat loop's plain copy" do
    Dir.mktmpdir do |dir|
      session = Samagotchi::Session.new_session(mode: "repl", model_name: "m", working_directory: dir)
      session.messages = [{ role: "tool_response", content: "[read] a", tool_ids: %w[t2], edits: { "t2" => saved } }]
      session.save(state_dir: dir)

      loaded = Samagotchi::Session.load(session.id, state_dir: dir).messages.first

      expect(described_class.on(loaded)).to eq("t2" => described_class.from_h("t2", saved))
      expect(Samagotchi::LLM::ChatLoop.new(kernel: test_kernel).plain([loaded]).first[:edits]).to eq("t2" => saved)
    end
  end
end
