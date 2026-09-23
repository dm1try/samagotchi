# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "samagotchi/terminal_ui"
require_relative "support/virtual_terminal"

# The REPL on a live region: a Screen on a virtual terminal, with the REPL's
# reads and the kernel stubbed as in the goldens. These check what stays on
# the terminal, not the bytes.
RSpec.describe Samagotchi::TerminalUI, "on a live region" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:history_dir) { Dir.mktmpdir("live-region-history") }
  let(:term) { VirtualTerminal.new(rows: 12, columns: 50) }
  let(:screen) { Samagotchi::TerminalUI::Screen.new(out: term, size: -> { [term.rows, term.columns] }) }

  around do |example|
    keys = %w[SAMAGOTCHI_DEFAULT_MODEL SAMAGOTCHI_HISTORY_FILE SAMAGOTCHI_THINKING_PREVIEW_LINES SAMAGOTCHI_STATUS_LINE XDG_STATE_HOME]
    saved = ENV.to_h.slice(*keys)
    ENV["SAMAGOTCHI_HISTORY_FILE"] = File.join(history_dir, "history.json")
    ENV["XDG_STATE_HOME"] = history_dir
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Qwen3-14B"
    ENV.delete("SAMAGOTCHI_THINKING_PREVIEW_LINES")
    ENV.delete("SAMAGOTCHI_STATUS_LINE")
    example.run
  ensure
    keys.each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(history_dir)
  end

  before do
    allow(Reline).to receive(:ambiguous_width).and_return(1)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
  end

  def build_ui(surface: screen, **options)
    ui = described_class.new(mode: :assist, client: client, no_default_input: true, surface: surface, **options)
    allow(ui).to receive(:thinking_spinner_enabled?).and_return(true)
    allow(ui).to receive(:color_output?).and_return(false)
    allow(ui).to receive(:thinking_render_min_interval).and_return(0.0)
    allow(ui).to receive(:status_server_segment).and_return("")
    ui
  end

  # Everything the terminal has shown that is still there: scrollback, then
  # the screen.
  def shown = term.scrollback + term.lines

  # One Qwen generation, chunk events as KernelLoop emits them.
  def generation(*pieces)
    splitter = Samagotchi::ThoughtStreamSplitter.for_profile(Samagotchi::ModelProfile.normalize("Qwen3-14B"))
    [{ type: :generation_started, iteration: 1 }] +
      pieces.map do |content|
        { type: :generation_chunk, iteration: 1, content: content, thinking: splitter.feed(content)[:thinking],
          payload: { "content" => content } }
      end +
      [{ type: :generation_completed, iteration: 1, content_length: pieces.join.length }]
  end

  # Run the REPL: +prompts+ feed the main prompt; the kernel replays +events+
  # and calls +on_event+ with each one after it is drawn.
  def run_repl(ui, prompts:, events: [], on_event: nil)
    allow(Reline).to receive(:readmultiline).and_return(*prompts, nil)
    allow(ui.instance_variable_get(:@kernel)).to receive(:run) do |messages, **kwargs|
      events.each do |event|
        kwargs[:on_stream_event]&.call(event)
        on_event&.call(event)
      end
      Samagotchi::KernelLoop::Result.new(
        output: "PONG", conversation: messages + [{ role: "model", content: "PONG" }],
        exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false
      )
    end
    ui.run
  end

  it "shows the spinner row above the status rows while a turn runs, and drops it after" do
    ui = build_ui
    regions = []
    run_repl(ui, prompts: ["hi"], events: generation("<think>TURN: Checking\n", "a", "</think>PONG"),
                 on_event: ->(event) { regions << term.lines.last(2) if event[:type] == :generation_chunk })

    expect(regions.last).to match([a_string_starting_with("chi> Checking"), a_string_starting_with("status> model=Qwen3-14B")])
    expect(shown.grep(/^chi> Checking/)).to be_empty
    expect(shown).to include("PONG")
  end

  # The drift from the smoke-run notes: a spinner row wider than the terminal
  # (a long turn phrase at 50 columns) wrapped, each redraw landed a row
  # lower and left a copy behind.
  it "keeps one spinner row and one status row when they are wider than the terminal" do
    ui = build_ui
    allow(ui).to receive(:status_effective_width).and_return(100)
    phrase = "TURN: Comparing the two decimal numbers carefully before answering\n"
    counts = []
    run_repl(ui, prompts: ["hi"], events: generation("<think>#{phrase}", *(["more "] * 8), "</think>PONG"),
                 on_event: ->(_event) { counts << [shown.grep(/^chi> Comparing/).size, shown.grep(/^status> /).size] })

    expect(counts).to all(satisfy { |spinner, status| spinner <= 1 && status <= 1 })
    expect(counts).to include([1, 1])
  end

  it "keeps the idle status line as one live row below the prompt" do
    ui = build_ui
    at_third_prompt = nil
    reads = 0
    allow(Reline).to receive(:readmultiline) do
      reads += 1
      at_third_prompt = shown if reads == 3
      reads < 3 ? "/stats" : nil
    end
    ui.run

    expect(at_third_prompt.grep(/^status> /)).to eq(["status> model=Qwen3-14B"])
    expect(at_third_prompt.last).to eq("status> model=Qwen3-14B")
  end

  it "takes Ctrl-C at the prompt while the REPL runs, on a plain surface too" do
    ui = build_ui(surface: nil)
    handler_at_prompt = nil
    allow(Reline).to receive(:readmultiline) do
      handler_at_prompt = Samagotchi::TerminalUI::RelineSeam.interrupt_handler
      nil
    end

    expect { ui.run }.to output.to_stdout

    expect(handler_at_prompt).to respond_to(:call)
    expect(Samagotchi::TerminalUI::RelineSeam.interrupt_handler).to be_nil
  end

  describe "a reminder due while the prompt is open" do
    let(:ui) { build_ui }
    let(:engine) { ui.instance_variable_get(:@engine) }
    let(:typed) { Queue.new }
    let(:kernel_calls) { [] }

    before do
      allow($stdin).to receive(:tty?).and_return(true)
      allow(STDIN).to receive(:tty?).and_return(true)
      allow(engine).to receive(:reminders_due?).and_return(true)
      reads = 0
      # The first prompt stays open (like a Reline read with text typed in
      # it) until the spec submits a line; the reminder falls due meanwhile.
      allow(Reline).to receive(:readmultiline) do
        reads += 1
        next nil if reads > 1

        engine.note_due_reminders(%w[stretch])
        typed.pop
      end
      @reads = -> { reads }
    end

    def kernel_replies(&during)
      allow(ui.instance_variable_get(:@kernel)).to receive(:run) do |messages, **kwargs|
        kernel_calls << messages
        canceled = during&.call(kwargs[:cancel_controller], kernel_calls.size) || false
        Samagotchi::KernelLoop::Result.new(
          output: "PONG #{kernel_calls.size}", conversation: messages + [{ role: "model", content: "PONG" }],
          exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: canceled,
          cancellation_reason: (canceled ? :ctrl_c : nil)
        )
      end
    end

    it "runs its turn with the prompt kept open, then takes the line typed there" do
      during_reminder = nil
      kernel_replies do |_controller, call|
        if call == 1
          during_reminder = { reads: @reads.call, lines: term.lines.dup }
          typed << "hi" # submitted while the reminder turn runs
        end
        false
      end

      ui.run

      expect(during_reminder[:reads]).to eq(1)
      expect(during_reminder[:lines]).to include("reminder: stretch · Ctrl-C cancels it")
      expect(kernel_calls.last).to include(hash_including(role: "user", content: "hi"))
      expect(shown).to include("PONG 1", "PONG 2")
      expect(shown.grep(/reminder: stretch/)).to be_empty
    end

    it "cancels only the reminder turn on Ctrl-C and keeps the prompt" do
      kernel_replies do |controller, call|
        next false unless call == 1

        # Ctrl-C with the prompt open: Reline's trap -> the seam's handler.
        handled = Samagotchi::TerminalUI::RelineSeam.interrupt_handler.call
        typed << "hi"
        handled && controller.cancelled?
      end

      ui.run

      expect(@reads.call).to eq(2) # the open prompt, then the one after "hi"
      expect(shown).to include("model> request cancelled (ctrl-c)")
      expect(kernel_calls.last).to include(hash_including(role: "user", content: "hi"))
    end
  end

  describe "choosing the surface" do
    it "opens a live region for the REPL and closes it at exit" do
      allow(Samagotchi::TerminalUI::LiveRegion).to receive(:open).and_return(screen)
      allow(Samagotchi::TerminalUI::LiveRegion).to receive(:close)
      ui = build_ui(surface: nil)

      run_repl(ui, prompts: [])

      expect(Samagotchi::TerminalUI::LiveRegion).to have_received(:close).with(screen)
      expect(shown).to include(a_string_starting_with("Continue session: chi --resume"))
    end

    it "prints plainly when the terminal can't show a live region" do
      ui = build_ui(surface: nil)

      expect { run_repl(ui, prompts: []) }.to output(/Continue session: chi --resume/).to_stdout
      expect(term.lines).to be_empty
    end

    it "draws on a surface it was given, and leaves it open" do
      expect(Samagotchi::TerminalUI::LiveRegion).not_to receive(:open)
      expect(Samagotchi::TerminalUI::LiveRegion).not_to receive(:close)
      ui = build_ui

      run_repl(ui, prompts: [])

      expect(shown).to include(a_string_starting_with("Continue session: chi --resume"))
    end

    it "opens none for a headless prompt (--non-interactive)" do
      expect(Samagotchi::TerminalUI::LiveRegion).not_to receive(:open)
      ui = build_ui(surface: nil, prompt: "hi", non_interactive: true)

      expect { run_repl(ui, prompts: []) }.to output(/PONG/).to_stdout
    end
  end
end
