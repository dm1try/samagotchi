# frozen_string_literal: true

require "json"
require "samagotchi/worker_link"
require_relative "../support/worker_fixtures"
require_relative "../support/worker_links"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "a failed turn's prompt" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:typed) { Queue.new }
  let(:reads) { Queue.new }

  before do
    allow(client).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e1"}'))
    allow(client).to receive(:follow) do |&block|
      @push = block
      block.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 })
      double("stream", close: nil)
    end
    # Each read reports its prefill, then blocks until the spec types.
    @thread = Thread.new { attached.run(input: ->(_prompt, prefill) { reads << prefill; typed.pop }) }
    expect(reads.pop(timeout: 2)).to be_nil
  end

  after do
    typed << nil
    @thread.join(2)
  end

  def fail_turn(enqueued_id)
    @push.call("type" => "turn_failed", "error_class" => "Samagotchi::LLM::ServerError", "summary" => "server error from host main: HTTP 500")
    @push.call("type" => "prompt_restored", "prompt" => "boom", "origin" => { "client_id" => "tui:1", "enqueued_id" => enqueued_id })
  end

  it "puts its own prompt back in the input, as the REPL does" do
    typed << "boom"
    expect(reads.pop(timeout: 2)).to be_nil

    fail_turn("e1")

    expect(reads.pop(timeout: 2)).to eq("boom")
    expect(screen.lines).to include("✕ turn failed: server error from host main: HTTP 500", "  prompt restored for retry")
  end

  it "leaves the input alone for a prompt it didn't send in this run (a replayed event, another UI)" do
    fail_turn("e-old")
    @push.call("type" => "prompt_restored", "prompt" => "theirs", "origin" => { "client_id" => "web:1", "enqueued_id" => "e2" })

    expect(reads.pop(timeout: 0.3)).to be_nil
    expect(screen.lines).not_to include("  prompt restored for retry")
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "commands and the continue offer" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }

  def feed(*events)
    events.each { |e| attached.handle_event(JSON.parse(JSON.generate(e))) }
  end

  def joined(continue_offer: nil)
    { type: :snapshot, snapshot: { messages: [], current_turn: nil, queued: [], continue_offer: continue_offer, event_seq: 1 } }
  end

  def ran(**fields)
    { type: :command_ran, command_id: "c1", client_id: "tui:1", line: "/model", status: "ok", output: "", changed: [],
      model_name: "m1" }.merge(fields)
  end

  before { feed(joined) }

  it "shows its own command's output as the REPL does: model> lines, a !cmd's own output as is" do
    feed(ran(line: "/model", output: "runtime model: m1 (profile=qwen36)"), ran(line: "!ls", output: "a\nb\n"))

    expect(screen.lines).to eq(["model> runtime model: m1 (profile=qwen36)", "a\nb\n"])
  end

  it "shows another UI's command with who sent it" do
    feed(ran(client_id: "web:tab", line: "/model x", output: "runtime model set to x (profile=qwen36)", changed: ["model"]))

    expect(screen.lines).to eq(["web> /model x", "model> runtime model set to x (profile=qwen36)"])
    expect(attached.model_name).to eq("m1")
  end

  it "says a refused command waits for the turn to end, and puts ours back into the prompt" do
    reader = double("reader", prefill: true)
    attached.instance_variable_set(:@reader, reader)

    feed(ran(status: "busy", line: "!rollback", output: "busy: Ctrl-C the turn first, then !rollback"),
         ran(status: "busy", client_id: "web:tab", line: "/continue", output: "busy: wait for the turn to end"))

    expect(screen.lines.last(2)).to eq(["web> /continue", "busy: wait for the turn to end"])
    expect(reader).to have_received(:prefill).once.with("!rollback")
  end

  it "says a queued command runs after the turn, at its command_queued, and prints no line again when it ran" do
    reader = double("reader", prefill: true)
    attached.instance_variable_set(:@reader, reader)

    feed({ type: :command_queued, command_id: "c1", client_id: "tui:1", line: "/model x", waits: "turn_end" },
         { type: :command_queued, command_id: "c2", client_id: "web:tab", line: "!ls", waits: "turn_end" })
    expect(screen.lines).to eq(["(queued: runs after this turn)", "web> !ls (queued: runs after this turn)"])

    feed(ran(command_id: "c1", line: "/model x", output: "runtime model set to x", changed: ["model"], queued: true),
         ran(command_id: "c2", client_id: "web:tab", line: "!ls", status: "dropped", queued: true,
             output: "turn canceled: !ls not run; send it again"))
    expect(screen.lines.drop(2)).to eq(["model> runtime model set to x", "turn canceled: !ls not run; send it again"])
    expect(reader).not_to have_received(:prefill)
  end

  it "prints the snapshot's queued commands on attach" do
    feed({ type: :snapshot, snapshot: { messages: [], current_turn: nil, queued: [], event_seq: 2,
                                        queued_commands: [{ command_id: "c1", client_id: "web:tab", line: "/model x" }] } })

    expect(screen.lines).to include("queued web> /model x")
  end

  it "prints a waiting command once, not again at each resync" do
    snapshot = { messages: [], current_turn: nil, queued: [], event_seq: 2,
                 queued_commands: [{ command_id: "c1", client_id: "web:tab", line: "/model x" }] }
    feed({ type: :snapshot, snapshot: snapshot }, { type: :reset, snapshot: snapshot },
         { type: :reset, snapshot: snapshot.merge(queued_commands: snapshot[:queued_commands] +
                                                    [{ command_id: "c2", client_id: "web:tab", line: "!ls" }]) })

    expect(screen.lines.grep(/\Aqueued web>/)).to eq(["queued web> /model x", "queued web> !ls"])
  end

  it "puts its own change's --yes line in the input when the worker asks first, never another UI's" do
    reader = double("reader", prefill: true)
    attached.instance_variable_set(:@reader, reader)
    confirm = { line: "/reasoning-history all --yes", text: "Nothing changed yet: send `/reasoning-history all --yes` to apply." }

    feed(ran(line: "/reasoning-history all", output: "reasoning history: turn (default)\n#{confirm[:text]}", confirm: confirm),
         ran(client_id: "web:tab", line: "/thinking low", output: "asks", confirm: { line: "/thinking low --yes", text: "t" }))

    expect(reader).to have_received(:prefill).once.with("/reasoning-history all --yes")
    expect(screen.lines.first).to start_with("model> reasoning history: turn (default)")
  end

  it "points to the history when the prompt already holds text" do
    attached.instance_variable_set(:@reader, double("reader", prefill: false))

    feed(ran(status: "busy", line: "!rollback", output: "busy: Ctrl-C the turn first, then !rollback"))

    expect(screen.lines.last).to eq("(the command is in the input history: ↑)")
  end

  it "asks at the ? prompt, its choices in the notes slot, while an offer is pending, from the join too" do
    expect(attached.send(:prompt_text)).to eq("> ")

    feed({ type: :continue_offered, context: { original_prompt: "task", last_model_intent: "run specs" }, no_interrupt: false })
    expect(attached.send(:prompt_text)).to eq("? ")
    expect(screen.slots[:notes]).to eq(["? The turn ran out of iterations. Continue it?", "  last step: run specs",
                                        "  yes: continue (Enter alone too)", "  no: stop here",
                                        "  no, <reason>: stop and tell the model why"])

    feed({ type: :continue_resolved, decision: "resume", client_id: "web:tab" })
    expect(attached.send(:prompt_text)).to eq("> ")
    expect(screen.slots).not_to have_key(:notes)
    # The web's "web> /continue yes" line says who answered.
    expect(screen.lines.grep(/Continue it\?/)).to be_empty

    feed({ type: :continue_offered, context: {}, no_interrupt: false },
         { type: :continue_resolved, decision: "dropped", client_id: "web:tab" })
    expect(screen.lines.last).to eq("? The turn ran out of iterations. Continue it? → (dropped: web sent a new prompt)")

    # A Continue on a participant's offer refused since says so, whoever answered.
    feed({ type: :continue_offered, context: {}, no_interrupt: false },
         { type: :continue_resolved, decision: "refused", reason: "revoked", client_id: "web:tab" })
    expect(screen.lines.last).to eq("? The turn ran out of iterations. Continue it? → " \
                                    "not continued: the participant may no longer run turns")

    other = described_class.new(client: client, screen: screen, client_id: "tui:2")
    other.handle_event(JSON.parse(JSON.generate(joined(continue_offer: { context: {}, no_interrupt: false }))))
    expect(other.send(:prompt_text)).to eq("? ")
    expect(screen.slots[:notes].first).to eq("? The turn ran out of iterations. Continue it?")
  end

  it "asks a question pending between turns (the step-limit one) on a join" do
    other = described_class.new(client: client, screen: screen, client_id: "tui:2")
    question = { id: "q9", kind: "continue", header: "Step limit", question: "The turn ran out of iterations. Continue it?",
                 options: %w[Continue Stop], multi_select: false, allow_freeform: true, status: "pending" }
    snapshot = joined.tap { |event| event[:snapshot][:pending_question] = question }
    other.handle_event(JSON.parse(JSON.generate(snapshot)))

    expect(other.send(:prompt_text)).to eq("? ")
    expect(screen.slots[:notes].join("\n")).to include("Step limit").and include("Continue")
  end

  describe "context notes" do
    let(:note) { Samagotchi::ContextNote.message(note_id: "n1", text: "deploy frozen", source: "slack") }

    # This group has already joined: a join header needs a fresh UI.
    def join_fresh(messages)
      other = described_class.new(client: client, screen: screen, client_id: "tui:2")
      other.handle_event(JSON.parse(JSON.generate(joined.tap { |event| event[:snapshot][:messages] = messages })))
    end

    it "shows a note as one line: who sent it and its first line" do
      feed({ type: :context_added, label: "slack", text: "deploy frozen" },
           { type: :context_added, label: "session 3f2a1c (~/w/foo)", text: "api moved\nsee the wiki" },
           { type: :context_added, label: "cli", text: "x" * 100 },
           { type: :context_added, label: "cli", text: "#{"y" * 100}\nmore" })

      expect(screen.lines).to eq(["note from slack: deploy frozen",
                                  "note from session 3f2a1c (~/w/foo): api moved …",
                                  "note from cli: #{"x" * 59}…",
                                  "note from cli: #{"y" * 59}…"])
    end

    it "shows on join the notes that came after the last exchange, not older ones" do
      allow(Samagotchi::Log).to receive(:info).and_call_original
      old = Samagotchi::ContextNote.message(note_id: "n0", text: "old news", source: "cli")
      join_fresh([{ role: "system", content: "sys" }, old, { role: "user", content: "hi" },
                  { role: "model", content: "hello there" }, note])

      expect(screen.lines).to eq(["user> hi", "hello there", "note from slack: deploy frozen"])
      # The log counts every note the session holds, shown or not.
      expect(Samagotchi::Log).to have_received(:info).with(:attached, "joined", session: "s-1234", messages: 2, notes: 2)
    end

    it "shows the notes of a session that has no exchange yet" do
      join_fresh([{ role: "system", content: "sys" }, note])

      expect(screen.lines).to eq(["note from slack: deploy frozen"])
    end
  end

  describe "a plugin's steer" do
    let(:steer) { Samagotchi::Steer.message(text: "how is it going?", source: "check-in") }

    it "is not the prompt in the join header: the prompt, the steer's line, the answer" do
      other = described_class.new(client: client, screen: screen, client_id: "tui:2")
      messages = [{ role: "user", content: "fix it" }, { role: "model", content: "" }, steer, { role: "model", content: "fixed" }]
      other.handle_event(JSON.parse(JSON.generate(joined.tap { |event| event[:snapshot][:messages] = messages })))

      expect(screen.lines).to eq(["user> fix it", "check-in> nudged: how is it going?", "fixed"])
    end

    it "shows a running turn's steer part on join" do
      other = described_class.new(client: client, screen: screen, client_id: "tui:2")
      turn = { prompt: "go", origin: { client_id: "web:1" }, parts: [{ kind: "steer", source: "check-in", text: "status?" }] }
      other.handle_event(JSON.parse(JSON.generate(joined.merge(snapshot: joined[:snapshot].merge(current_turn: turn)))))

      expect(screen.lines).to include("check-in> nudged: status?")
    end
  end

  it "renders a reminder turn by its reminders, live and from a join" do
    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "system:reminder" } },
         { type: :reminder_injected, reminders: [{ name: "stretch", description: "Stand up", interval_minutes: 1 }] })
    expect(screen.lines).to eq(["reminder: stretch"])

    other = described_class.new(client: client, screen: screen, client_id: "tui:2")
    turn = { prompt: nil, continue: true, origin: { client_id: "system:reminder" },
             parts: [{ kind: "reminder", reminders: [{ name: "stretch" }, { name: "water" }] }] }
    other.handle_event(JSON.parse(JSON.generate(joined.merge(snapshot: joined[:snapshot].merge(current_turn: turn)))))
    expect(screen.lines.last).to eq("reminder: stretch, water")
  end

  it "renders a continue turn as (continuing), not as an empty prompt line" do
    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "web:tab" } })

    expect(screen.lines.last).to eq("web> (continuing)")
  end

  it "renders a turn an attached context change started by its label alone, live and from a join" do
    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "context:pr-12" } })
    expect(screen.lines.last).to eq("context pr-12 changed>")

    other = described_class.new(client: client, screen: screen, client_id: "tui:2")
    turn = { prompt: nil, continue: true, origin: { client_id: "context:pr-12" }, parts: [] }
    other.handle_event(JSON.parse(JSON.generate(joined.merge(snapshot: joined[:snapshot].merge(current_turn: turn)))))
    expect(screen.lines.last).to eq("context pr-12 changed>")
  end

  it "renders a finished task's wake turn by its label alone, live and from a join" do
    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "task:3f9a2c1d-0000" } })
    expect(screen.lines.last).to eq("task 3f9a2c1d finished>")

    other = described_class.new(client: client, screen: screen, client_id: "tui:2")
    turn = { prompt: nil, continue: true, origin: { client_id: "task:3f9a2c1d-0000" }, parts: [] }
    other.handle_event(JSON.parse(JSON.generate(joined.merge(snapshot: joined[:snapshot].merge(current_turn: turn)))))
    expect(screen.lines.last).to eq("task 3f9a2c1d finished>")
  end

  it "points at !rollback after a cancelled prompt turn, not after a cancelled continue" do
    feed({ type: :turn_started, prompt: "go", origin: { client_id: "tui:1" } }, { type: :turn_canceled, cancellation_reason: "ctrl_c" })
    expect(screen.lines.last(2)).to eq(["■ turn canceled (Ctrl-C)", "  partial progress kept; !rollback restores the pre-turn state"])

    feed({ type: :turn_started, prompt: nil, continue: true, origin: { client_id: "tui:1" } }, { type: :turn_canceled, cancellation_reason: "ctrl_c" })
    expect(screen.lines.last).to eq("■ turn canceled (Ctrl-C)")
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "launch flags" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:joined) { { "type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 } } }
  let(:ack) { Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e1"}') }

  def ran(status, output) = { "type" => "command_ran", "command_id" => "c1", "client_id" => "tui:1", "line" => "/model fast",
                              "status" => status, "output" => output, "changed" => [], "model_name" => "m" }

  # The launcher sends --model as "/model X --yes" (no confirm step): its
  # applied reply ends the launch's command.
  it "switches the model first, then sends the first prompt" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    allow(client).to receive(:post_turn).and_return(ack)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi",
                                   first_command: "/model fast --yes")

    attached.handle_event(joined)
    expect(client).not_to have_received(:post_turn)
    attached.handle_event(ran("ok", "runtime model set to fast (profile=qwen36)"))

    expect(client).to have_received(:post_command).with(line: "/model fast --yes", client_id: "tui:1")
    expect(client).to have_received(:post_turn).with(prompt: "hi", client_id: "tui:1")
  end

  it "runs the first commands in order (--model, then --llm-context), then sends the first prompt" do
    replies = [Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'),
               Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c2"}')]
    allow(client).to receive(:post_command).and_return(*replies)
    allow(client).to receive(:post_turn).and_return(ack)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi",
                                   first_command: ["/model fast", "/llm-context strategy stale"])

    attached.handle_event(joined)
    attached.handle_event(ran("ok", "runtime model set to fast"))
    expect(client).to have_received(:post_command).with(line: "/llm-context strategy stale", client_id: "tui:1")
    expect(client).not_to have_received(:post_turn)
    result = attached.handle_event(ran("error", "unknown llm_context strategy x").merge("command_id" => "c2"))

    expect(result).to eq(:failed)
    expect(screen.lines.last).to eq("could not set the --llm-context: unknown llm_context strategy x")
    expect(client).not_to have_received(:post_turn)
  end

  # --thinking on a resumed session runs "/thinking X --yes" last; its
  # failure (and its queued note) name --thinking, not --llm-context.
  it "names --thinking when the /thinking first command fails or waits" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    allow(client).to receive(:post_turn)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi",
                                   first_command: "/thinking high --yes")

    attached.handle_event(joined)
    attached.handle_event({ "type" => "command_queued", "command_id" => "c1", "client_id" => "tui:1",
                            "line" => "/thinking high --yes", "waits" => "turn_end" })
    expect(screen.lines.last).to eq("(--thinking queued: applies after the running turn)")
    result = attached.handle_event(ran("error", "unknown thinking level").merge("queued" => true))

    expect(result).to eq(:failed)
    expect(screen.lines.last).to eq("could not set the --thinking: unknown thinking level")
    expect(client).not_to have_received(:post_turn)
  end

  # S6: --model on a session whose turn runs waits for that turn's end.
  it "says a queued --model applies after the running turn, and sends the first prompt once it ran" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    allow(client).to receive(:post_turn).and_return(ack)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi", first_command: "/model fast")

    attached.handle_event(joined)
    attached.handle_event({ "type" => "command_queued", "command_id" => "c1", "client_id" => "tui:1", "line" => "/model fast",
                            "waits" => "turn_end" })
    expect(screen.lines.last).to eq("(--model queued: applies after the running turn)")
    expect(client).not_to have_received(:post_turn)
    attached.handle_event(ran("ok", "runtime model set to fast").merge("queued" => true))

    expect(client).to have_received(:post_turn).with(prompt: "hi", client_id: "tui:1")
  end

  # An older worker answers busy instead of queueing.
  it "stops the launch when the switch doesn't go through, saying why" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    allow(client).to receive(:post_turn)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi", first_command: "/model fast")

    attached.handle_event(joined)
    result = attached.handle_event(ran("busy", "busy: wait for the turn to end"))

    expect(result).to eq(:failed)
    expect(screen.lines.last).to eq("could not switch to the --model: busy: wait for the turn to end")
    expect(client).not_to have_received(:post_turn)
  end

  it "stops the launch when the worker can't take the command" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 404, body: "{}"))
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_command: "/model fast")

    expect(attached.handle_event(joined)).to eq(:failed)
    expect(screen.lines.last).to start_with("could not switch to the --model: this session's worker runs an older chi")
    expect(screen.lines.last).to include("chi sessions stop s-1234 && chi --resume s-1234")
  end

  # chi --attach ID --llm-context stale to a worker on an older chi (one
  # with no /llm-context): it says so, not "the worker answered 400".
  it "stops the launch when the worker runs a chi without the command" do
    detail = '{"error":"unknown_command","detail":"not a session command: /llm-context strategy stale"}'
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 400, body: detail))
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_command: "/llm-context strategy stale")

    expect(attached.handle_event(joined)).to eq(:failed)
    expect(screen.lines.last).to eq("could not set the --llm-context: this session's worker runs an older chi and can't run /llm-context; " \
                                    "restart it: chi sessions stop s-1234 && chi --resume s-1234 (its turns still work)")
  end

  it "stops the launch when the worker doesn't answer the command" do
    allow(client).to receive(:post_command).and_raise(Errno::ETIMEDOUT.new("bridge command: no reply within 30s"))
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_command: "/model fast")

    expect(attached.handle_event(joined)).to eq(:failed)
    expect(screen.lines.last).to eq("could not switch to the --model: worker not answering: no reply within 30s")
  end

  it "stops the launch when the worker dropped the command as too late" do
    allow(client).to receive(:post_command)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}'))
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_command: "/model fast")

    expect(attached.handle_event(joined)).to eq(:failed)
    expect(screen.lines.last).to eq("could not switch to the --model: worker not answering in time")
  end

  it "posts every prompt with no_interrupt under --no-interrupt" do
    allow(client).to receive(:post_turn).and_return(ack)
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "hi", no_interrupt: true)

    attached.handle_event(joined)

    expect(client).to have_received(:post_turn).with(prompt: "hi", client_id: "tui:1", no_interrupt: true)
  end
end
