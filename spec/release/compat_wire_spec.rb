# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require_relative "../../script/release/compat_wire"
require_relative "../../script/release/release_tools"

# The wire samples' recorder (script/release/compat_wire.rb): what it pins and
# the determinism guard release:bump runs (ReleaseTools.write_compat_wire!).
# What the samples say is read by spec/compat/wire_readers_spec.rb.
RSpec.describe CompatWire do
  let(:tmp) { Dir.mktmpdir("compat-wire-") }

  after { FileUtils.rm_rf(tmp) }

  def read(dir, name) = JSON.parse(File.read(File.join(dir, name)))

  describe ".normalise" do
    it "pins times, event ids' epochs, measured numbers, the temp folder, chi's version and the system prompt" do
      raw = { status: 200, "body" => { event_id: "41-9a8b7c6d", at: "2026-11-11T10:20:30.123+01:00", gen_ms: 37,
                                       count: 3, chi_version: Samagotchi::VERSION, path: "/tmp/rec-x/README.md",
                                       messages: [{ role: "system", content: "You are Chi, today" },
                                                  { role: "system", content: "[SYSTEM: REMINDERS DUE]" }] } }

      shown = described_class.normalise(raw, version: "1.2.3", roots: ["/tmp/rec-x"])

      expect(shown).to eq("body" => { "at" => "2026-01-01T00:00:00Z", "chi_version" => "1.2.3", "count" => 3,
                                      "event_id" => "41-0c0ffee0", "gen_ms" => 1000,
                                      "messages" => [{ "content" => "<system prompt>", "role" => "system" },
                                                     { "content" => "[SYSTEM: REMINDERS DUE]", "role" => "system" }],
                                      "path" => "/compat-fixture/README.md" },
                          "status" => 200)
      expect(shown.keys).to eq(shown.keys.sort)
    end

    it "pins last_turn.seconds only, not another seconds key" do
      raw = { "body" => { "last_turn" => { "seconds" => 0.1, "steps" => 2 }, "seconds" => 7, "recap" => { "seconds" => 5 } } }

      shown = described_class.normalise(raw, version: "1.2.3")

      expect(shown["body"]["last_turn"]).to eq("seconds" => 1000, "steps" => 2)
      expect(shown["body"]).to include("seconds" => 7, "recap" => { "seconds" => 5 })
    end

    it "is idempotent on a recording" do
      described_class.record!(tmp, version: "1.2.3")

      described_class::FILES.each do |name|
        recorded = read(tmp, name)
        expect(described_class.normalise(recorded, version: "1.2.3")).to eq(recorded), name
      end
    end
  end

  describe ".first_difference" do
    it "names the first JSON path where two values differ, nil when equal" do
      a = { "body" => { "items" => [{ "at" => 1 }, { "at" => 2 }] } }

      expect(described_class.first_difference(a, JSON.parse(JSON.generate(a)))).to be_nil
      expect(described_class.first_difference(a, { "body" => { "items" => [{ "at" => 1 }, { "at" => 3 }] } }))
        .to eq("$.body.items[1].at")
      expect(described_class.first_difference(a, { "body" => { "items" => [{ "at" => 1 }] } })).to eq("$.body.items[1]")
      expect(described_class.first_difference(a, { "body" => nil })).to eq("$.body")
    end
  end

  describe "ReleaseTools.write_compat_wire!" do
    it "writes the recording into wire/ when two recordings agree" do
      paths = ReleaseTools.send(:write_compat_wire!, tmp, "1.2.3")

      expect(paths).to eq(described_class::FILES.map { |name| File.join(tmp, "wire", name) })
      expect(read(File.join(tmp, "wire"), "state.json")).to include("route" => "state", "status" => 200)
      events = read(File.join(tmp, "wire"), described_class::EVENTS_FILE)
      expect(events.first).to include("type" => "turn_started")
      expect(events.map { |event| event.fetch("type") }).to include("tool_call_started", "tool_call_completed", "hook_notice", "turn_completed")
      expect(events.find { |event| event["type"] == "generation_chunk" }.fetch("data")).to include("text" => "Reading.")
      expect(events).to all(satisfy { |event| event.dig("data", "type") == event.fetch("type") })
    end

    it "refuses a field the normaliser leaves unpinned, naming its file and path" do
      recordings = 0
      allow(described_class).to receive(:record!).and_wrap_original do |original, dir, **options|
        original.call(dir, **options).tap do
          recordings += 1
          path = File.join(dir, "tail.json")
          data = read(dir, "tail.json")
          data["body"]["session_id"] = "random-#{recordings}"
          File.write(path, JSON.generate(data))
        end
      end

      expect { ReleaseTools.send(:write_compat_wire!, tmp, "1.2.3") }
        .to raise_error(ReleaseTools::Error, %r{wire/tail\.json differ at \$\.body\.session_id: pin it in CompatWire\.normalise})
      expect(File).not_to exist(File.join(tmp, "wire"))
    end
  end
end
