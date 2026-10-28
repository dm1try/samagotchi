# frozen_string_literal: true

require "json"
require "samagotchi/worker_link"
require_relative "../support/worker_fixtures"
require_relative "../support/worker_links"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "questions" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:question) { { "id" => "q1", "question" => "Which one?", "options" => %w[Apple Banana Cherry] } }
  let(:typed) { Queue.new }
  let(:prompts) { [] }
  let(:prefills) { [] }

  def snapshot(pending_question: nil)
    turn = { "prompt" => "p", "parts" => [], "pending_question" => pending_question }
    { "type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => turn, "queued" => [], "event_seq" => 1 } }
  end

  # Runs the loop on a thread. The fake terminal blocks in each read, like
  # Reline, until the spec types a line; events are pushed with #push.
  def start(first: snapshot)
    allow(client).to receive(:follow) do |&block|
      @push = block
      block.call(first)
      double("stream", close: nil)
    end
    @thread = Thread.new do
      attached.run(input: lambda { |prompt, prefill|
        prompts << prompt
        prefills << prefill
        typed.pop
      })
    end
    wait_for("the first prompt") { prompts.any? }
  end

  def push(event) = @push.call(event)

  def finish
    typed << nil
    @thread.join(2)
  end

  it "asks a question at the ? prompt, its choices in the notes slot, and sends the answer" do
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start
    push("type" => "question_requested", "pending_question" => question)

    wait_for("the question prompt") { prompts.last == "? " }
    wait_for("the notes") { screen.slots[:notes] }
    expect(screen.slots[:notes]).to include("? Which one?", "  2) Banana")
    typed << "2"
    wait_for("the turn prompt") { prompts.last == "> " }
    finish

    # The choices go; one line stays: the question and the answer.
    expect(screen.slots).not_to have_key(:notes)
    expect(screen.lines).to include("? Which one? → Banana")
    expect(screen.lines.join("\n")).not_to include("2) Banana")
    expect(client).to have_received(:answer).with(id: "q1", selected: ["Banana"], freeform: nil)
  end

  it "reads the continue words at the step-limit question, Enter alone continuing, and draws no second slot or line" do
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start
    limit = { "id" => "c1", "kind" => "continue", "header" => "Step limit", "options" => %w[Continue Stop],
              "question" => "The turn ran out of iterations (3 steps) before it answered. Continue it?", "allow_freeform" => true }
    push("type" => "continue_offered", "context" => { "original_prompt" => "task" }, "no_interrupt" => false)
    push("type" => "question_requested", "pending_question" => limit)

    wait_for("the note Step limit") { screen.slots[:notes]&.any? { |line| line.include?("Step limit") } }
    expect(screen.slots[:notes].join("\n")).to include("Enter or yes = Continue")
    expect(prompts.last).to eq("? ")
    typed << ""
    wait_for("the line → Continue") { screen.lines.any? { |line| line.include?("→ Continue") } }
    # The worker's events for that answer: the old offer's slot doesn't come back, nor its own line.
    push("type" => "question_answered", "id" => "c1", "answer" => { "selected" => ["Continue"] })
    push("type" => "continue_resolved", "decision" => "resume", "client_id" => "tui:1")
    wait_for("the turn prompt") { prompts.last == "> " }
    finish

    expect(client).to have_received(:answer).with(id: "c1", selected: ["Continue"], freeform: nil)
    expect(screen.slots).not_to have_key(:notes)
    expect(screen.lines.grep(/Continue it\?/).size).to eq(1)
  end

  it "stops at the step-limit question with no, <reason>" do
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start
    push("type" => "question_requested", "pending_question" => { "id" => "c1", "kind" => "continue", "options" => %w[Continue Stop],
                                                                 "question" => "Continue it?", "allow_freeform" => true })
    wait_for("the question prompt") { prompts.last == "? " }
    typed << "no, it is going in circles"
    wait_for("the line → Stop: it is going in circles") { screen.lines.any? { |line| line.include?("→ Stop: it is going in circles") } }
    finish

    expect(client).to have_received(:answer).with(id: "c1", selected: ["Stop"], freeform: "it is going in circles")
  end

  it "puts what was typed at the prompt aside for the question and back after it" do
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    allow_any_instance_of(Samagotchi::TerminalUI::LineReader).to receive(:typed_text).and_return("half typed")
    start
    push("type" => "question_requested", "pending_question" => question)

    wait_for("the question prompt") { prompts.last == "? " }
    expect(prefills.last).to be_nil
    typed << "2"
    wait_for("the turn prompt") { prompts.last == "> " }
    finish

    expect(prefills.last).to eq("half typed")
  end

  # The step-limit question closes before its offer resolves: the prompt
  # stays ? meanwhile, so the text set aside waits for the > prompt.
  it "puts the text set aside back once a continue offer the question stood for resolves" do
    allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    # What the open read holds: the text, moved into the offer's ? read,
    # until the question takes it aside; then the empty answer line.
    buffer = "half typed"
    allow_any_instance_of(Samagotchi::TerminalUI::LineReader).to receive(:typed_text) { buffer }
    start
    push("type" => "continue_offered", "context" => { "original_prompt" => "task" }, "no_interrupt" => false)
    push("type" => "question_requested", "pending_question" => { "id" => "c1", "kind" => "continue", "options" => %w[Continue Stop],
                                                                 "question" => "Continue it?", "allow_freeform" => true })
    wait_for("the note Continue it?") { screen.slots[:notes]&.any? { |line| line.include?("Continue it?") } }
    buffer = ""
    typed << ""
    wait_for("the line → Continue") { screen.lines.any? { |line| line.include?("→ Continue") } }
    push("type" => "question_answered", "id" => "c1", "answer" => { "selected" => ["Continue"] })
    push("type" => "continue_resolved", "decision" => "resume", "client_id" => "tui:1")
    wait_for("the turn prompt") { prompts.last == "> " }
    finish

    expect(prefills.last).to eq("half typed")
  end

  describe "an approval" do
    let(:approval) do
      { "id" => "a1", "kind" => "approval", "header" => "Approve tool call?",
        "question" => "execute: git push\n  in /r (repo r, branch main)\n  why: pushes (rule git-push, config)",
        "options" => ["Allow once", "Allow this call in this repo", "Deny"], "allow_freeform" => true,
        "approval" => { "scopes" => %w[once repo] } }
    end

    it "shows the call and takes y (also when it was pending before the attach)" do
      allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
      start(first: snapshot(pending_question: approval))
      wait_for("the question prompt") { prompts.last == "? " }
      wait_for("the notes") { screen.slots[:notes] }
      expect(screen.slots[:notes]).to include("Approve tool call?", "! execute: git push", "  why: pushes (rule git-push, config)",
                                              "  3) Deny")
      typed << "y"
      wait_for("the turn prompt") { prompts.last == "> " }
      finish
      expect(client).to have_received(:answer).with(id: "a1", selected: ["Allow once"], freeform: nil)
      expect(screen.lines).to include("! execute: git push → Allow once")
    end

    # A parent agent driving chi --attach (piped stdin, an agent marker):
    # its answers are a parent's, held to guardrails.parent_answers.
    context "answered by a parent agent" do
      let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", as_parent: true) }

      it "marks the answer as chi answer's and shows the worker's refusal, the question still open" do
        refusal = { "error" => "parent_answer_refused", "reason" => "permit_wide", "detail" => "allowing a tool call is up to the user" }
        allow(client).to receive(:answer)
          .and_return(Samagotchi::BridgeClient::Response.new(status: 403, body: JSON.generate(refusal)))
        start(first: snapshot(pending_question: approval))
        wait_for("the question prompt") { prompts.last == "? " }
        typed << "2"
        wait_for("the line allowing a tool call is up to the user") { screen.lines.any? { |line| line.include?("allowing a tool call is up to the user") } }
        expect(prompts.last).to eq("? ")
        finish
        expect(client).to have_received(:answer).with(id: "a1", selected: ["Allow this call in this repo"], freeform: nil,
                                                      client_id: Samagotchi::ClientId::CLI_ANSWER)
      end
    end

    it "prints an edit's diff above the slot once, when the snapshot and the event both bring it" do
      allow(client).to receive(:dismiss_question).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
      edit = approval.merge("question" => "edit: /k.conf\n  change: +1 \u22121",
                            "approval" => { "scopes" => %w[once], "preview" => { "text" => "@@ -1 +1 @@\n-a\n+b" } })
      start(first: snapshot(pending_question: edit))
      wait_for("the question prompt") { prompts.last == "? " }
      push("type" => "question_requested", "pending_question" => edit)
      wait_for("the notes") { screen.slots[:notes] }
      expect(screen.slots[:notes]).to include("! edit: /k.conf", "  change: +1 \u22121")
      typed << ""
      wait_for("the turn prompt") { prompts.last == "> " }
      finish
      expect(screen.lines.count("@@ -1 +1 @@\n-a\n+b")).to eq(1)
    end

    it "shows that the question waits in the parent too, live, and a relayed card's close in its own words" do
      start
      push("type" => "question_requested", "pending_question" => approval)
      wait_for("the notes") { screen.slots[:notes] }
      push("type" => "question_relay", "id" => "a1", "relayed_to" => { "parent_id" => "p" * 36, "parent_short" => "pppppppp" })
      wait_for("the note waiting in parent pppppppp too (answering here works)") { screen.slots[:notes]&.include?("  waiting in parent pppppppp too (answering here works)") }
      push("type" => "question_relay", "id" => "a1", "relayed_to" => nil, "reason" => "parent_gone")
      wait_for("the note waiting in parent to go") { !screen.slots[:notes].to_s.include?("waiting in parent") }
      push("type" => "question_cancelled", "id" => "a1", "reason" => "user")

      relayed = approval.merge("id" => "a2", "relay" => { "child_id" => "cccc1111-0", "chain" => ["cccc1111"], "task" => "push it",
                                                          "asked" => "execute: git push" })
      push("type" => "question_requested", "pending_question" => relayed)
      wait_for("the note delegate cccc1111 · push it") { screen.slots[:notes]&.include?("  delegate cccc1111 · push it") }
      push("type" => "question_cancelled", "id" => "a2", "reason" => "answered_on_child")
      wait_for("the turn prompt") { prompts.last == "> " }
      finish
      expect(screen.lines).to include("! execute: git push → (question cancelled)",
                                      "! cccc1111: execute: git push → (answered in cccc1111)")
    end

    it "sends n with a reason, and says denied on an empty answer" do
      allow(client).to receive(:answer).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
      allow(client).to receive(:dismiss_question).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
      start
      push("type" => "question_requested", "pending_question" => approval)
      wait_for("the question prompt") { prompts.last == "? " }
      typed << "n; use a PR"
      wait_for("the turn prompt") { prompts.last == "> " }
      push("type" => "question_requested", "pending_question" => approval.merge("id" => "a2"))
      wait_for("the question prompt") { prompts.last == "? " }
      typed << ""
      wait_for("the turn prompt") { prompts.last == "> " }
      finish
      expect(client).to have_received(:answer).with(id: "a1", selected: ["Deny"], freeform: "use a PR")
      expect(client).to have_received(:dismiss_question).with(id: "a2")
      expect(screen.lines).to include("! execute: git push → Deny: use a PR", "! execute: git push → (denied)")
    end
  end

  it "re-asks after an invalid answer, and closes when another UI answers first" do
    start
    push("type" => "question_requested", "pending_question" => question)
    wait_for("the question prompt") { prompts.last == "? " }

    typed << "9"
    wait_for("the line Invalid choice '9': pick 1-3") { screen.lines.include?("Invalid choice '9': pick 1-3") }
    expect(screen.lines.last(2)).to eq(["? 9", "Invalid choice '9': pick 1-3"])
    push("type" => "question_answered", "id" => "q1", "answer" => { "selected" => ["Apple"], "freeform" => nil })
    wait_for("the turn prompt") { prompts.last == "> " }
    finish

    expect(screen.lines).to include("? Which one? → Apple (in another UI)")
  end

  it "clears the choices and says so when the turn ends with the question open" do
    start
    push("type" => "question_requested", "pending_question" => question)
    wait_for("the notes") { screen.slots[:notes] }

    push("type" => "turn_canceled", "cancellation_reason" => "ctrl_c")
    wait_for("the turn prompt") { prompts.last == "> " }
    finish

    expect(screen.slots).not_to have_key(:notes)
    expect(screen.lines).to include("? Which one? → (the turn ended)")
  end

  it "reads the answer without echo (only the summary line stays)" do
    echo = []
    allow(Reline).to receive(:readline) { echo << !Thread.current[:samagotchi_reline_no_echo]; "2" }
    allow($stdin).to receive(:tty?).and_return(true)
    attached.instance_variable_set(:@question, Samagotchi::TerminalUI::QuestionPrompt.new(question))

    attached.send(:read_input_line, "? ", nil)

    expect(echo).to eq([false])
  end

  it "says so when its answer came too late" do
    allow(client).to receive(:answer)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 409, body: '{"error":"question_not_pending"}'))
    start(first: snapshot(pending_question: question))
    wait_for("the question prompt") { prompts.last == "? " }

    typed << "1"
    wait_for("the turn prompt") { prompts.last == "> " }
    finish

    expect(screen.lines).to include("? Which one? → (already answered in another UI)")
  end

  it "dismisses the question on an empty answer, as the REPL does" do
    allow(client).to receive(:dismiss_question).and_return(Samagotchi::BridgeClient::Response.new(status: 200))
    start(first: snapshot(pending_question: question))
    wait_for("the question prompt") { prompts.last == "? " }

    typed << "  "
    wait_for("the turn prompt") { prompts.last == "> " }
    # Every UI gets the cancel, this one too: it is already closed here.
    push("type" => "question_cancelled", "id" => "q1", "reason" => "dismissed")
    finish

    expect(client).to have_received(:dismiss_question).with(id: "q1")
    expect(screen.lines).to include("? Which one? → (cancelled)")
    expect(screen.lines.join("\n")).not_to include("(question cancelled)")
  end

  it "closes the question when it was answered or cancelled before the dismiss" do
    allow(client).to receive(:dismiss_question)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 409, body: '{"error":"question_not_pending"}'))
    start(first: snapshot(pending_question: question))
    wait_for("the question prompt") { prompts.last == "? " }

    typed << ""
    wait_for("the turn prompt") { prompts.last == "> " }
    finish

    expect(screen.lines).to include("? Which one? → (question already closed in another UI)")
  end

  it "keeps the question open when the worker can't dismiss it" do
    allow(client).to receive(:dismiss_question)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 404, body: '{"error":"not_found"}'))
    start(first: snapshot(pending_question: question))
    wait_for("the question prompt") { prompts.last == "? " }

    typed << ""
    wait_for("the line Ctrl-C cancels the turn") { screen.lines.last.to_s.end_with?("Ctrl-C cancels the turn") }
    finish

    expect(screen.lines).to include("this session's worker runs an older chi and can't dismiss questions; " \
                                    "restart it: chi sessions stop s-1234 && chi --resume s-1234 (its turns still work); " \
                                    "Ctrl-C cancels the turn")
    expect(prompts.last).to eq("? ")
  end

  it "keeps the question open when the worker doesn't answer the answer or the dismiss" do
    allow(client).to receive(:answer).and_raise(Errno::ETIMEDOUT.new("bridge answer: no reply within 30s"))
    allow(client).to receive(:dismiss_question).and_raise(Errno::ECONNREFUSED)
    start(first: snapshot(pending_question: question))
    wait_for("the question prompt") { prompts.last == "? " }

    typed << "1"
    wait_for("the line could not answer") { screen.lines.last.to_s.start_with?("could not answer") }
    typed << ""
    wait_for("the line could not dismiss") { screen.lines.last.to_s.start_with?("could not dismiss") }
    finish

    expect(screen.lines).to include("could not answer (worker not answering: no reply within 30s)",
                                    "could not dismiss the question (worker unreachable: connection refused); " \
                                    "Ctrl-C cancels the turn")
    expect(prompts.last).to eq("? ")
  end

  it "keeps the question open when the worker dropped the answer or the dismiss as too late" do
    late = Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}')
    allow(client).to receive_messages(answer: late, dismiss_question: late)
    start(first: snapshot(pending_question: question))
    wait_for("the question prompt") { prompts.last == "? " }

    typed << "1"
    wait_for("the line could not answer") { screen.lines.last.to_s.start_with?("could not answer") }
    typed << ""
    wait_for("the line could not dismiss") { screen.lines.last.to_s.start_with?("could not dismiss") }
    finish

    expect(screen.lines).to include("could not answer (worker not answering in time)",
                                    "could not dismiss the question (worker not answering in time); Ctrl-C cancels the turn")
    expect(prompts.last).to eq("? ")
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "answering the continue offer" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:typed) { Queue.new }
  let(:prompts) { [] }

  it "sends a bare answer as /continue <answer>, an empty one as /continue, and commands as they are" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    offer = { "type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [],
                                                    "continue_offer" => { "context" => {}, "no_interrupt" => false } } }
    allow(client).to receive(:follow) { |&block| block.call(offer) && double("stream", close: nil) }
    # Reads block until typed into, like Reline.
    thread = Thread.new { attached.run(input: ->(prompt, _prefill) { prompts << prompt; typed.pop }) }
    wait_for("the question prompt") { prompts.last == "? " }

    ["no, too slow", "", "/model", nil].each { |line| typed << line }
    thread.join(2)

    # A command at the offer ran without echo: its line shows as typed.
    expect(screen.lines).to include("? /model")
    expect(screen.lines).not_to include("? no, too slow", "? ")

    expect(client).to have_received(:post_command).with(line: "/continue no, too slow", client_id: "tui:1")
    expect(client).to have_received(:post_command).with(line: "/continue", client_id: "tui:1")
    expect(client).to have_received(:post_command).with(line: "/model", client_id: "tui:1")
  end

  it "sends a parent agent's yes at the offer as chi answer's (cli:answer), its no as its own" do
    parent = described_class.new(client: client, screen: screen, client_id: "tui:1", as_parent: true)
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    offer = { "type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [],
                                                    "continue_offer" => { "context" => {}, "no_interrupt" => false } } }
    allow(client).to receive(:follow) { |&block| block.call(offer) && double("stream", close: nil) }
    thread = Thread.new { parent.run(input: ->(prompt, _prefill) { prompts << prompt; typed.pop }) }
    wait_for("the question prompt") { prompts.last == "? " }

    ["", "no", nil].each { |line| typed << line }
    thread.join(2)

    expect(client).to have_received(:post_command).with(line: "/continue", client_id: "cli:answer")
    expect(client).to have_received(:post_command).with(line: "/continue no", client_id: "tui:1")
  end

  # P3 (H1): a parent attach's /parent-answers goes as chi answer's
  # (cli:answer), so the worker never takes it as a user's loosening: typed,
  # as -p's first prompt, or as /cut and /queue text (which the Bridge runs
  # as the command). A user's attach sends its own id.
  describe "a /parent-answers line" do
    let(:ok) { Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1","enqueued_id":"e1"}') }

    before do
      allow(client).to receive(:post_command).and_return(ok)
      allow(client).to receive(:post_turn).and_return(ok)
    end

    def sent_ids
      commands = []
      turns = []
      allow(client).to receive(:post_command) { |**kw| commands << kw.slice(:line, :client_id); ok }
      allow(client).to receive(:post_turn) { |**kw| turns << kw.slice(:prompt, :client_id); ok }
      yield
      [commands, turns]
    end

    it "goes as cli:answer from a parent attach, every route" do
      parent = described_class.new(client: client, screen: screen, client_id: "tui:1", as_parent: true,
                                   first_prompt: "/parent-answers soft")
      commands, turns = sent_ids do
        parent.send(:submit, "/parent-answers soft")
        parent.send(:submit, "/queue /parent-answers soft")
        parent.send(:submit, "/cut /parent-answers standard")
        parent.handle_event({ type: :turn_started, turn_id: "t1" })
        parent.send(:submit, "/queue /parent-answers soft")
        parent.send(:send_first_prompt)
        parent.send(:submit, "/model")
        parent.send(:submit, "hello")
      end
      expect(commands).to include({ line: "/parent-answers soft", client_id: "cli:answer" })
      expect(commands).to include({ line: "/model", client_id: "tui:1" })
      expect(commands.count { |c| c[:line] == "/parent-answers soft" }).to eq(2)
      expect(turns.select { |t| t[:prompt].start_with?("/parent-answers") }.map { |t| t[:client_id] }.uniq).to eq(["cli:answer"])
      expect(turns.size).to be >= 3
      expect(turns).to include({ prompt: "hello", client_id: "tui:1" })
    end

    it "goes with its own id from a user's attach" do
      commands, turns = sent_ids do
        attached.send(:submit, "/parent-answers soft")
        attached.send(:submit, "/queue /parent-answers soft")
      end
      expect(commands).to eq([{ line: "/parent-answers soft", client_id: "tui:1" }])
      expect(turns).to eq([{ prompt: "/parent-answers soft", client_id: "tui:1" }])
    end
  end

  it "leaves one line with its own answer once the worker resolves the offer" do
    allow(client).to receive(:post_command).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"command_id":"c1"}'))
    attached.handle_event({ type: :continue_offered, context: {}, no_interrupt: false })

    attached.send(:submit, "maybe")
    expect(screen.lines.last).to eq("? maybe")
    attached.send(:submit, "no, too slow")
    attached.handle_event({ type: :continue_resolved, decision: "abort_with_reason", client_id: "tui:1" })

    expect(screen.lines.last).to eq("? The turn ran out of iterations. Continue it? → no, too slow")
    expect(screen.slots).not_to have_key(:notes)
  end
end
