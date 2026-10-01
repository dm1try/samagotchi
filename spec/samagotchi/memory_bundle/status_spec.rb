# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
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
end
