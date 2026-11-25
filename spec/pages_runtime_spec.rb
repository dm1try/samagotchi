# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "spec_helper"
require "samagotchi/pages"
require "samagotchi/pages/runner"

# What a page script reads of chi (Pages::Runtime, docs/pages.md): the
# schedules from this chi's own code, and the runner staying light for a
# page that never asks.
RSpec.describe Samagotchi::Pages::Runtime do
  let(:tmp) { Dir.mktmpdir("pages-runtime") }
  let(:pages) { Samagotchi::Pages }
  let(:fixture) { File.expand_path("fixtures/schedules/listing_store.json", __dir__) }
  let(:store_path) { File.join(Samagotchi::Paths.state_dir, "schedules.json") }

  around do |example|
    with_env("XDG_CONFIG_HOME" => File.join(tmp, "config"), "XDG_STATE_HOME" => File.join(tmp, "state")) { example.run }
  ensure
    FileUtils.rm_rf(tmp)
  end

  def fixture_store
    FileUtils.mkdir_p(File.dirname(store_path))
    FileUtils.cp(fixture, store_path)
  end

  describe "#schedules" do
    before do
      require "samagotchi/schedules"
      require "samagotchi/schedule_display"
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("schedule.auto_tick").and_return(false)
      allow(Samagotchi::Config).to receive(:get).with("schedule.tick_interval_minutes").and_return(5)
    end

    it "reads every schedule as the CLI's JSON says it, with the unreadable ids and the tick warning" do
      fixture_store
      list = described_class.new.schedules
      expect(list.map(&:id)).to eq(Samagotchi::Schedules.new.entries(include_disabled: true).map(&:id))
      expect(list.unreadable_ids).to eq(["e1f2a3b4", nil])
      expect(list.warning).to eq(Samagotchi::Schedules.new.tick_warning)

      heartbeat = list.find { |schedule| schedule.id == "a1b2c3d4" }
      expect(heartbeat.to_h.slice(:name, :state, :off_reason, :skips, :max_skips, :recurrence_words, :skip_window))
        .to eq(name: "Heartbeat", state: "on", off_reason: nil, skips: 2, max_skips: 12, recurrence_words: "every 1h",
               skip_window: "≈1 h at a 5 min tick")
      expect([heartbeat.next_due, heartbeat.condition])
        .to eq(["2026-11-25T13:00:00Z", { "cmd" => "$HOME/.local/bin/coord-pane gate", "by" => "cli", "set_at" => "2026-11-24T09:00:00Z" }])
      expect(heartbeat.history.map(&:status)).to eq(%w[skipped fired])
      expect(heartbeat.history.last).to eq(described_class::Run.new(at: "2026-11-25T11:00:00Z", status: "fired",
                                                                    detail: "continued as 11111111",
                                                                    session_id: "11111111-aaaa-4aaa-8aaa-000000000002"))
      expect(list.find { |schedule| schedule.id == "f6a7b8c9" }.off_reason).to eq("failures")
    end

    it "has the members the CLI's JSON names, and the JSON only chi's bookkeeping besides" do
      fixture_store
      entries = Samagotchi::Schedules.new.entries(include_disabled: true)
      cli = entries.map { |entry| Samagotchi::ScheduleDisplay.json(entry) }
      list = described_class.new.schedules
      cli.zip(list.entries).each do |json, schedule|
        described_class::SCHEDULE_MEMBERS.each do |member|
          expected = json.fetch(member.to_s)
          expected = expected.map { |row| described_class::Run.new(**row) } if member == :history
          expect(schedule.public_send(member)).to eq(expected), "#{schedule.id} #{member}"
        end
      end
      bookkeeping = %w[recurrence busy catch_up keep_links due_was firing_since firing_token pending_session_id pending_turn_id
                       disabled_notice]
      expect(cli.flat_map(&:keys).uniq - described_class::SCHEDULE_MEMBERS.map(&:to_s) - ["future_key"]).to match_array(bookkeeping)
    end

    it "gives table rows: every member but the history, string keys" do
      fixture_store
      rows = described_class.new.schedules.rows
      expect(rows.size).to eq(10)
      expect(rows.first.keys).to eq((described_class::SCHEDULE_MEMBERS - [:history]).map(&:to_s))
      builder = Samagotchi::Pages::Builder.new("t")
      builder.table(rows, columns: { "name" => "Name", "state" => "State" })
      expect(builder.data["blocks"].first["rows"].first).to eq(%w[Dentist off])
    end

    it "is empty with no schedules file" do
      list = described_class.new.schedules
      expect([list.entries, list.unreadable_ids]).to eq([[], []])
    end

    it "raises Unreadable with Schedules::Corrupt's own words for a file that isn't JSON, and changes nothing" do
      FileUtils.mkdir_p(File.dirname(store_path))
      File.write(store_path, "{not json")
      expect { described_class.new.schedules }
        .to raise_error(described_class::Unreadable, /schedules\.json is not readable JSON .*: fix or remove it before changing schedules/)
      expect(File.read(store_path)).to eq("{not json")
      expect(File.exist?(File.join(File.dirname(store_path), "schedules.lock"))).to be(false)
    end
  end

  # A real runner process (Runner.run, as Launch starts it): what the page's
  # own process has loaded when its script ends.
  describe "the runner's weight" do
    def run_page(name, body)
      FileUtils.mkdir_p(pages.scripts_dir)
      File.write(File.join(pages.scripts_dir, "#{name}.rb"), body)
      lib = File.expand_path("../lib", __dir__)
      boot = 'require "samagotchi/pages/runner"; exit Samagotchi::Pages::Runner.run(ARGV)'
      _out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", boot, name, chdir: tmp)
      expect(status.exitstatus).to eq(0), err
      Samagotchi::Pages::Store.read(name).blocks.first["text"]
    end

    loaded = 'ui.text $LOADED_FEATURES.grep(%r{/samagotchi/(schedules|config|pages/runtime)\.rb\z}).map { |f| File.basename(f) }.sort.join(",")'

    it "loads none of the runtime, the schedules or the config for a page that never calls runtime" do
      expect(run_page("plain", "page 'Plain' do |ui|\n  #{loaded}\nend\n")).to eq("")
    end

    it "loads them when the page calls runtime.schedules" do
      fixture_store
      text = run_page("reads", "page 'Reads' do |ui|\n  ui.text runtime.schedules.count.to_s\n  #{loaded}\nend\n")
      expect(text).to eq("10")
      expect(Samagotchi::Pages::Store.read("reads").blocks.last["text"]).to eq("config.rb,runtime.rb,schedules.rb")
    end
  end
end
