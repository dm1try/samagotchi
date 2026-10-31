# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/web/update_check"

RSpec.describe Samagotchi::Web::UpdateCheck do
  let(:root) { Dir.mktmpdir("update-check-spec") }
  let(:state_file) { File.join(root, "samagotchi", "update_check.json") }
  let(:clock) { [Time.utc(2026, 10, 27, 12)] }
  let(:hub) { double("hub", update_available: nil) }
  let(:installed_versions) { double("installed versions", newest: nil) }
  let(:release_version) { Gem::Version.new(Samagotchi::VERSION).bump.to_s }
  let(:releases) { [release(release_version)] }
  let(:fetcher) { -> { releases } }

  after { FileUtils.remove_entry(root) }

  def release(version, age: 48 * 3600, prerelease: false)
    Samagotchi::GemUpdate::Release.new(version: version, created_at: clock.first - age, prerelease: prerelease)
  end

  def checker(**options)
    described_class.new(hub: hub, enabled: true, fetcher: fetcher, clock: -> { clock.first }, state_file: state_file,
                        gem_spec: Object.new, bundler: false, gem_dir: root,
                        installed_versions: installed_versions, **options)
  end

  it "checks only when due, persists the answer with private permissions, and notifies once per version" do
    update_check = checker

    expect(update_check.check).to be(true)
    expect(hub).to have_received(:update_available).with(available: release_version, blocked: nil, notify: true).once
    state = JSON.parse(File.read(state_file))
    expect(state).to include("available" => release_version, "notified" => [release_version])
    expect(File.stat(state_file).mode & 0o777).to eq(0o600)
    expect(update_check.check).to be(false)

    clock[0] += 24 * 3600
    expect(update_check.check).to be(true)
    expect(hub).to have_received(:update_available).with(available: release_version, blocked: nil, notify: false).once
    expect(JSON.parse(File.read(state_file))["notified"]).to eq([release_version])
  end

  it "chooses only the newest sufficiently old stable release newer than the installed chi" do
    installed = Gem::Version.new(Samagotchi::VERSION).bump.to_s
    newest = Gem::Version.new(installed).bump.to_s
    young = Gem::Version.new(newest).bump.to_s
    allow(installed_versions).to receive(:newest).and_return(installed)
    allow(fetcher).to receive(:call).and_return([
      release(release_version),
      release(installed),
      release(newest),
      release(young, age: 3600),
      release("#{young}.pre1", prerelease: true)
    ])

    expect(checker.check).to be(true)
    expect(hub).to have_received(:update_available).with(available: newest, blocked: nil, notify: true)
  end

  it "keeps the previous answer after a failed check, without re-notifying, and tries again within RETRY" do
    expect(checker.check).to be(true)
    clock[0] += 24 * 3600
    allow(fetcher).to receive(:call).and_raise(IOError, "offline")
    previous = JSON.parse(File.read(state_file))

    failing = checker
    expect(failing.check).to be(false)
    expect(JSON.parse(File.read(state_file))).to eq(previous)
    expect(failing.send(:next_wait, clock.first)).to eq(described_class::RETRY)
  end

  it "waits until the check is due again, never less than FIRST_CHECK" do
    update_check = checker
    expect(update_check.send(:next_wait, clock.first)).to eq(described_class::FIRST_CHECK)
    update_check.check

    expect(update_check.send(:next_wait, clock.first)).to eq(24 * 3600)
    expect(update_check.send(:next_wait, clock.first + (20 * 3600))).to eq(4 * 3600)
    expect(update_check.send(:next_wait, clock.first + (30 * 3600))).to eq(described_class::FIRST_CHECK)
  end

  it "publishes no saved answer the owner has installed since" do
    expect(checker.check).to be(true)
    allow(installed_versions).to receive(:newest).and_return(release_version)

    checker.start.stop
    expect(hub).to have_received(:update_available).with(available: nil, blocked: nil)
  end

  it "publishes the blocked update reasons for checkout, Bundler, and an unwritable gem directory" do
    cases = [
      [{ gem_spec: nil }, "checkout"],
      [{ bundler: true }, "bundler"],
      [{ gem_dir: File.join(root, "missing") }, "gem_dir_not_writable"]
    ]
    cases.each do |settings, expected|
      hub = double("hub", update_available: nil)
      described_class.new(hub: hub, enabled: true, fetcher: fetcher, clock: -> { clock.first },
                          state_file: File.join(root, expected, "update_check.json"),
                          installed_versions: installed_versions, gem_spec: Object.new, bundler: false,
                          gem_dir: root, **settings).check
      expect(hub).to have_received(:update_available).with(available: release_version, blocked: expected, notify: true)
    end
  end

  it "checks the chi home's gem dir for writability when there is one" do
    spec = Object.new
    home = Samagotchi::ChiHome::Record.new(ruby: "/r", gem_home: File.join(root, "missing"), gem_path: root, mise: nil,
                                           set_at: "t", set_by_version: "1")
    allow(Samagotchi::ChiHome).to receive(:current).with(gem_spec: spec).and_return(home)
    expect(described_class.blocked_reason(gem_spec: spec, bundler: false)).to eq("gem_dir_not_writable")
    allow(Samagotchi::ChiHome).to receive(:current).with(gem_spec: spec).and_return(home.with(gem_home: root))
    expect(described_class.blocked_reason(gem_spec: spec, bundler: false)).to be_nil
  end

  it "does no fetch or publish when notifications are off" do
    update_check = checker(enabled: false)
    expect(fetcher).not_to receive(:call)

    expect(update_check.start).to be(update_check)
    expect(update_check.check).to be(false)
    expect(hub).not_to have_received(:update_available)
    expect(File).not_to exist(state_file)
  end

  it "restores the saved answer without checking before the cooldown expires" do
    expect(checker.check).to be(true)
    restored = checker
    expect(fetcher).not_to receive(:call)

    restored.start
    thread = restored.instance_variable_get(:@thread)
    expect(hub).to have_received(:update_available).with(available: release_version, blocked: nil)
    expect(restored.check).to be(false)
    restored.stop
    join!(thread, "restored update-check thread")
  end

  it "with update.auto: install checks though update.notify is off, and tells the page nothing of it" do
    update_check = checker(enabled: false, auto: true)

    expect(update_check.check).to be(true)
    expect(update_check.available).to eq(release_version)
    expect(hub).to have_received(:update_available).with(available: nil, blocked: nil, notify: false)
    expect(JSON.parse(File.read(state_file))).to include("available" => release_version, "notified" => [])

    update_check.start
    expect(hub).to have_received(:update_available).with(available: nil, blocked: nil)
    update_check.stop
  end

  it "runs neither for the page nor for AutoUpdate with notify off and auto off" do
    update_check = checker(enabled: false, auto: false)

    expect(update_check.check).to be(false)
    expect(update_check.available).to be_nil
  end

  it "stops reporting a release as available once it is installed" do
    update_check = checker
    update_check.check
    allow(installed_versions).to receive(:newest).and_return(release_version)

    expect(update_check.available).to be_nil
  end

  describe "AutoUpdate's record" do
    it "is saved privately, survives a restart and a later check, and holds the versions given up on" do
      update_check = checker
      expect(update_check.auto_state).to be_nil
      expect(update_check.auto_failed?(release_version)).to be(false)

      update_check.save_auto({ version: release_version, from: "0.1.0", phase: "failed", kept: [] }, failed: release_version)
      update_check.save_auto({ version: release_version, from: "0.1.0", phase: "failed", kept: [] }, failed: release_version)

      expect(File.stat(state_file).mode & 0o777).to eq(0o600)
      expect(JSON.parse(File.read(state_file))).to include("auto_failed" => [release_version],
                                                           "auto" => include("version" => release_version, "phase" => "failed"))
      restored = checker
      expect(restored.auto_state).to include(version: release_version, phase: "failed")
      expect(restored.auto_failed?(release_version)).to be(true)

      expect(restored.check).to be(true)
      expect(restored.auto_state).to include(phase: "failed")
      expect(restored.auto_failed?(release_version)).to be(true)
    end

    it "is cleared by saving nil, and a failed version stays failed" do
      update_check = checker
      update_check.save_auto({ version: "0.1.0", phase: "done" }, failed: "0.0.9")
      update_check.save_auto(nil)

      expect(update_check.auto_state).to be_nil
      expect(update_check.auto_failed?("0.0.9")).to be(true)
    end

    it "is read and saved without waiting for a fetch in progress, and the check's answer keeps that save" do
      fetching = Queue.new
      release_fetch = Queue.new
      update_check = checker(fetcher: lambda {
        fetching << true
        release_fetch.pop
        releases
      })
      check = Thread.new { update_check.check }
      begin
        pop!(fetching, "the fetch to start")

        read = Thread.new do
          update_check.save_auto({ version: release_version, phase: "installed" }, failed: "0.0.9")
          [update_check.auto_state, update_check.auto_failed?("0.0.9")]
        end
        join!(read, "the state's read and save during the fetch")
        expect(read.value).to eq([{ version: release_version, phase: "installed" }, true])
      ensure
        release_fetch << true
        join!(check, "the check")
      end
      expect(check.value).to be(true)
      expect(JSON.parse(File.read(state_file))).to include("available" => release_version, "auto_failed" => ["0.0.9"],
                                                           "auto" => include("phase" => "installed"))
    end

    it "loads a state file written before it existed" do
      FileUtils.mkdir_p(File.dirname(state_file))
      File.write(state_file, JSON.generate(checked_at: clock.first.iso8601, available: release_version, notified: []))

      expect(checker.auto_state).to be_nil
    end
  end

  it "uses the config checks for the minimum supported intervals" do
    entries = Samagotchi::Config::ENTRIES.to_h { |entry| [entry.key, entry] }

    expect(entries.fetch("update.check_hours").check.call(0)).to eq("at least 1")
    expect(entries.fetch("update.min_age_hours").check.call(-1)).to eq("at least 0")
    expect(entries.fetch("update.min_age_hours").check.call(0)).to be_nil
  end

  it "declares update.auto (off by default) and update.restart (idle by default) as web-start enums" do
    auto = Samagotchi::Config::BY_KEY.fetch("update.auto")
    restart = Samagotchi::Config::BY_KEY.fetch("update.restart")

    expect([auto.default, auto.enum_values, auto.lifecycle]).to eq(["off", %w[off install], :web_start])
    expect([restart.default, restart.enum_values, restart.lifecycle]).to eq(["idle", %w[idle never], :web_start])
  end
end
