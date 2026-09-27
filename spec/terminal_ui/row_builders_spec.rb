# frozen_string_literal: true

require "samagotchi/terminal_ui"
require_relative "../support/recording_surface"

# The spinner, preview and status rows are built for a width the caller
# passes in (the surface's), not read from the terminal by each builder.
RSpec.describe Samagotchi::TerminalUI, "row builders" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:ui) { described_class.new(mode: :assist, client: client) }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "SAMAGOTCHI_STATUS_LINE")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV.delete("SAMAGOTCHI_STATUS_LINE")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL SAMAGOTCHI_STATUS_LINE].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  before do
    ui.instance_variable_set(:@surface, RecordingSurface.new)
    allow(ui).to receive(:color_output?).and_return(false)
    allow(ui).to receive(:thinking_spinner_enabled?).and_return(true)
    allow(ui).to receive(:status_server_segment).and_return("")
    ui.send(:handle_stream_event, type: :generation_started)
    ui.send(:handle_stream_event, type: :generation_chunk, content: "#{"x" * 200}. ")
    ui.send(:handle_stream_event, type: :tool_call_started, call: { name: "memory_read", content: "notes" })
    expect(ui).not_to receive(:status_effective_width)
  end

  it "fits the status rows to the given width" do
    rows = ui.send(:build_status_lines, scope: :spinner, width: 20)

    expect(rows).to eq(["status> model=Gemma-"])
    expect(ui.send(:idle_status_lines, width: 12)).to eq(["status> mode"])
  end

  it "fits the sentence to the given width, next to the notifications" do
    row, = ui.send(:thinking_spinner_status_lines, "|", width: 120)

    expect(row).to match(/\Amodel> thinking · x+… \| memory_loaded: notes last_tool: memory_read\(name="notes"\)\z/)
    expect(row.length).to eq(120)
  end

  it "says thinking... where the sentence has too little room" do
    row, = ui.send(:thinking_spinner_status_lines, "|", width: 41)

    expect(row).to eq("model> thinking... | memory_loaded: notes")
  end
end

# The REPL's tool tally: a row after the spinner row.
RSpec.describe Samagotchi::TerminalUI, "tool tally row" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:ui) { described_class.new(mode: :assist, client: client, spinner_tick_interval: nil) }

  before do
  ui.instance_variable_set(:@surface, RecordingSurface.new)
  allow(ui).to receive(:color_output?).and_return(false)
  allow(ui).to receive(:thinking_spinner_enabled?).and_return(true)
  allow(ui).to receive(:status_server_segment).and_return("")
  allow(ui).to receive(:status_effective_width).and_return(80)
  ui.send(:handle_stream_event, type: :generation_started)
  ui.send(:handle_stream_event, type: :tool_call_started, iteration: 0, call_index: 0, tool: "memory_read",
                                call: { name: "memory_read", content: "notes" })
  end

  def call_tool(iteration, name, status: "ok")
    ui.send(:handle_stream_event, type: :tool_call_started, iteration: iteration, call_index: 1, tool: name,
                                  call: { name: name }, params: "command=x")
    ui.send(:handle_stream_event, type: :tool_call_completed, iteration: iteration, call_index: 1, tool: name,
                                  activity: { action: "running command", tool: name, params: "command=x", status: status })
  end

  it "follows the spinner row from the turn's 3rd tool call" do
    call_tool(1, "execute", status: "error")
    expect(ui.send(:thinking_spinner_status_lines, "|", width: 80).size).to eq(1)

    call_tool(2, "execute")
    rows = ui.send(:thinking_spinner_status_lines, "|", width: 50)
    expect(rows.size).to eq(2)
    expect(rows.first).to start_with("model> thinking... |")
    expect(rows.last).to eq("3 tool calls (1 failed) · execute ×2 · memory_rea…")
  end

  it "follows the retry row too" do
    2.times { |i| call_tool(i + 1, "execute") }
    ui.send(:handle_stream_event, type: :generation_retrying, attempt: 1, max_retries: 2, next_delay: 1.0)
    rows = ui.send(:thinking_spinner_status_lines, "|", width: 200)
    expect(rows.size).to eq(2)
    expect(rows.first).to include("retrying")
    expect(rows.last).to start_with("3 tool calls · execute ×2")
  end

  it "starts over with each turn" do
    2.times { |i| call_tool(i + 1, "execute") }
    ui.send(:handle_stream_event, type: :turn_started)
    ui.send(:handle_stream_event, type: :generation_started)
    expect(ui.send(:thinking_spinner_status_lines, "|", width: 80).size).to eq(1)
  end
end
