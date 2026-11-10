# frozen_string_literal: true

require "spec_helper"
require "samagotchi/bridge/card_store"
require "samagotchi/memory_bundle/installed_bundle"
require "samagotchi/schedules"
require "samagotchi/session"
require "samagotchi/worker_sidecar"

RSpec.describe "the recorded compatibility corpus" do
  let(:compat_root) { File.join(__dir__) }

  def corpus_version
    versions = Dir.children(compat_root).select do |name|
      path = File.join(compat_root, name)
      File.directory?(path) && Gem::Version.correct?(name)
    end
    current = Gem::Version.new(Samagotchi::VERSION)
    previous = versions.select { |version| Gem::Version.new(version) < current }
    candidates = previous.empty? ? versions.select { |version| Gem::Version.new(version) <= current } : previous
    candidates.max_by { |version| Gem::Version.new(version) }
  end

  it "reads the newest previous-release samples with today's state readers" do
    version = corpus_version
    expect(version).not_to be_nil, "record a compatibility corpus with release:bump"

    root = File.join(compat_root, version)
    sessions_dir = File.join(root, "sessions")
    session = Samagotchi::Session.load("compat-session", state_dir: sessions_dir)
    expect(session).to have_attributes(id: "compat-session", model_name: "compat:model")
    expect(session.messages.map { |message| message[:content] }).to eq(["compatibility corpus"])

    session_dir = Samagotchi::Session.session_dir(session.id, state_dir: sessions_dir)
    expect(Samagotchi::WorkerSidecar.read(session_dir))
      .to have_attributes(session_id: session.id, version: version, port: 4321)
    expect(Samagotchi::Bridge::CardStore.saved(session_dir).map { |entry| entry.slice(:type, :hook, :text) })
      .to eq([{ type: :hook_notice, hook: "compat", text: "compatibility corpus" }])

    schedule = Samagotchi::Schedules.new(state_dir: sessions_dir).entries.fetch(0)
    expect(schedule).to have_attributes(id: "compat-schedule", anchor: session.id, prompt: "compatibility corpus")
    expect(schedule.recurrence).to eq(kind: "every", interval: "1h")

    manifest_path = File.join(root, ".bundles", "compat", "manifest.json")
    record = Samagotchi::MemoryBundle::InstalledBundle.read("compat", manifest_path)
    expect(record).to have_attributes(name: "compat", version: version, scope: "system", source: "compat-fixture")
  end
end
