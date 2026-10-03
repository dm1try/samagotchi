# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "yaml"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/status"

RSpec.describe Samagotchi::MemoryBundle::Status do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-status-") }
  let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  let(:fixture) { File.expand_path("../../fixtures/sample_needs_bundle", __dir__) }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  it "lists each stored need with found: from the current PATH" do
    Samagotchi::MemoryBundle::Installer.new(source: fixture, name: "sample-needs", scope: "system").run
    needs = described_class.bundle_status("sample-needs")[:needs]
    expect(needs.map { |n| [n[:command], n[:found]] }).to eq([["chi-surely-missing-cmd", false], ["sh", true]])
  end

  it "finds each installed file's index line (lines name the entry without .md)" do
    Samagotchi::MemoryBundle::Installer.new(source: fixture, name: "sample-needs", scope: "system").run
    files = described_class.bundle_status("sample-needs")[:files]
    expect(files).not_to be_empty
    expect(files.transform_values { |f| f[:index_present] }).to all(satisfy { |_k, v| v == true })
  end

  it "doesn't guess a folder for a scope this chi doesn't know: scope_error, files unchecked, nothing read" do
    Samagotchi::MemoryBundle::Installer.new(source: fixture, name: "sample-needs", scope: "system").run
    mjson = File.join(system_dir, ".bundles", "sample-needs", "manifest.json")
    File.write(mjson, JSON.generate(JSON.parse(File.read(mjson)).merge("scope" => "team")))
    allow(File).to receive(:read).and_call_original
    allow(Samagotchi::MemoryBundle::IndexUpdater).to receive(:index_path_for).and_call_original

    st = described_class.bundle_status("sample-needs")

    expect(st).to include(scope: "team", scope_error: "unknown scope: team", target_dir: nil)
    expect(st[:files]).not_to be_empty
    expect(st[:files].values).to all(include(unchecked: true, missing: false, modified: false))
    expect(File).not_to have_received(:read).with(start_with(system_dir + "/").and(end_with(".md")))
    expect(Samagotchi::MemoryBundle::IndexUpdater).not_to have_received(:index_path_for)
  end

  it "has no scope_error for a scope it knows" do
    Samagotchi::MemoryBundle::Installer.new(source: fixture, name: "sample-needs", scope: "system").run
    expect(described_class.bundle_status("sample-needs")).to include(scope: "system", scope_error: nil, target_dir: system_dir)
  end

  it "has no needs for a bundle that declares none" do
    expect(described_class.needs_status({})).to eq([])
  end

  it "formats one line per need" do
    expect(described_class.need_line({ command: "gh", why: "reads PRs", hint: "brew install gh", found: true }))
      .to eq("needs gh (reads PRs) [ok]")
    expect(described_class.need_line({ command: "gh", why: nil, hint: "brew install gh", found: false }))
      .to eq("needs gh [not found]: brew install gh")
    expect(described_class.need_line({ command: "jq", why: nil, hint: nil, found: false }))
      .to eq("needs jq [not found]")
  end
  it "marks a model overlay (its base among the bundle's files) and doesn't look for its index line" do
    src = File.join(tmpdir, "ovl-src")
    FileUtils.mkdir_p(src)
    files = { "tips.md" => "Base\n", "tips.qwen3.md" => "Qwen\n", "notes.v2.md" => "Not an overlay\n" }
    files.each { |f, body| File.write(File.join(src, f), body) }
    File.write(File.join(src, "manifest.yml"), YAML.dump("name" => "ovl", "version" => "0.1.0",
                                                         "files" => files.keys.to_h { |f| [f, "sha256:x"] }))
    Samagotchi::MemoryBundle::Installer.new(source: src, name: "ovl", scope: "system", strict: false).run

    files = described_class.bundle_status("ovl")[:files]
    expect(files["tips.qwen3.md"]).to include(overlay: true, index_present: nil)
    expect(files["tips.md"]).to include(overlay: false, index_present: true)
    expect(files["notes.v2.md"][:overlay]).to be(true) # no base anywhere: an overlay, as the installer took it
  end
end
