# frozen_string_literal: true

require "json"
require "fileutils"
require "samagotchi/testing/rspec"
require "samagotchi/memory_bundle/installer"
require "samagotchi/pages"
require "samagotchi/pages/launch"

# The schedules bundle as installed: its page lists, and a run (a real
# runner process, as chi web's Refresh starts it) draws the blocks the
# golden holds over a fixture store (spec/fixtures/store.json), in UTC.
# The fixture has never ticked (last_tick_at null), so the tick warning
# always shows. UPDATE_GOLDENS=1 rewrites the golden after an intended change.
RSpec.describe "The schedules bundle's page", :bundle do
  let(:shipped) { File.expand_path("..", __dir__) }
  let(:fixtures) { File.expand_path("fixtures", __dir__) }
  let(:store_path) { File.join(Samagotchi::Paths.state_dir, "schedules.json") }
  let(:store) { Samagotchi::Pages::Store }

  around do |example|
    saved = ENV.fetch("TZ", nil)
    ENV["TZ"] = "UTC"
    example.run
  ensure
    ENV["TZ"] = saved
  end

  before do
    Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "schedules", scope: "system", strict: true).run
  end

  def schedules_file(text)
    FileUtils.mkdir_p(File.dirname(store_path))
    File.write(store_path, text)
  end

  def run_page
    result = Samagotchi::Pages::Launch.run("schedules")
    [result, result.page.blocks]
  end

  def texts(blocks) = blocks.select { |block| block["type"] == "text" }.map { |block| block["text"] }

  it "is a page of the bundle's, never ran, with no pages folder of the owner's" do
    expect(store.list.map { |page| [page.name, page.bundle, page.state] }).to eq([["schedules", "schedules", :never_ran]])
    expect(File.exist?(Samagotchi::Pages.scripts_dir)).to be(false)
  end

  it "draws every schedule, why one is off, what can't be read and the recent runs (golden)" do
    schedules_file(File.read(File.join(fixtures, "store.json")))
    result, blocks = run_page
    expect(result).to be_ok, result.page.error&.message
    golden = File.join(fixtures, "page_golden.json")
    actual = "#{JSON.pretty_generate(blocks)}\n"
    File.write(golden, actual) if ENV["UPDATE_GOLDENS"]
    expect(actual).to eq(File.read(golden)), "page_golden.json changed: UPDATE_GOLDENS=1 rewrites it after an intended change"
    expect(texts(blocks).first).to eq("10 schedules: 1 on, 2 firing, 7 off. Refresh to update.\n\n" \
                                      "Warning: no schedule tick in the last 10 minutes; set schedule.auto_tick: true or " \
                                      "run `chi schedule tick` from cron.")
  end

  it "says how to make the first one when there are none, with no tick warning" do
    _result, blocks = run_page
    expect(texts(blocks)).to eq(["No schedules yet. Ask chi (\"check the CI every morning at 9\") or run " \
                                 "`chi schedule add --session ID --every 1d -m \"…\"`; see docs/scheduling.md."])
  end

  it "fails a run on a schedules.json that isn't JSON with the store's own words, and keeps the last good result" do
    schedules_file(File.read(File.join(fixtures, "store.json")))
    good, = run_page
    expect(good).to be_ok
    schedules_file("{not json")
    result, blocks = run_page
    expect(result).not_to be_ok
    expect(result.page.error.message).to match(/schedules\.json is not readable JSON .*: fix or remove it before changing schedules/)
    expect(blocks).to eq(good.page.blocks)
    expect(File.read(store_path)).to eq("{not json")
  end

  it "keeps the off and unreadable texts under a text block's cap: the first lines, then how many more" do
    data = JSON.parse(File.read(File.join(fixtures, "store.json")))
    template = data["schedules"].find { |entry| entry.is_a?(Hash) && entry["id"] == "d4e5f6a7" } # off by failures
    failed = { "at" => "2026-11-24T02:00:00Z", "status" => "failed", "detail" => "disabled: #{"the session is archived " * 9}",
               "session_id" => template["anchor"] }
    data["schedules"] = (1..50).map do |i|
      template.merge("id" => format("%08x", i), "title" => "Nightly build #{i} #{"y" * 90}", "history" => [failed])
    end + (1..30).map { |i| { "id" => format("bad%05d", i) } }
    schedules_file(JSON.generate(data))
    result, blocks = run_page
    expect(result).to be_ok, result.page.error&.message
    off = texts(blocks).find { |text| text.start_with?("Turned off:") }
    unreadable = texts(blocks).find { |text| text.start_with?("Can't be read:") }
    [off, unreadable].each { |text| expect(text.bytesize).to be < Samagotchi::Pages::MAX_TEXT_BYTES / 4 }
    expect(off.lines.last).to eq("- and 30 more: `chi schedule list --all`")
    expect(off.lines[2].size).to be < 260
    expect(unreadable.lines.last).to start_with("- and 10 more: ")
  end

  it "stays under the output cap with many schedules and their full history: the tables cut and say so" do
    data = JSON.parse(File.read(File.join(fixtures, "store.json")))
    template = data["schedules"].first
    history = (1..20).map do |i|
      { "at" => format("2026-11-25T%02d:00:00Z", i % 24), "status" => "skipped", "detail" => "busy " * 30, "session_id" => template["head"] }
    end
    data["schedules"] = (1..120).map do |i|
      template.merge("id" => format("%08x", i), "title" => "Schedule #{i} #{"x" * 80}", "prompt" => "p " * 200, "history" => history)
    end
    schedules_file(JSON.generate(data))
    result, blocks = run_page
    expect(result).to be_ok, result.page.error&.message
    expect(JSON.generate(result.page.to_json_hash).bytesize).to be < Samagotchi::Pages::MAX_OUTPUT_BYTES
    tables = blocks.select { |block| block["type"] == "table" }
    expect(tables.map { |table| table["rows"].size }).to eq([100, 50])
    expect(texts(blocks)).to include("Schedules\n\nThe first 100; 20 more in `chi schedule list --all`.",
                                     "Recent runs\n\nThe last 50 of 2400; `chi schedule show ID` has each one's.")
  end
end
