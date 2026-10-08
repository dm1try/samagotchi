# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/llm_context_forget"
require "samagotchi/llm_context_strategy"
require "samagotchi/kernel_loop"
require "samagotchi/model_profile"
require "samagotchi/llm/chat_loop"
require_relative "support/fake_chat_adapter"
require_relative "support/test_kernel"

RSpec.describe Samagotchi::LLMContextForget do
  let(:dir) { Dir.mktmpdir("chi-forget") }
  let(:now) { "2026-10-07T20:00:00.000Z" }
  let(:log) { (1..30).map { |n| "spec line #{n}: ok" }.join("\n") }
  let(:source) { (1..40).map { |n| "line #{n} of a.rb" }.join("\n") }

  after { FileUtils.remove_entry(dir) }

  # One step of a chat session: the model's call and its result, with id t<n>.
  def step(n, name, args, output)
    [{ role: "model", content: "", tool_calls: [{ id: "c#{n}", name: name, arguments: args }] },
     { role: "tool_response", content: "[#{name}]\n#{output}", tool_call_id: "c#{n}", tool_ids: ["t#{n}"] }]
  end

  # Steps 1-5 (t1 a read of a.rb, t2 a spec run, t3 a read of b.rb, t4 an
  # edit of b.rb, t5 a listing), then step 6: the forget call itself.
  def conversation
    [{ role: "system", content: "base" }, { role: "user", content: "fix it" },
     *step(1, "read", { "path" => File.join(dir, "a.rb") }, source),
     *step(2, "execute", { "command" => "bundle exec rspec" }, log),
     *step(3, "read", { "path" => File.join(dir, "b.rb") }, source),
     *step(4, "edit", { "path" => File.join(dir, "b.rb"), "old_text" => "x", "new_text" => "y" }, "edited"),
     *step(5, "execute", { "command" => "ls" }, log),
     { role: "model", content: "", tool_calls: [{ id: "c6", name: "forget_outputs", arguments: {} }] }]
  end

  def llm_context(rule = :next_request, protect_steps: 3)
    Samagotchi::LLMContextStrategy::Resolved.new(layers: %i[stale forget], strategy: %i[stale forget], source: :config,
                                                 apply: rule, protect_steps: protect_steps)
  end

  # Runs a call on +entries+ under +resolved+, the apply rule at a request.
  def forget(entries, args, resolved = llm_context, context = nil)
    apply = lambda do
      Samagotchi::LLMContextApply.run!(entries, layers: resolved.active_layers, rule: resolved.apply, moment: :request,
                                                protect_steps: resolved.protect_steps, root: dir, now: now)
    end
    call = Samagotchi::Tools::BuiltinCalls.build("forget_outputs", args)
    described_class.call(described_class::Turn.new(conversation: entries, context: context), call,
                         llm_context: resolved, apply: apply, root: dir, now: now)
  end

  def edits(entries) = entries.select { |entry| entry[:edits] }.to_h { |entry| [entry[:tool_ids].first, entry[:edits]] }

  it "saves a forget with its note on each output named, and the rule applies it (next_request: at once)" do
    entries = conversation

    result = forget(entries, "ids" => %w[t1 t2], "note" => "a.rb: no retry logic (VERIFIED). NEXT: edit b.rb")

    expect(result).to start_with("forgot t1, t2: applied, the next request sends the stubs (frees ")
    expect(edits(entries).keys).to eq(%w[t1 t2])
    saved = Samagotchi::LLMContextEdit.on(entries[3])["t1"]
    expect(saved).to have_attributes(kind: :forget, by: "model", note: "a.rb: no retry logic (VERIFIED). NEXT: edit b.rb",
                                     applied_at: now)
    sent = Samagotchi::LLMContextView.new(strategy: %i[stale forget]).messages(entries)
    expect(sent[3][:content]).to eq("[read] [#t1] (forgotten) a.rb: no retry logic (VERIFIED). NEXT: edit b.rb")
    expect(sent[5][:content]).to eq("[execute] [#t2] (forgotten with t1: see its note) [restore: t2]")
  end

  it "says a batch the rule holds back is staged until the turn ends, with what it frees then" do
    entries = conversation

    result = forget(entries, { "ids" => ["t1"], "note" => "a.rb is read" }, llm_context(:turn_end))

    expect(result).to match(/\Aforgot t1: staged until the turn ends \(the staged stubs: frees \d+ tokens then\)\z/)
    expect(Samagotchi::LLMContextEdit.on(entries[3])["t1"]).not_to be_applied
  end

  it "refuses per id: the last protect_steps steps' outputs, a read of a file they edited without keep, an unknown id" do
    entries = conversation

    result = forget(entries, { "ids" => %w[t3 t4 t5 t99 t1], "note" => "done with them" }, llm_context(protect_steps: 2))

    expect(result.lines.first).to start_with("forgot t1: applied")
    expect(result).to include("- t3: a read of a file you edited in your last 2 steps; keep the lines you edit " \
                              "against (keep: [\"t3:1-21\"]) or forget it later")
    expect(result).to include("- t4: from your last 2 steps; you may still need it, forget it later",
                              "- t5: from your last 2 steps", "- t99: no output with that id in context")
    expect(edits(entries).keys).to eq(%w[t1])
  end

  it "protects protect_steps steps of outputs before the forget's own step: 1 is the output just got" do
    entries = conversation

    expect(forget(entries, { "ids" => %w[t5], "note" => "n" }, llm_context(protect_steps: 1)))
      .to include("- t5: from your last 1 step;")
    expect(forget(entries, { "ids" => %w[t2], "note" => "n" }, llm_context(protect_steps: 1))).to start_with("forgot t2")
    expect(forget(conversation, { "ids" => %w[t3], "note" => "n" }, llm_context(protect_steps: 3)))
      .to include("- t3: from your last 3 steps")
  end

  it "pairs an output with its call by name: a shifted joined entry has no ids to forget (the reviewer's repro)" do
    sep = Samagotchi::ToolResponse::SEPARATOR
    execute = "[execute]\n#{(1..10).map { |i| "log line #{i} ......" }.join("\n")}#{sep}[x] tail of the execute output"
    read = "ran as: read b.rb\n[read]\n#{(1..10).map { |i| "def m#{i}; end" }.join("\n")}"
    entries = [{ role: "system", content: "base" }, { role: "user", content: "go" },
               { role: "model", content: "", tool_calls: [{ id: "c1", name: "execute", arguments: { "command" => "x" } },
                                                          { id: "c2", name: "read", arguments: { "path" => "b.rb" } }] },
               { role: "tool_response", content: "#{execute}#{sep}#{read}", tool_ids: %w[t1 t2] },
               *(1..5).flat_map { |n| step(10 + n, "execute", { "command" => "true" }, log) }]

    expect(forget(entries, "ids" => %w[t2], "note" => "n")).to include("- t2: no output with that id in context")
    expect(Samagotchi::LLMContextView.new(strategy: %i[stale forget]).messages(entries)[3][:content]).not_to include("[#t")
  end

  it "keeps a ranged read's lines by the file's numbers, and refuses a keep outside them or of a preview" do
    entries = [{ role: "system", content: "base" }, { role: "user", content: "fix it" },
               *step(1, "read", { "path" => "b.rb", "start_line" => 120, "end_line" => 159 }, source),
               *step(2, "read", { "path" => "c.rb" }, "truncated=true\npath=c.rb\n\n[TRUNCATED_PREVIEW_HEAD]\n#{log}"),
               { role: "model", content: "", tool_calls: [{ id: "c9", name: "forget_outputs", arguments: {} }] }]
    loose = llm_context(protect_steps: 0)

    expect(forget(entries, { "keep" => ["t1:400-410"], "note" => "n" }, loose))
      .to include("- t1: keep 400-410 is outside its lines (120-159, the file's)")
    expect(forget(entries, { "keep" => ["t2:3-5"], "note" => "n" }, loose)).to include("- t2: a preview of a big file")
    expect(forget(entries, { "keep" => ["t1:121-122"], "note" => "b.rb's head" }, loose)).to start_with("forgot t1")
    sent = Samagotchi::LLMContextView.new(strategy: %i[stale forget]).messages(entries)
    expect(sent[3][:content]).to end_with("lines 121-122 kept:\nline 2 of a.rb\nline 3 of a.rb")
  end

  it "forgets a read the model edits against when it keeps lines of it, and sends them under the stub" do
    entries = conversation

    result = forget(entries, { "keep" => ["t3:2-3"], "note" => "b.rb: only lines 2-3 matter" }, llm_context(protect_steps: 2))

    expect(result).to start_with("forgot t3: applied")
    sent = Samagotchi::LLMContextView.new(strategy: %i[stale forget]).messages(entries)
    expect(sent[7][:content]).to eq("[read] [#t3] (forgotten) b.rb: only lines 2-3 matter\nlines 2-3 kept:\n" \
                                    "line 2 of a.rb\nline 3 of a.rb")
  end

  it "refuses a keep that holds all of an output, an output forgotten already, and a call without a note or ids" do
    entries = conversation
    forget(entries, "ids" => ["t1"], "note" => "first")
    expect(forget(entries, { "ids" => %w[t4], "note" => "small" }, llm_context(protect_steps: 0)))
      .to include("- t4: too small: its stub would free nothing")

    expect(forget(entries, "ids" => %w[t1], "note" => "again")).to include("- t1: already forgotten or stubbed")
    expect(forget(entries, "keep" => ["t2:1-30"], "note" => "all of it")).to include("- t2: keep holds all of it")
    expect(forget(entries, "ids" => ["t2"])).to start_with("Error: forget_outputs needs a note")
    expect(forget(entries, "note" => "n")).to start_with("Error: forget_outputs needs ids")
  end

  it "restores a forgotten output at once, whatever the apply rule, but not a sent read (reading the file again is its restore)" do
    entries = conversation
    forget(entries, "ids" => %w[t1 t2], "note" => "both")
    context = instance_double(Samagotchi::ContextStatus, edited!: nil)

    result = forget(entries, { "restore" => "[\"t2\", \"t1\", \"t3\"]" }, llm_context, context)

    expect(result).to match(/\Arestored t2: the next request sends it whole again, now whatever llm_context.apply says \(the server reads the \d+ tokens from it on again\)\nnot done:\n/)
    expect(result).to end_with("- t1: a read: read the file again instead (it may have changed)\n- t3: not forgotten")
    expect(edits(entries).keys).to eq(%w[t1])
    expect(context).to have_received(:edited!)
  end

  it "restores a read whose forget is still staged (never sent)" do
    entries = conversation
    forget(entries, { "ids" => %w[t1], "note" => "a.rb" }, llm_context(:turn_end))

    expect(forget(entries, "restore" => ["t1"])).to eq("restored t1: its stub was never sent")
    expect(edits(entries)).to be_empty
  end

  it "names only outputs with stored ids: a legacy entry's derived ids, user messages and notes are none" do
    entries = conversation
    entries[3] = entries[3].except(:tool_ids)

    expect(forget(entries, "ids" => %w[t1], "note" => "n")).to include("- t1: no output with that id in context")
    expect(described_class.outputs(entries).keys).to eq(%w[t2 t3 t4 t5])
  end

  describe "in the loops" do
    def qwen_call(name, params)
      body = params.map { |key, value| "<parameter=#{key}>\n#{value}\n</parameter>" }.join("\n")
      "<tool_call>\n<function=#{name}>\n#{body}\n</function>\n</tool_call>"
    end

    it "native: offers the tool and the ids only under forget, and the stub reaches the request after the call" do
      file = File.join(dir, "a.rb").tap { |path| File.write(path, "#{source}\n") }
      steps = [qwen_call("read", "path" => file), qwen_call("execute", "command" => "echo hi"),
               qwen_call("execute", "command" => "echo again"), qwen_call("execute", "command" => "echo more"),
               qwen_call("forget_outputs", "ids" => '["t1"]', "note" => "a.rb holds 40 lines; NEXT: answer"), "Done."]
      sent = []
      client = test_client
      allow(client).to receive(:complete) do |prompt, on_chunk: nil, **|
        sent << prompt
        text = steps.shift
        on_chunk&.call(content: text, payload: { "content" => text })
        text
      end
      kernel = test_kernel(client: client, profile: Samagotchi::ModelProfile.qwen36)
      kernel.turn_settings = Samagotchi::LLM::TurnSettings.none.with(llm_context: llm_context)

      events = []
      result = kernel.run([{ role: "system", content: "base" }, { role: "user", content: "go" }], max_iterations: 10,
                          on_stream_event: ->(event) { events << event })

      expect(sent[1]).to include("[read]\n[#t1] line 1 of a.rb")
      # One ✂ row, the forget's own batch, while its call runs.
      rows = events.select { |event| event[:type] == :llm_context_edited }
      expect(rows.map { |row| [row[:moment], row[:groups].map { |group| [group[:kind], group[:note]] }] })
        .to eq([["request", [["forget", "a.rb holds 40 lines; NEXT: answer"]]]])
      at = events.index(rows.first)
      expect(events[...at].reverse.find { |event| event[:type].to_s.start_with?("tool_call_") })
        .to include(type: :tool_call_started, tool: "forget_outputs")
      forget_result = result.conversation.select { |entry| entry[:role] == "tool_response" }.last[:content]
      expect(forget_result).to start_with("[forget_outputs]\nforgot t1: applied")
      expect(sent.last).to include("[read] [#t1] (forgotten) a.rb holds 40 lines; NEXT: answer")
      expect(sent.last).not_to include("line 1 of a.rb")
    end

    it "chat: the tool is in the request's tools only under forget, and its call stubs the output" do
      adapter = FakeChatAdapter.new(FakeChatAdapter.tools(["a", "execute", { "command" => "seq 1 40" }]),
                                    FakeChatAdapter.tools(["b", "forget_outputs", { "ids" => ["t1"], "note" => "it counts to 40" }]),
                                    FakeChatAdapter.text("Done."))
      kernel = test_kernel
      chat = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
      names = -> { chat.tool_definitions.map { |tool| tool[:function][:name] } }
      expect(names.call).not_to include("forget_outputs")

      kernel.turn_settings = Samagotchi::LLM::TurnSettings.none.with(llm_context: llm_context(protect_steps: 0))
      expect(names.call.last).to eq("forget_outputs")

      events = []
      chat.complete(messages: [{ role: "system", content: "base" }, { role: "user", content: "go" }], max_iterations: 5,
                    on_stream_event: ->(event) { events << event })
      expect(events.select { |event| event[:type] == :llm_context_edited }.map { |row| row[:text] })
        .to eq(["✂ forgot 1 output · frees ~#{events.find { |e| e[:type] == :llm_context_edited }[:freed_tokens]} tokens"])

      last = adapter.requests.last[:messages]
      expect(last.find { |message| message[:tool_call_id] == "a" }[:content])
        .to eq("[execute] [#t1] (forgotten) it counts to 40 [restore: t1]")
      expect(last.find { |message| message[:tool_call_id] == "b" }[:content]).to start_with("[forget_outputs]\n[#t2] forgot t1")
    end
  end
end
