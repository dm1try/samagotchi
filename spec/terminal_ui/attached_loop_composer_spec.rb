# frozen_string_literal: true

require "json"
require "samagotchi/worker_link"
require_relative "../support/worker_fixtures"
require_relative "../support/worker_links"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "input parity with the REPL" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:history_dir) { Dir.mktmpdir("attached-history") }
  let(:ack) { Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e1","command_id":"c1"}') }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_HISTORY_FILE", "SAMAGOTCHI_DEFAULT_INPUT")
    ENV["SAMAGOTCHI_HISTORY_FILE"] = File.join(history_dir, "history.json")
    example.run
  ensure
    %w[SAMAGOTCHI_HISTORY_FILE SAMAGOTCHI_DEFAULT_INPUT].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(history_dir)
    Reline::HISTORY.clear
  end

  before do
    allow(client).to receive(:follow) do |&block|
      block.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 })
      double("stream", close: nil)
    end
    allow(client).to receive_messages(post_turn: ack, post_command: ack)
  end

  def run_loop(inputs, **opts)
    reads = []
    described_class.new(client: client, screen: screen, client_id: "tui:1", **opts)
                   .run(input: ->(_prompt, prefill) { reads << prefill; inputs.shift })
    reads
  end

  it "keeps what was typed in the REPL's history file, and loads it on the next run" do
    run_loop(["hello", "!ls", "/model", "!rollback", "/stats"].tap { allow(client).to receive(:get_json) })

    expect(JSON.parse(File.read(ENV["SAMAGOTCHI_HISTORY_FILE"]))).to eq(["hello", "!ls"])
    Reline::HISTORY.clear
    run_loop([])
    expect(Reline::HISTORY.to_a).to eq(["hello", "!ls"])
  end

  it "sends #name as typed, as the REPL does" do
    run_loop(["PR #1: check #notes and #project/todo"])

    expect(client).to have_received(:post_turn)
      .with(prompt: "PR #1: check #notes and #project/todo", client_id: "tui:1")
  end

  it "offers the attached commands on Tab, /quit, /queue and /unqueue too" do
    attached = described_class.new(client: client, screen: screen, client_id: "tui:1")

    expect(attached.send(:assist_path_completion_candidates, "/q")).to eq(%w[/queue /quit])
    expect(attached.send(:assist_path_completion_candidates, "/u")).to eq(["/unqueue"])
    expect(attached.send(:assist_path_completion_candidates, "/mo")).to eq(%w[/model /models])
  end

  it "types the default input into a new session's first read, unless told not to" do
    ENV["SAMAGOTCHI_DEFAULT_INPUT"] = "Please "

    expect(run_loop([nil], default_input: true)).to eq(["Please "])
    expect(run_loop([nil], default_input: false)).to eq([nil])
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "Ctrl-C and exit at an idle prompt (D4)" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:now) { [0.0] }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", clock: -> { now.first }) }

  before do
    allow(client).to receive(:follow) do |&block|
      block.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 })
      double("stream", close: nil)
    end
    allow(client).to receive(:cancel)
  end

  after { Samagotchi::TerminalUI::RelineSeam.interrupt_handler = nil }

  # Each entry is a read: a line, nil (Ctrl-D), or [:ctrl_c, typed, at] for a
  # Ctrl-C with +typed+ in the line at time +at+ (Reline's seam sees the text
  # before the read ends).
  def run_reads(*reads)
    attached.run(input: lambda do |_prompt, _prefill|
      entry = reads.shift
      return entry unless entry.is_a?(Array)

      _, typed, at = entry
      now[0] = at
      allow(Reline).to receive(:line_buffer).and_return(typed)
      Samagotchi::TerminalUI::RelineSeam.interrupt_handler&.call
      raise Interrupt
    end)
  end

  it "says how to detach on a first Ctrl-C at an empty prompt, and detaches on a second within 2 s" do
    expect(run_reads([:ctrl_c, "", 10.0], [:ctrl_c, "", 11.5])).to eq(:detached)

    expect(screen.lines).to include("Ctrl-D to detach, /exit stops the worker")
    expect(screen.lines.last).to start_with("Detached; the session keeps running.")
    expect(client).not_to have_received(:cancel)
  end

  it "only says it again when the second press comes later" do
    expect(run_reads([:ctrl_c, "", 10.0], [:ctrl_c, "", 13.0], nil)).to eq(:detached)

    expect(screen.lines.count("Ctrl-D to detach, /exit stops the worker")).to eq(2)
  end

  it "takes a Ctrl-C that cleared typed text as just that" do
    expect(run_reads([:ctrl_c, "half typed", 10.0], [:ctrl_c, "", 10.5], nil)).to eq(:detached)

    expect(screen.lines.count("Ctrl-D to detach, /exit stops the worker")).to eq(1)
  end

  it "cancels a running turn on Ctrl-C and leaves the typed text in the prompt (the read goes on)" do
    allow(client).to receive(:follow) do |&block|
      block.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => { "prompt" => "p", "parts" => [] },
                                                       "queued" => [], "event_seq" => 1 })
      double("stream", close: nil)
    end
    handled = nil

    attached.run(input: lambda do |_prompt, _prefill|
      # The read starts on its own thread as the loop takes the snapshot in.
      wait_for("the turn running") { attached.running? }
      allow(Reline).to receive(:line_buffer).and_return("half typed")
      handled = Samagotchi::TerminalUI::RelineSeam.interrupt_handler.call
      nil # then Ctrl-D, in the same read
    end)

    expect(handled).to be(true)
    expect(client).to have_received(:cancel).with(reason: "ctrl_c")
  end

  it "asks the worker to exit on a bare exit, any case, as the REPL exits" do
    allow(client).to receive(:request_exit).and_return(Samagotchi::BridgeClient::Response.new(status: 200, body: '{"status":"exiting"}'))

    expect(run_reads("exit")).to eq(:detached)
    inputs = ["EXIT"]
    expect(described_class.new(client: client, screen: screen, client_id: "tui:1").run(input: ->(_p, _f) { inputs.shift }))
      .to eq(:detached)
    expect(client).to have_received(:request_exit).twice.with(client_id: "tui:1")
  end
end
