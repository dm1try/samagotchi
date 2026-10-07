# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm_context_apply"
require "samagotchi/kernel_loop"
require "samagotchi/llm/chat_loop"
require "tmpdir"
require_relative "support/fake_chat_adapter"
require_relative "support/test_kernel"

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

  describe "in the loops" do
    let(:dir) { Dir.mktmpdir("chi-apply") }
    let(:file) { File.join(dir, "cart.rb").tap { |path| File.write(path, "#{big}\n") } }
    let(:others) { (1..3).map { |n| File.join(dir, "o#{n}.rb").tap { |path| File.write(path, "x\n") } } }

    after { FileUtils.remove_entry(dir) }

    def strategy(rule, protect_steps: 3, stale_edits: true)
      Samagotchi::LLMContextStrategy::Resolved.new(layers: [:stale], strategy: [:stale], source: :config, apply: rule,
                                                   protect_steps: protect_steps, stale_edits: stale_edits)
    end

    def qwen_call(name, params)
      body = params.map { |key, value| "<parameter=#{key}>\n#{value}\n</parameter>" }.join("\n")
      "<tool_call>\n<function=#{name}>\n#{body}\n</function>\n</tool_call>"
    end

    def under(kernel, llm_context)
      kernel.turn_settings = Samagotchi::LLM::TurnSettings.none.with(llm_context: llm_context)
      kernel
    end

    # The native loop on +steps+ (the model's answers in order): the prompts sent, the result, the kernel.
    def native(llm_context, steps)
      sent = []
      client = test_client
      allow(client).to receive(:complete) do |prompt, on_chunk: nil, **|
        sent << prompt
        text = steps.shift
        on_chunk&.call(content: text, payload: { "content" => text })
        text
      end
      kernel = under(test_kernel(client: client, profile: Samagotchi::ModelProfile.qwen36), llm_context)
      [sent, kernel.run([head, { role: "user", content: "go" }], max_iterations: 10), kernel]
    end

    def read_twice = [qwen_call("read", "path" => file), qwen_call("read", "path" => file), "Done."]

    def stub_line = "[read] #{file}: superseded by a later read"

    it "next_request: the stub reaches the request after the second read" do
      sent, = native(strategy(:next_request), read_twice)

      expect(sent.map { |prompt| prompt.include?(stub_line) }).to eq([false, false, true])
    end

    it "rebases the turn's context estimate on the request that sends an applied batch" do
      edited = 0
      allow_any_instance_of(Samagotchi::ContextStatus).to receive(:edited!).and_wrap_original do |original|
        edited += 1
        original.call
      end

      native(strategy(:next_request), read_twice)

      expect(edited).to eq(1)
    end

    it "turn_end: no request of the turn has it; the turn's result does, and the warm-up warms it" do
      sent, result, kernel = native(strategy(:turn_end), read_twice)

      expect(sent.none? { |prompt| prompt.include?(stub_line) }).to be(true)
      first = result.conversation.find { |entry| entry[:role] == "tool_response" }
      expect(Samagotchi::LLMContextEdit.on(first).values.map(&:applied?)).to eq([true])
      expect(kernel.warmup_prompt(result.conversation, llm_context: strategy(:turn_end)).first).to include(stub_line)
    end

    it "payoff: holds a read-driven stub back (its tail is longer) until turn end" do
      sent, result, = native(strategy(:payoff), read_twice)

      expect(sent.none? { |prompt| prompt.include?(stub_line) }).to be(true)
      expect(result.conversation.count { |entry| entry.key?(:edits) }).to eq(1)
    end

    it "payoff: applies an edit-driven stub mid-turn once protect_steps have passed and it frees more than the tail" do
      steps = [qwen_call("read", "path" => file),
               qwen_call("edit", "path" => file, "old_text" => "1: line 1 of the cart", "new_text" => "1: one"),
               *others.map { |other| qwen_call("read", "path" => other) }, "Done."]
      stub = "[read] #{file}: superseded by a later edit"

      sent, = native(strategy(:payoff), steps)

      expect(sent.map { |prompt| prompt.include?(stub) }).to eq([false, false, false, false, false, true])
    end

    it "stubs no read an edit superseded with stale_edits off (the default)" do
      steps = [qwen_call("read", "path" => file),
               qwen_call("edit", "path" => file, "old_text" => "1: line 1 of the cart", "new_text" => "1: one"), "Done."]

      _, result, = native(strategy(:turn_end, protect_steps: 0, stale_edits: false), steps)

      expect(result.conversation.count { |entry| entry.key?(:edits) }).to eq(0)
    end

    it "leaves a turn that ran out of steps on an empty-answer retry as it was (not answered)" do
      _, result, = native(strategy(:turn_end), [qwen_call("read", "path" => file), qwen_call("read", "path" => file), "", ""])
      expect(result.conversation.count { |entry| entry.key?(:edits) }).to eq(1)

      sent = []
      client = test_client
      steps = [qwen_call("read", "path" => file), qwen_call("read", "path" => file), ""]
      allow(client).to receive(:complete) do |prompt, on_chunk: nil, **|
        sent << prompt
        text = steps.shift || ""
        on_chunk&.call(content: text, payload: { "content" => text })
        text
      end
      kernel = under(test_kernel(client: client, profile: Samagotchi::ModelProfile.qwen36), strategy(:turn_end))
      cut_short = kernel.run([head, { role: "user", content: "go" }], max_iterations: 3)

      expect(cut_short.conversation.count { |entry| entry.key?(:edits) }).to eq(0)
    end

    it "keeps the latest read of a file the last steps edited, at turn end too" do
      steps = [qwen_call("read", "path" => file),
               qwen_call("edit", "path" => file, "old_text" => "1: line 1 of the cart", "new_text" => "1: one"), "Done."]

      _, kept, = native(strategy(:turn_end), steps.dup)
      File.write(file, "#{big}\n")
      _, stubbed, = native(strategy(:turn_end, protect_steps: 0), steps)

      expect(kept.conversation.count { |entry| entry.key?(:edits) }).to eq(0)
      expect(stubbed.conversation.count { |entry| entry.key?(:edits) }).to eq(1)
    end

    it "leaves a turn that ran out of steps mid-task as it was" do
      _, result, = native(strategy(:turn_end), read_twice)
      expect(result.conversation.count { |entry| entry.key?(:edits) }).to eq(1)

      sent = []
      client = test_client
      allow(client).to receive(:complete) do |prompt, on_chunk: nil, **|
        sent << prompt
        text = qwen_call("read", "path" => file)
        on_chunk&.call(content: text, payload: { "content" => text })
        text
      end
      kernel = under(test_kernel(client: client, profile: Samagotchi::ModelProfile.qwen36), strategy(:turn_end))
      exhausted = kernel.run([head, { role: "user", content: "go" }], max_iterations: 3)

      expect(exhausted).to be_exhausted
      expect(exhausted.conversation.count { |entry| entry.key?(:edits) }).to eq(0)
    end

    describe "the chat loop" do
      def chat(llm_context)
        adapter = FakeChatAdapter.new(FakeChatAdapter.tools(["c1", "read", { "path" => file }]),
                                      FakeChatAdapter.tools(["c2", "read", { "path" => file }]),
                                      FakeChatAdapter.text("Done."))
        result = Samagotchi::LLM::ChatLoop.new(kernel: under(test_kernel, llm_context), adapter: adapter)
                                          .complete(messages: [head, { role: "user", content: "go" }], model_name: "m",
                                                    max_iterations: 5)
        stubbed = adapter.requests.map do |request|
          request[:messages].any? { |message| message[:tool_call_id] == "c1" && message[:content] == stub_line }
        end
        [stubbed, result]
      end

      it "estimates the context from what the view sends: a stub counts, not the output it stands for" do
        observed = []
        allow_any_instance_of(Samagotchi::ContextStatus).to receive(:observe).and_wrap_original do |original, chars, **opts|
          observed << chars
          original.call(chars, **opts)
        end

        chat(strategy(:next_request))
        stubbed = observed.dup
        observed.clear
        chat(nil)

        expect(stubbed.last).to be < observed.last - big.length + 200
      end

      it "sends the stub from the next request under next_request, and only from the next turn under turn_end" do
        expect(chat(strategy(:next_request)).first).to eq([false, false, true])

        stubbed, result = chat(strategy(:turn_end))
        expect(stubbed).to eq([false, false, false])
        wire = Samagotchi::LLM::ChatLoop.new(kernel: under(test_kernel, strategy(:turn_end)), adapter: FakeChatAdapter.new)
                                        .wire_messages(result.conversation)
        expect(wire.find { |message| message[:tool_call_id] == "c1" }[:content]).to eq(stub_line)
      end
    end
  end
end
