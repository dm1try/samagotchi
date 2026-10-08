# frozen_string_literal: true

require "samagotchi/terminal_ui/status_row"
require "samagotchi/children_status"
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

  describe "the children segment" do
    def counts(running: 0, waiting: 0, unreported: 0)
      Samagotchi::ChildrenStatus::Counts.new(running: running, waiting: waiting, unreported: unreported)
    end

    it "follows the parent with the delegates running and waiting (the ones there are)" do
      row.update(model: "m1", parent_id: "3f2a1c9e-0000", children: counts(running: 2, waiting: 1),
                 context: { est_pct: 12.34, bucket: "under20" })

      expect(surface.slots[:status]).to eq(["status> model=m1 | ↳ 3f2a1c9e | ⑂ 2 running · 1 waiting | ctx=12.3% (under20)"])

      row.update(children: counts(waiting: 1, unreported: 2))
      expect(surface.slots[:status]).to eq(["status> model=m1 | ↳ 3f2a1c9e | ⑂ 1 waiting | ctx=12.3% (under20)"])
    end

    it "is hidden without children, or with none running or waiting (unreported replies aren't shown)" do
      row.update(model: "m1", children: nil)
      expect(surface.slots[:status]).to eq(["status> model=m1"])

      row.update(children: counts(unreported: 1))
      expect(surface.slots[:status]).to eq(["status> model=m1"])
    end

    it "draws nothing with status.line off" do
      ENV["SAMAGOTCHI_STATUS_LINE"] = "off"
      row.update(model: "m1", children: counts(running: 1))

      expect(surface.events).to be_empty
      expect(row.enabled?).to be(false)
    end
  end

  describe "#take_state" do
    let(:state) do
      { model_name: "m2", served_model: "ornith", served_model_for: "m2", parent_id: "3f2a1c9e-0000",
        used_memory_names: %w[notes], preloaded_memory_names: %w[cli], muted_memory_names: %w[gh],
        context_status: { est_pct: 12.34, bucket: "under20" } }
    end

    it "shows a session state's model, served model, parent, ctx and memories" do
      row.take_state(state, default_model: "m1")

      expect(surface.slots[:status])
        .to eq(["status> model=ornith (served; asked m2) | ↳ 3f2a1c9e | ctx=12.3% (under20) | mem: notes, cli | muted: gh"])
    end

    it "keeps what an older state lacks, but clears the served pair" do
      row.take_state(state, default_model: "m1")
      row.take_state({ context_status: nil })

      expect(row[:served]).to be_nil
      expect(row[:model]).to eq("m2")
      expect(row[:used_memories]).to eq(%w[notes])
      expect(row[:parent_id]).to eq("3f2a1c9e-0000")
      expect(row[:context]).to eq(est_pct: 12.34, bucket: "under20")
    end
  end

  it "keeps the model asked for when the served one is expected (hosts.<name>.models served:)" do
    row.take_state({ model_name: "work:rr/x", served_model: "fireworks/x", served_model_for: "rr/x", served_expected_by: "work" })
    expect(surface.slots[:status]).to eq(["status> model=work:rr/x"])

    row.take_event({ type: :generation_completed, served_model: "together/x", requested_model: "rr/x", served_expected_by: nil })
    expect(surface.slots[:status]).to eq(["status> model=together/x (served; asked work:rr/x)"])

    row.take_event({ type: :generation_completed, served_model: "baseten/x", requested_model: "rr/x", served_expected_by: "work" })
    expect(surface.slots[:status]).to eq(["status> model=work:rr/x"])
  end

  describe "#take_event" do
    it "takes ctx, the memories used and the served model from turn events" do
      row.update(model: "m1", default_model: "m1")
      row.take_event({ type: :context_status, usage: { estimated_pct: 40.0 }, bucket: "under60" })
      row.take_event({ type: :used_memories_updated, used_memory_names: %w[notes] })
      row.take_event({ type: :generation_completed, served_model: "ornith", requested_model: "m1" })
      row.take_event({ type: :generation_completed })
      row.take_event({ type: :turn_started })

      expect(surface.slots[:status]).to eq(["status> model=ornith (served; asked m1) | ctx=40.0% (under60) | mem: notes"])
    end
  end

  it "refuses a field it doesn't know" do
    expect { row.update(server: "x") }.to raise_error(ArgumentError, /server/)
  end
end
