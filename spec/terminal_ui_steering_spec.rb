# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"
require_relative "support/recording_surface"

# REPL steering: a line submitted at the open prompt while a turn runs.
RSpec.describe Samagotchi::TerminalUI, "steering" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:surface) { RecordingSurface.new }
  let(:agent) { described_class.new(client: client, surface: surface) }
  let(:engine) { agent.engine }
  let(:session) { instance_double(Samagotchi::Session, id: "s1", messages: [], used_memory_names: []) }
  # A session something happened in: the REPL keeps it at exit.
  let(:used_session) do
    instance_double(Samagotchi::Session, id: "s1", used_memory_names: [], "messages=": nil, messages: [{ role: "user", content: "go" }], last_prompt: "go")
  end
  let(:repl_input) { Samagotchi::TerminalUI::ReplInput.new(prompt: -> { "> " }, read: ->(*) {}, surface: surface) }
  let(:result) { Samagotchi::LLM::ModelResult.new(text: "ok", conversation: [], tool_activity: []) }

  before do
    agent.instance_variable_set(:@pending_input_queue, Samagotchi::PendingInputQueue.new)
    agent.instance_variable_set(:@repl_input, repl_input)
    allow(agent).to receive(:persist_recent_history)
  end

  it "merges a line submitted during the turn at the next iteration boundary" do
    drained = nil
    allow(engine).to receive(:run_turn) do |*, pending_input:, **|
      repl_input << [:line, "also check #mem"]
      drained = pending_input.call
      result
    end

    agent.run_engine_turn(session, "go")

    expect(drained).to eq(["also check #mem"])
    expect(agent).to have_received(:persist_recent_history).with("also check #mem")
    expect(repl_input.pop(timeout: 0)).to be_nil
  end

  it "runs a line that came after the last iteration as the next turn" do
    allow(engine).to receive(:run_turn) do |*, pending_input:, **|
      pending_input.call
      repl_input << [:line, "too late to merge"]
      result
    end

    agent.run_engine_turn(session, "go")

    expect(repl_input.pop(timeout: 0)).to eq([:line, "too late to merge"])
  end

  it "leaves a line sent after Ctrl-C (even a command) for after the turn" do
    allow(engine).to receive(:run_turn) do |*, cancel_controller:, **|
      cancel_controller.cancel!(:ctrl_c)
      repl_input << [:line, "next"] << [:line, "!ls"]
      result
    end

    agent.run_engine_turn(session, "go")

    expect(Array.new(2) { repl_input.pop(timeout: 0).last }).to eq(["next", "!ls"])
  end

  it "runs /stats at once and puts another command back into the prompt, busy" do
    reader = double("reader", prefill_next: nil)
    repl_input.instance_variable_set(:@reader, reader)
    allow(engine).to receive(:stats_snapshot).and_return({})
    allow(agent).to receive(:format_session_metrics).and_return("turns: 1")
    allow(engine).to receive(:run_turn) do
      repl_input << [:line, "/stats"] << [:line, "!ls"]
      result
    end

    agent.run_engine_turn(session, "go")

    expect(surface.lines).to include("\nmodel> session stats:\nturns: 1", "busy: wait for the turn to end")
    expect(reader).to have_received(:prefill_next).with("!ls")
    expect(repl_input.pop(timeout: 0)).to be_nil
  end

  describe "a plugin's command" do
    let(:reader) { double("reader", prefill_next: nil) }

    before do
      repl_input.instance_variable_set(:@reader, reader)
      agent.instance_variable_set(:@commands, Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine),
                                                                              default_model: "m", registry: engine.command_registry))
    end

    it "is busy mid-turn and goes back into the prompt, a normal one" do
      engine.command_registry.register("/hello", "greet", source: "b") { |_args| "hi" }
      allow(engine).to receive(:run_turn) do
        repl_input << [:line, "/hello"]
        result
      end

      agent.run_engine_turn(session, "go")

      expect(surface.lines).to include("busy: wait for the turn to end")
      expect(reader).to have_received(:prefill_next).with("/hello")
    end

    it "runs at once on its own thread mid-turn, an anytime one, printing while the turn goes on" do
      started = Queue.new
      engine.command_registry.register("/side", "side", anytime: true, source: "b") do |args|
        started << Thread.current
        "side: #{args}"
      end
      lines_mid_turn = nil
      allow(engine).to receive(:turn_running?).and_return(true)
      allow(engine).to receive(:run_turn) do
        repl_input << [:line, "/side q"]
        thread = started.pop
        thread.join(2)
        lines_mid_turn = surface.lines.dup
        result
      end

      agent.run_engine_turn(session, "go")

      expect(lines_mid_turn).to include("\nmodel> side: q")
      expect(surface.lines).not_to include("busy: wait for the turn to end")
      expect(reader).not_to have_received(:prefill_next)
    end

    it "prints an anytime command's cards mid-turn as it shows them, not as the turn's" do
      started = Queue.new
      engine.command_registry.register("/side", "side", anytime: true, source: "b") do |_args|
        engine.show_card(source: "b", title: "thinking…", id: "c1")
        engine.show_card(source: "b", title: "answer", id: "c1")
        started << Thread.current
        nil
      end
      lines_mid_turn = nil
      allow(engine).to receive(:turn_running?).and_return(true)
      allow(engine).to receive(:run_turn) do
        repl_input << [:line, "/side q"]
        started.pop.join(2)
        lines_mid_turn = surface.lines.flat_map { |line| line.split("\n") }
        result
      end

      agent.run_engine_turn(session, "go")

      expect(lines_mid_turn).to include("┌ thinking… · b", "┌ answer (updated) · b")
    end

    it "keeps an anytime command's output for the prompt's flush once the turn has ended" do
      engine.command_registry.register("/side", "side", anytime: true, source: "b") { |_args| "later" }
      thread = nil
      allow(Thread).to receive(:new).and_wrap_original { |original, &block| thread = original.call(&block) }
      allow(engine).to receive(:turn_running?).and_return(false)

      agent.send(:start_anytime_command, "/side")
      thread.join(2)
      expect(surface.lines).not_to include("\nmodel> later")
      agent.between_turns.flush_cards

      expect(surface.lines).to include("\nmodel> later")
    end
  end

  %w[Ctrl-D exit].each do |key|
    it "exits after the turn on #{key}, and says so" do
      line = key == "exit" ? "/exit" : nil
      allow(engine).to receive(:run_turn) do
        repl_input << [:line, line]
        result
      end

      agent.run_engine_turn(session, "go")

      expect(surface.lines).to include("(exits after this turn; Ctrl-C cancels it)")
      expect(agent.exit_after_turn?).to be(true)
      expect(repl_input.pop(timeout: 0)).to be_nil
    end
  end

  it "exits after the turn on /exit --delete, and deletes the session then" do
    allow(engine).to receive(:run_turn) do
      repl_input << [:line, "/exit --delete"]
      result
    end

    agent.run_engine_turn(session, "go")

    expect(surface.lines).to include("(exits after this turn and deletes the session; Ctrl-C cancels the turn)")
    expect(agent.exit_after_turn?).to be(true)
    expect(agent.exit_action).to eq(:delete)
  end

  # The same exit words as the attached TUI's (SessionCommands' local entries).
  ["/quit", "/QUIT --delete", "EXIT --DELETE"].each do |line|
    it "ends the loop on #{line}, as on /exit" do
      allow(agent).to receive(:poll_input_with_reminder_check).and_return(line, "never read", nil)
      allow(agent).to receive(:run_input_line)
      allow(agent).to receive(:drain_pending_question?)

      agent.run_assist_loop(session: used_session, messages: [])

      expect(agent).not_to have_received(:run_input_line)
      expect(agent.exit_action == :delete).to be(line.downcase.end_with?("--delete"))
    end
  end

  it "exits after the turn on /quit typed during it" do
    allow(engine).to receive(:run_turn) do
      repl_input << [:line, "/quit"]
      result
    end

    agent.run_engine_turn(session, "go")

    expect(surface.lines).to include("(exits after this turn; Ctrl-C cancels it)")
    expect(agent.exit_after_turn?).to be(true)
  end

  it "puts /archive typed during a turn back in the prompt instead of merging it into the turn" do
    drained = nil
    allow(engine).to receive(:run_turn) do |*, pending_input:, **|
      repl_input << [:line, "/archive"]
      drained = pending_input.call
      result
    end

    agent.run_engine_turn(session, "go")

    expect(drained).to eq([])
    expect(surface.lines).to include(described_class::COMMAND_BUSY)
  end

  it "ends the loop on /exit --delete without the resume line" do
    allow(agent).to receive(:poll_input_with_reminder_check).and_return("/exit --delete", nil)
    allow(agent).to receive(:run_input_line)
    allow(agent).to receive(:drain_pending_question?)

    agent.run_assist_loop(session: used_session, messages: [])

    expect(agent).not_to have_received(:run_input_line)
    expect(agent.exit_action).to eq(:delete)
    expect(surface.lines.join("\n")).not_to include("Continue session")
  end

  describe "the recap at exit" do
    it "writes one, saying so while it waits" do
      allow(engine).to receive(:write_recap_now) { |on_start:| on_start.call; "Done." }
      agent.recap_after_exit
      expect(surface.lines).to include("writing a recap…")
    end

    it "says nothing when there is nothing new to recap" do
      allow(engine).to receive(:write_recap_now).and_return(nil)
      agent.recap_after_exit
      expect(surface.lines).not_to include("writing a recap…")
    end

    it "gives up on Ctrl-C" do
      allow(engine).to receive(:write_recap_now).and_raise(Interrupt)
      expect { agent.recap_after_exit }.not_to raise_error
    end

    it "comes before the resume line, which ends the REPL's output" do
      allow(agent).to receive(:poll_input_with_reminder_check).and_return("/exit")
      allow(agent).to receive(:drain_pending_question?)
      allow(engine).to receive(:write_recap_now) { |on_start:| on_start.call; "Done." }

      agent.run_assist_loop(session: used_session, messages: [])
      agent.keep_after_exit(used_session)

      expect(surface.lines.last(2)).to eq(["writing a recap…", "\nContinue session: chi --resume s1"])
    end
  end

  describe "an empty session at exit" do
    let(:state_dir) { Dir.mktmpdir("repl-empty") }
    # The REPL's working copy starts with its system prompt.
    let(:empty_session) do
      instance_double(Samagotchi::Session, id: "s-empty", used_memory_names: [], "messages=": nil, messages: [{ role: "system", content: "You are chi." }],
                                           last_prompt: "")
    end

    before do
      allow(Samagotchi::Session).to receive(:default_state_dir).and_return(state_dir)
      allow(agent).to receive(:poll_input_with_reminder_check).and_return("/exit")
      allow(agent).to receive(:drain_pending_question?)
      # What claim_session! leaves: the directory with its owner lock.
      FileUtils.mkdir_p(File.join(state_dir, "s-empty"))
      File.write(File.join(state_dir, "s-empty", "owner.lock"), "")
    end

    after { FileUtils.rm_rf(state_dir) }

    it "is discarded, without the resume line" do
      agent.run_assist_loop(session: empty_session, messages: [])
      expect(surface.lines.join("\n")).not_to include("Continue session")
      expect(agent.exit_action).to eq(:discard)

      agent.discard_after_exit(empty_session)
      expect(surface.lines.last).to eq("The session was empty, so it is discarded.")
      expect(Dir.exist?(File.join(state_dir, "s-empty"))).to be(false)
    end

    it "is kept on another model than the default (/model, --model)" do
      agent.instance_variable_set(:@effective_model_name, "some/other-model")

      agent.run_assist_loop(session: empty_session, messages: [])

      expect(agent.exit_action).not_to eq(:discard)
    end

    it "is kept with session.keep_empty" do
      allow(Samagotchi::SessionManager).to receive(:discard_empty?).and_return(false)

      agent.run_assist_loop(session: empty_session, messages: [])

      expect(agent.exit_action).not_to eq(:discard)
    end
  end

  it "says /detach has nothing to detach from, during a turn too, and sends nothing" do
    drained = nil
    allow(engine).to receive(:run_turn) do |*, pending_input:, **|
      repl_input << [:line, "/detach"]
      drained = pending_input.call
      result
    end

    agent.run_engine_turn(session, "go")

    expect(drained).to eq([])
    expect(surface.lines).to include(described_class::REPL_DETACH_NOTE)
  end

  it "answers /detach at the prompt with the note, and reads on" do
    allow(agent).to receive(:poll_input_with_reminder_check).and_return("/DETACH", nil)
    allow(agent).to receive(:run_input_line)
    allow(agent).to receive(:drain_pending_question?)

    agent.run_assist_loop(session: used_session, messages: [])

    expect(agent).not_to have_received(:run_input_line)
    expect(surface.lines).to include("(not attached: this session runs in this terminal; /exit ends it)")
  end

  it "runs /stats and /recap at a continue offer instead of reading them as an answer" do
    turn_flow = agent.instance_variable_get(:@turn_flow)
    allow(turn_flow).to receive(:awaiting_continue?).and_return(true)
    allow(agent).to receive(:poll_input_with_reminder_check).and_return("/stats", "/recap", nil)
    allow(agent).to receive(:drain_pending_question?)
    allow(agent).to receive(:answer_continue_offer)
    allow(engine).to receive(:stats_snapshot).and_return({})
    allow(agent).to receive(:format_session_metrics).and_return("turns: 1")
    allow(agent).to receive(:handle_recap_command).and_return("recap is off")

    agent.run_assist_loop(session: used_session, messages: [])

    expect(agent).not_to have_received(:answer_continue_offer)
    expect(surface.lines).to include("? /stats", "\nmodel> session stats:\nturns: 1", "? /recap", "\nmodel> recap is off")
  end

  it "ends the loop after the turn instead of reading on" do
    allow(agent).to receive(:poll_input_with_reminder_check).and_return("go", "never read", nil)
    allow(agent).to receive(:run_input_line) { agent.instance_variable_set(:@exit_after_turn, true) }
    allow(agent).to receive(:drain_pending_question?)

    agent.run_assist_loop(session: used_session, messages: [])

    expect(agent).to have_received(:run_input_line).once
    expect(agent.exit_action).not_to eq(:discard)
  end

  it "still runs the lines sent before Ctrl-D, then exits" do
    agent.instance_variable_set(:@exit_after_turn, true)
    repl_input << [:line, "sent before"]
    allow(agent).to receive(:run_input_line)
    allow(agent).to receive(:poll_input_with_reminder_check)

    agent.run_assist_loop(session: used_session, messages: [])

    expect(agent).to have_received(:run_input_line).once.with(anything, "sent before")
    expect(agent).not_to have_received(:poll_input_with_reminder_check)
  end
end
