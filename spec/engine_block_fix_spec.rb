# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/llm/chat_loop"
require_relative "support/test_kernel"
require_relative "support/fake_chat_adapter"

# Engine::BlockFixPart: the route's answers, the side request on its thread,
# and the write between turns (content, display, or dropped).
RSpec.describe Samagotchi::Engine::BlockFixPart do
  include TestKernel

  let(:tmpdir) { Dir.mktmpdir("block-fix-") }
  let(:events) { [] }
  let(:asks) { [] }
  let(:side_answers) { [] }
  let(:bad) { "graph TD\n  A--B\n" }
  let(:good) { "graph TD\n  A-->B" }
  let(:answer_text) { "Here:\n\n```mermaid\n#{bad}```\n\nDone." }
  let(:engine) do
    Samagotchi::Engine.new(client: test_client).tap do |engine|
      engine.session_state_dir = tmpdir
      engine.interface = :worker
      engine.subscribe(observer: ->(event) { events << event })
    end
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |session|
      session.messages = [{ role: "user", content: "draw it", turn_id: "t1" },
                          { role: "model", content: answer_text, at: "2026-11-21T10:00:00Z" }]
    end
  end

  before do
    side = instance_double(Samagotchi::IdleClient)
    allow(side).to receive(:ask) do |request, **options|
      asks << [request, options]
      next_answer = side_answers.shift || "```mermaid\n#{good}\n```"
      next_answer.is_a?(Proc) ? next_answer.call : Samagotchi::IdleClient::Summary.new(text: next_answer, model: "m")
    end
    allow(Samagotchi::IdleClient).to receive(:for).and_return(side)
    engine.session = session
  end

  after { FileUtils.rm_rf(tmpdir) }

  def fix(source = bad, turn_id: "t1", lang: "mermaid", reason: "Parse error on line 2")
    engine.fix_block(turn_id: turn_id, lang: lang, source: source, reason: reason)
  end

  def settle = eventually { expect(engine.block_fixes_running).to be_empty }

  def answer = session.messages.find { |m| m[:role] == "model" && m[:content].start_with?("Here") }

  def fix_events = events.select { |e| e[:type] == :block_fix }

  def answer_of_turn = session.messages.last

  describe "#fix_block" do
    it "is unavailable without a session, or for a scratch session" do
      engine.instance_variable_set(:@session, nil)
      expect(fix.first).to eq(409)
      engine.session = session
      session.scratch = true
      expect(fix).to eq([409, { error: "fix_unavailable", detail: Samagotchi::BlockFix::REFUSALS[:fix_unavailable] }])
    end

    it "refuses a block over 16 KB, and one that isn't in the turn's answer" do
      expect(fix("x" * (17 * 1024)).first).to eq(413)
      expect(fix("graph LR").first).to eq(409)
      expect(fix(bad, lang: "dot").last[:error]).to eq("block_not_found")
    end

    it "asks once: 202 running while asked, then the stamp's answer" do
      gate = Queue.new
      side_answers << -> { gate.pop }
      expect(fix).to eq([202, { state: "running" }])
      expect(fix).to eq([202, { state: "running" }])
      gate << Samagotchi::IdleClient::Summary.new(text: "```mermaid\n#{good}\n```", model: "m")
      settle
      expect(fix).to eq([202, { state: "running" }])
      expect(engine.apply_block_fixes).to eq(1)
      expect(asks.size).to eq(1)
      expect(fix(good)).to eq([200, { state: "failed", reason: "it failed again after a fix" }])
    end

    it "tells a page that drew the answer before its fix (a second tab): fixed, so it reads the answer again" do
      fix
      settle
      engine.apply_block_fixes
      expect(answer[:content]).not_to include(bad)
      expect(fix).to eq([200, { state: "fixed" }])
    end

    it "answers failed, not fixed, for a fixed block a copy of which is still shown (the page would ask again)" do
      session.messages = [session.messages.first,
                          Samagotchi::BlockFix.with_stamp(session.messages.last,
                                                          Samagotchi::BlockFix.entry(key: Samagotchi::BlockFix.key("mermaid", bad),
                                                                                     fixed_key: "f" * 32, state: "fixed"))]
      expect(fix).to eq([200, { state: "failed", reason: "a copy of it is still in the answer" }])
      expect(asks).to be_empty
    end

    it "asks for the same block in a newer answer as that answer's own, while the older one's ask is in flight" do
      gate = Queue.new
      side_answers << -> { gate.pop }
      expect(fix.first).to eq(202)
      engine.send(:note_block_fix_turn)
      newer = { role: "model", content: "Again:\n\n```mermaid\n#{bad}```\n", at: "2026-11-21T11:00:00Z" }
      session.messages = session.messages + [{ role: "user", content: "again", turn_id: "t2" }, newer]
      expect(fix(turn_id: "t2").first).to eq(202)
      eventually { expect(asks.size).to eq(2) }
      gate << Samagotchi::IdleClient::Summary.new(text: "```mermaid\n#{good}\n```", model: "m")
      settle
      expect(engine.apply_block_fixes).to eq(2)
      expect(session.messages.last[:content]).to include(good)
      expect(fix_events.map { |e| [e[:turn_id], e[:landed]] }).to contain_exactly(%w[t1 display], %w[t2 answer])
    end

    it "answers 429 past two in flight" do
      gate = Queue.new
      session.messages = [session.messages.first, { role: "model", content: "```mermaid\na\n```\n```mermaid\nb\n```" },
                          { role: "user", content: "more", turn_id: "t2" }, { role: "model", content: "```mermaid\nc\n```" }]
      2.times { side_answers << -> { gate.pop } }
      expect(fix("a").first).to eq(202)
      expect(fix("b").first).to eq(202)
      expect(fix("c", turn_id: "t2")).to eq([429, { error: "fix_busy", detail: Samagotchi::BlockFix::REFUSALS[:fix_busy] }])
      2.times { gate << Samagotchi::IdleClient::Summary.new(text: "```mermaid\nz\n```", model: "m") }
      settle
    end

    it "asks for at most two blocks of one answer, counting its stamp, so a reload's third block is refused" do
      session.messages = [session.messages.first,
                          { role: "model", content: "```mermaid\na\n```\n```mermaid\nb\n```\n```mermaid\nc\n```" }]
      side_answers.push("```mermaid\nz1\n```", "```mermaid\nz2\n```")
      expect(fix("a").first).to eq(202)
      expect(fix("b").first).to eq(202)
      expect(fix("c")).to eq([429, { error: "fix_limit", detail: Samagotchi::BlockFix::REFUSALS[:fix_limit] }])
      settle
      expect(fix("c").last[:error]).to eq("fix_limit")
      engine.send(:note_block_fix_turn)
      engine.apply_block_fixes
      expect(Samagotchi::BlockFix.stamps(session.messages.last).size).to eq(2)
      expect(fix("c").last[:error]).to eq("fix_limit")
      expect(asks.size).to eq(2)
    end

    it "sends the conversation up to the answer, display-only keys gone, as the owner's block-fix side request" do
      session.messages = [session.messages.first, session.messages.last.merge(display: "shown " + answer_text),
                          { role: "user", content: "later", turn_id: "t2" }]
      fix
      settle
      request, options = asks.first
      expect(request.last[:content]).to include("User: draw it", "Error: Parse error on line 2")
      expect(request.last[:content]).not_to include("later", "shown")
      expect(options).to include(max_tokens: Samagotchi::BlockFix::MAX_TOKENS, kind: "block-fix")
      expect(engine.side_author("block-fix")).to be_nil
    end

    it "counts the side request in the session's side line under block-fix" do
      allow(Samagotchi::IdleClient).to receive(:for).and_call_original
      allow_any_instance_of(Samagotchi::IdleClient).to receive(:ask) do |_client, _request, **options|
        options[:on_usage]&.call(Samagotchi::SideUsage.new(kind: options[:kind], prompt_tokens: 10, completion_tokens: 5))
        Samagotchi::IdleClient::Summary.new(text: "```mermaid\n#{good}\n```", model: "m")
      end
      fix
      settle
      expect(events.select { |e| e[:type] == :side_usage }.map { |e| e[:kind] }).to eq(["block-fix"])
    end
  end

  describe "#apply_block_fixes" do
    it "patches the answer's text when no turn started since, stamps it and announces it" do
      fix
      settle
      expect(engine.apply_block_fixes).to eq(1)
      expect(answer[:content]).to eq("Here:\n\n```mermaid\n#{good}\n```\n\nDone.")
      expect(answer).not_to have_key(:display)
      expect(Samagotchi::BlockFix.stamps(answer)).to contain_exactly(
        include(key: Samagotchi::BlockFix.key("mermaid", bad), fixed_key: Samagotchi::BlockFix.key("mermaid", good), state: "fixed")
      )
      expect(fix_events).to contain_exactly(include(turn_id: "t1", state: "fixed", landed: "answer", lang: "mermaid",
                                                    was_digest: be_a(String), digest: be_a(String)))
      expect(fix_events.first[:was_digest]).not_to eq(fix_events.first[:digest])
    end

    it "patches every copy of a repeated block in one fix: text, display and saved blocks; neither is asked again" do
      twice = "A:\n\n```mermaid\n#{bad}```\n\nB:\n\n```mermaid\n#{bad}```\n"
      blocks = [{ "type" => "text", "text" => "A:\n\n```mermaid\n#{bad}```\n" }, { "type" => "text", "text" => "B:\n\n```mermaid\n#{bad}```\n" }]
      session.messages = [session.messages.first, { role: "model", content: "Here #{twice}", display: "Shown #{twice}", anthropic_content: blocks }]
      expect(fix.first).to eq(202)
      expect(fix.first).to eq(202)
      settle
      expect(engine.apply_block_fixes).to eq(1)
      expect(asks.size).to eq(1)
      expect(answer[:content].scan(good).size).to eq(2)
      expect(answer[:display].scan(good).size).to eq(2)
      expect(answer[:anthropic_content].map { |b| b["text"] }).to all(include(good))
      expect([answer[:content], answer[:display]]).to all(satisfy { |text| !text.include?("A--B") })
      expect(fix).to eq([200, { state: "fixed" }])
      expect(asks.size).to eq(1)
    end

    it "patches every copy in the display when a turn started since" do
      session.messages = [session.messages.first, session.messages.last.merge(content: "#{answer_text}\n\n```mermaid\n#{bad}```\n")]
      fix
      settle
      engine.send(:note_block_fix_turn)
      engine.apply_block_fixes
      expect(answer[:display].scan(good).size).to eq(2)
      expect(answer[:display]).not_to include("A--B")
    end

    it "lands both blocks of one answer in its text, the second asked before the first's fix changed the text" do
      session.messages = [session.messages.first, session.messages.last.merge(content: "```mermaid\na\n```\n\n```mermaid\nb\n```\n")]
      side_answers.push("```mermaid\nz1\n```", "```mermaid\nz2\n```")
      fix("a")
      fix("b")
      settle
      expect(engine.apply_block_fixes).to eq(2)
      # The two asks run at once: either may take either answer.
      expect(answer_of_turn[:content].scan(/z[12]/).sort).to eq(%w[z1 z2])
      expect(answer_of_turn[:content]).not_to match(/^[ab]$/)
      expect(fix_events.map { |e| e[:landed] }).to eq(%w[answer answer])
      expect(fix_events.last[:was_digest]).to eq(fix_events.first[:digest])
    end

    it "still patches the text when only a note came after the answer" do
      fix
      settle
      session.messages = session.messages + [Samagotchi::ContextNote.message(note_id: "n1", text: "a note", source: "x")]
      expect(engine.apply_block_fixes).to eq(1)
      expect(answer[:content]).to include(good)
    end

    it "patches only the display when a turn started since" do
      fix
      settle
      engine.send(:note_block_fix_turn)
      expect(engine.apply_block_fixes).to eq(1)
      expect(answer[:content]).to eq(answer_text)
      expect(answer[:display]).to include(good)
      expect(fix_events.first).to include(landed: "display", state: "fixed")
      expect(fix_events.first[:was_digest]).to eq(fix_events.first[:digest])
    end

    it "patches only the display when the fix was asked while a turn ran" do
      allow(engine).to receive(:turn_running?).and_return(true)
      fix
      settle
      allow(engine).to receive(:turn_running?).and_call_original
      engine.apply_block_fixes
      expect(answer[:content]).to eq(answer_text)
      expect(answer[:display]).to include(good)
    end

    it "patches the text when the fix was asked as the answer's own turn ended (its hooks still running)" do
      allow(engine).to receive_messages(turn_running?: true, turn_context: instance_double(Samagotchi::TurnContext, id: "t1"))
      fix
      settle
      allow(engine).to receive(:turn_running?).and_call_original
      engine.apply_block_fixes
      expect(answer[:content]).to include(good)
      expect(answer).not_to have_key(:display)
    end

    it "patches a display a hook set, with the text, when the block is in both" do
      session.messages = [session.messages.first, session.messages.last.merge(display: "Shown.\n\n```mermaid\n#{bad}```\n")]
      fix
      settle
      engine.apply_block_fixes
      expect(answer[:content]).to include(good)
      expect(answer[:display]).to eq("Shown.\n\n```mermaid\n#{good}\n```\n")
    end

    it "drops the fix when the answer changed (a rollback, a new text)" do
      fix
      settle
      session.messages = [session.messages.first, session.messages.last.merge(content: "Other.\n\n```mermaid\n#{bad}```")]
      expect(engine.apply_block_fixes).to eq(0)
      expect(Samagotchi::BlockFix.stamps(session.messages.last)).to be_empty
      expect(fix_events).to contain_exactly(include(state: "dropped", reason: "the answer changed"))
    end

    it "stamps failed, with the reason, a fix too long for the display of an answer still there, so it isn't asked again" do
      stub_const("Samagotchi::AnswerDisplay::MAX_CHARS", answer_text.length)
      fix
      settle
      engine.send(:note_block_fix_turn)
      expect(engine.apply_block_fixes).to eq(1)
      expect(answer[:content]).to eq(answer_text)
      expect(answer).not_to have_key(:display)
      expect(Samagotchi::BlockFix.stamps(answer)).to contain_exactly(include(state: "failed", reason: "the fix is too long"))
      expect(fix_events).to contain_exactly(include(state: "failed", reason: "the fix is too long"))
      expect(fix).to eq([200, { state: "failed", reason: "the fix is too long" }])
      expect(asks.size).to eq(1)
    end

    it "stamps failed a fix whose block left the answer's display (a hook rewrote it), the answer still there" do
      fix
      settle
      session.messages = [session.messages.first, session.messages.last.merge(display: "Rewritten, no block.")]
      expect(engine.apply_block_fixes).to eq(1)
      expect(answer[:content]).to eq(answer_text)
      expect(Samagotchi::BlockFix.stamps(answer)).to contain_exactly(include(state: "failed", reason: "the answer changed"))
    end

    it "stamps a failed ask and changes no text" do
      side_answers << "```mermaid\n#{bad}```"
      fix
      settle
      expect(engine.apply_block_fixes).to eq(1)
      expect(answer[:content]).to eq(answer_text)
      expect(Samagotchi::BlockFix.stamps(answer)).to contain_exactly(include(state: "failed", reason: "the fix was the same block"))
      expect(fix_events.first).to include(state: "failed", reason: "the fix was the same block")
      expect(fix).to eq([200, { state: "failed", reason: "the fix was the same block" }])
    end

    it "fails a chi-ui fix that doesn't parse, and one whose request raised" do
      session.messages = [session.messages.first, { role: "model", content: "```chi-ui\ntype: nope\n```" }]
      side_answers << "```chi-ui\ntype: still-nope\n```"
      fix("type: nope", lang: "chi-ui")
      settle
      engine.apply_block_fixes
      expect(fix_events.last[:reason]).to include("unknown type")
      session.messages = [session.messages.first, { role: "model", content: "```mermaid\nx\n```" }]
      side_answers << -> { raise Samagotchi::IdleClient::SummarizeError, "the model request failed: boom\nmore" }
      fix("x")
      settle
      engine.apply_block_fixes
      expect(fix_events.last).to include(state: "failed", reason: "the model request failed: boom")
    end

    it "patches a Messages-shaped answer's saved text block, so the wire sends the fix; never a thinking block" do
      blocks = [{ "type" => "thinking", "thinking" => "```mermaid\n#{bad}```", "signature" => "sig" },
                { "type" => "text", "text" => answer_text }]
      session.messages = [session.messages.first, session.messages.last.merge(anthropic_content: blocks)]
      fix
      settle
      engine.apply_block_fixes
      expect(answer[:anthropic_content].first).to eq(blocks.first)
      expect(answer[:anthropic_content].last["text"]).to include(good)

      adapter = FakeChatAdapter.new
      def adapter.replays_content? = true
      loop = Samagotchi::LLM::ChatLoop.new(kernel: test_kernel, adapter: adapter)
      wire = loop.wire_messages(session.messages + [{ role: "user", content: "next" }])
      sent = Samagotchi::LLM::AnthropicWire.translate(wire).messages
      expect(JSON.generate(sent)).to include(JSON.generate(good)[1..-2])
      expect(JSON.generate(sent)).not_to include("A--B\\n```\\n\\nDone")
    end

    it "drops the saved blocks when no one text block holds the block whole" do
      blocks = [{ "type" => "text", "text" => "Here:\n\n```mermaid\ngraph TD\n" }, { "type" => "text", "text" => "  A--B\n```\n\nDone." }]
      session.messages = [session.messages.first, session.messages.last.merge(anthropic_content: blocks)]
      fix
      settle
      engine.apply_block_fixes
      expect(answer).not_to have_key(:anthropic_content)
      expect(answer[:content]).to include(good)
    end

    it "drops a reminder turn's fix once a later turn repeating the block answered; the newer answer untouched" do
      session.messages = [{ role: "system", content: "reminder" }, { role: "model", content: answer_text }]
      fix(turn_id: "reminder-turn")
      settle
      newer = { role: "model", content: answer_text, at: "2026-11-21T11:00:00Z" }
      session.messages = session.messages + [{ role: "user", content: "again", turn_id: "t2" }, newer]
      engine.send(:note_block_fix_turn)
      expect(engine.apply_block_fixes).to eq(0)
      expect(session.messages.last).to eq(newer)
      expect(session.messages[1][:content]).to eq(answer_text)
      expect(fix_events.first[:state]).to eq("dropped")
    end

    it "waits while a turn runs, and wakes the worker once a result waits" do
      woken = Queue.new
      engine.block_fix_ready = -> { woken << true }
      fix
      expect(woken.pop(timeout: 5)).to be(true)
      allow(engine).to receive(:turn_running?).and_return(true)
      expect(engine.apply_block_fixes).to eq(0)
      allow(engine).to receive(:turn_running?).and_call_original
      expect(engine.apply_block_fixes).to eq(1)
    end
  end
end
