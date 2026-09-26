# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/status"

RSpec.describe Samagotchi::MemoryBundle::Status do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-status-") }
  let(:system_dir) { File.join(tmpdir, "mem") }
  let(:fixture) { File.expand_path("../../fixtures/sample_needs_bundle", __dir__) }

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = File.join(system_dir, ".bundles")
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = File.join(tmpdir, "proj")
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.rm_rf(tmpdir)
  end

  it "lists each stored need with found: from the current PATH" do
    Samagotchi::MemoryBundle::Installer.new(source: fixture, name: "sample-needs", scope: "system").run
    needs = described_class.bundle_status("sample-needs")[:needs]
    expect(needs.map { |n| [n[:command], n[:found]] }).to eq([["chi-surely-missing-cmd", false], ["sh", true]])
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
