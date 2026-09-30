# frozen_string_literal: true

require "samagotchi/terminal_ui/status_row"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::StatusRow do
  let(:surface) { RecordingSurface.new(columns: 120) }
  let(:row) { described_class.new(surface) }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_STATUS_LINE")
    example.run
  ensure
    ENV.delete("SAMAGOTCHI_STATUS_LINE")
    saved.each { |k, v| ENV[k] = v }
  end

  it "shows the model, the parent, ctx, the memories and the mutes, in that order" do
    row.update(model: "m2", default_model: "m1", parent_id: "3f2a1c9e-0000", context: { est_pct: 12.34, bucket: "under20" },
               used_memories: %w[notes], preloaded: %w[notes cli], muted: %w[gh])

    expect(surface.slots[:status]).to eq(["status> model=m2 (default: m1) | ↳ 3f2a1c9e | ctx=12.3% (under20) | mem: notes, cli | muted: gh"])
  end

  it "names the served model first when the server served another" do
    row.update(model: "m1", default_model: "m1", served: %w[ornith m1])

    expect(surface.slots[:status]).to eq(["status> model=ornith (served; asked m1)"])
  end

  it "redraws only when its text changes" do
    row.update(model: "m1")
    row.update(model: "m1", used_memories: [])
    row.update(used_memories: %w[notes])

    expect(surface.events.count { |event| event[0] == :set_slot }).to eq(2)
  end

  it "draws again on a new surface" do
    row.update(model: "m1")
    other = RecordingSurface.new(columns: 120)
    row.surface = other
    row.refresh

    expect(other.slots[:status]).to eq(["status> model=m1"])
  end

  it "draws nothing with status.line off" do
    ENV["SAMAGOTCHI_STATUS_LINE"] = "off"
    row.update(model: "m1")

    expect(surface.events).to be_empty
  end

  it "refuses a field it doesn't know" do
    expect { row.update(server: "x") }.to raise_error(ArgumentError, /server/)
  end
end
