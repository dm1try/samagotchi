# frozen_string_literal: true

require "samagotchi/terminal_ui"
require_relative "../support/recording_surface"

# The spinner, preview and status rows are built for a width the caller
# passes in (the surface's), not read from the terminal by each builder.
RSpec.describe Samagotchi::TerminalUI, "row builders" do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:ui) { described_class.new(mode: :assist, client: client) }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "SAMAGOTCHI_THINKING_PREVIEW_LINES", "SAMAGOTCHI_STATUS_LINE")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["SAMAGOTCHI_THINKING_PREVIEW_LINES"] = "2"
    ENV.delete("SAMAGOTCHI_STATUS_LINE")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL SAMAGOTCHI_THINKING_PREVIEW_LINES SAMAGOTCHI_STATUS_LINE].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
  end

  before do
    ui.instance_variable_set(:@surface, RecordingSurface.new)
    allow(ui).to receive(:color_output?).and_return(false)
    allow(ui).to receive(:thinking_spinner_enabled?).and_return(true)
    allow(ui).to receive(:status_server_segment).and_return("")
    ui.send(:handle_stream_event, type: :generation_started)
    ui.send(:handle_stream_event, type: :generation_chunk, content: "x" * 200)
    ui.send(:handle_stream_event, type: :tool_call_started, call: { name: "memory_read", content: "notes" })
    expect(ui).not_to receive(:status_effective_width)
  end

  it "fits the status rows to the given width" do
    rows = ui.send(:build_status_lines, scope: :spinner, width: 20)

    expect(rows).to eq(["status> model=Gemma-"])
    expect(ui.send(:idle_status_lines, width: 12)).to eq(["status> mode"])
  end

  it "fits the thinking preview rows to the given width" do
    rows, has_content = ui.send(:thinking_tail_preview_lines, width: 30)

    expect(has_content).to be(true)
    expect(rows.length).to eq(2)
    expect(rows).to all(satisfy { |row| row.length <= 30 })
    expect(rows.first).to start_with("model> … x")
  end

  it "fits the spinner row's notifications to the given width" do
    row, = ui.send(:thinking_spinner_status_lines, "|", width: 41)

    expect(row).to eq("model> thinking... | memory_loaded: notes")
  end
end
