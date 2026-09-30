# frozen_string_literal: true

require "spec_helper"
require "digest"
require "tmpdir"
require "samagotchi/memory_bundle/system_bundle"
require "samagotchi/version"

RSpec.describe Samagotchi::MemoryBundle::SystemBundle do
  describe "shipped bundle manifest" do
    let(:dir) { described_class::GEM_BUNDLE_DIR }
    let(:manifest) { Samagotchi::MemoryBundle::Manifest.read(dir: dir) }

    it "lists every bundled memory file" do
      shipped = Dir.glob(File.join(dir, "*.md")).map { |p| File.basename(p) }.sort
      expect(manifest.files.keys.map(&:to_s).sort).to eq(shipped)
    end

    it "is at the gem's version (the two are bumped together)" do
      expect(manifest.version.to_s).to eq(Samagotchi::VERSION)
    end

    it "ships the delegated-session rules, preloaded into every child of a delegate call" do
      expect(manifest.files.keys.map(&:to_s)).to include("delegated.md")
      expect(File.read(File.join(dir, "delegated.md"))).to include("can't delegate further")
    end

    it "teaches skills in identity (every turn's prompt) in at most 6 lines, and in the memory guide" do
      identity = File.read(File.join(dir, "identity.md"))
      paragraph = identity[/^- \*\*Skills\*\*.*?(?=^- \*\*|\z)/m]
      expect(paragraph).to include("skill_<name>", "memory_write", "Changelog", "stop means stop and ask")
      expect(paragraph.lines.size).to be <= 6
      expect(paragraph).to include("when anything looks unexpected", "don't improvise a fix", "including warnings")
      guide = File.read(File.join(dir, "memory_guide.md"))
      expect(guide).to include("## Skills", "# Skill: release", "/skill save")
      expect(guide).to include("When anything looks unexpected", "don't improvise a fix", "including warnings")
    end

    it "has checksums matching the bundled files (edit a file → refresh its sha256 and bump the version)" do
      manifest.files.each_key do |file_key|
        actual = Digest::SHA256.hexdigest(File.read(File.join(dir, file_key.to_s)))
        expect(manifest.checksum_for(file_key.to_s)).to eq(actual), "stale checksum for #{file_key}"
      end
    end
  end

  describe ".ensure!" do
    around do |example|
      Dir.mktmpdir("system-bundle-spec") do |tmp|
        @tmp = tmp
        old_xdg = ENV["XDG_CONFIG_HOME"]
        ENV["XDG_CONFIG_HOME"] = File.join(tmp, "config")
        example.run
      ensure
        ENV["XDG_CONFIG_HOME"] = old_xdg
      end
    end

    def ship(version, identity)
      dir = File.join(@tmp, "gem-#{version}")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "identity.md"), identity)
      Samagotchi::MemoryBundle::Manifest.write(
        dir: dir, name: described_class::BUNDLE_NAME, version: version, scope: "system",
        files: { "identity.md" => "sha256:#{Digest::SHA256.hexdigest(identity)}" }
      )
      stub_const("#{described_class}::GEM_BUNDLE_DIR", dir)
    end

    def installed_version
      Samagotchi::MemoryBundle::Provenance.new(name: described_class::BUNDLE_NAME).read[:version].to_s
    end

    def installed_identity
      File.read(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"))
    end

    it "upgrades when the shipped bundle is newer" do
      ship("0.1.6", "old\n")
      described_class.ensure!
      ship("0.1.10", "new\n")
      described_class.ensure!

      expect(installed_version).to eq("0.1.10")
      expect(installed_identity).to eq("new\n")
    end

    it "records the new version on a conflict, so the next start doesn't warn again" do
      ship("0.1.6", "old\n")
      described_class.ensure!
      File.write(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"), "mine\n")
      ship("0.1.10", "new\n")

      expect { described_class.ensure! }.to output(/kept local edit in identity\.md/).to_stderr
      expect { described_class.ensure! }.not_to output.to_stderr
      expect(installed_version).to eq("0.1.10")
      expect(installed_identity).to eq("mine\n")
    end

    describe ".sync" do
      it "reports what it did: installed, up to date, updated with kept edits, newer installed" do
        ship("0.1.6", "old\n")
        expect(described_class.sync).to have_attributes(status: :installed, from: nil, to: "0.1.6")
        expect(described_class.sync).to have_attributes(status: :up_to_date, from: "0.1.6", to: "0.1.6")

        File.write(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"), "mine\n")
        ship("0.1.10", "new\n")
        result = nil
        expect { result = described_class.sync }.not_to output.to_stderr
        expect(result).to have_attributes(status: :updated, from: "0.1.6", to: "0.1.10", kept: ["identity.md"], warnings: [])

        ship("0.1.8", "older\n")
        expect(described_class.sync).to have_attributes(status: :newer_installed, from: "0.1.10", to: "0.1.8")
      end

      it "writes nothing with dry_run" do
        ship("0.1.6", "old\n")
        expect(described_class.sync(dry_run: true).status).to eq(:installed)
        expect(Samagotchi::MemoryBundle::Provenance.new(name: described_class::BUNDLE_NAME).read).to be_nil

        described_class.sync
        ship("0.1.10", "new\n")
        expect(described_class.sync(dry_run: true)).to have_attributes(status: :updated, from: "0.1.6", to: "0.1.10", kept: [])
        File.write(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"), "mine\n")
        expect(described_class.sync(dry_run: true).kept).to eq(["identity.md"])
        expect(installed_identity).to eq("mine\n")
        expect(installed_version).to eq("0.1.6")
      end

      it "reports a restored file" do
        ship("0.1.6", "old\n")
        described_class.sync
        File.delete(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"))
        expect(described_class.sync.status).to eq(:restored)
        expect(installed_identity).to eq("old\n")
      end
    end

    it "leaves a newer installed bundle alone when the shipped one is older" do
      ship("0.1.7", "new\n")
      described_class.ensure!
      ship("0.1.6", "old\n")

      expect(described_class.ensure!).to be(false)
      expect(installed_version).to eq("0.1.7")
      expect(installed_identity).to eq("new\n")
    end

    it "notes a newer installed bundle once per installed/shipped pair" do
      ship("0.1.13", "new\n")
      described_class.ensure!
      ship("0.1.8", "old\n")

      note = "[samagotchi-system] installed system bundle 0.1.13 is newer than this chi's 0.1.8; left as is\n"
      expect { described_class.ensure! }.to output(note).to_stderr
      expect { described_class.ensure! }.not_to output.to_stderr

      ship("0.1.11", "mid\n")
      expect { described_class.ensure! }.to output(/0\.1\.13 is newer than this chi's 0\.1\.11/).to_stderr
      ship("0.1.8", "old\n")
      expect { described_class.ensure! }.not_to output.to_stderr
      expect(installed_identity).to eq("new\n")
    end

    it "notes again after the installed bundle changes" do
      ship("0.1.12", "a\n")
      described_class.ensure!
      ship("0.1.8", "old\n")
      expect { described_class.ensure! }.to output(/0\.1\.12 is newer/).to_stderr

      ship("0.1.13", "b\n")
      described_class.ensure!
      ship("0.1.8", "old\n")
      expect { described_class.ensure! }.to output(/0\.1\.13 is newer/).to_stderr
    end

    it "does not restore a missing file from an older shipped bundle" do
      ship("0.1.7", "new\n")
      described_class.ensure!
      File.delete(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"))
      ship("0.1.6", "old\n")

      described_class.ensure!
      expect(installed_version).to eq("0.1.7")
      expect(File).not_to exist(File.join(Samagotchi::MemoryBundle::Installer.system_dir, "identity.md"))
    end

    it "installs once, without warnings, when parallel processes start on a fresh config dir" do
      ship("0.1.7", "new\n")
      # The race is timing-dependent: run it on a few fresh config dirs.
      3.times do |round|
        ENV["XDG_CONFIG_HOME"] = File.join(@tmp, "config-#{round}")
        gate_r, gate_w = IO.pipe
        err_r, err_w = IO.pipe
        pids = 8.times.map do
          fork do
            gate_w.close
            err_r.close
            $stderr.reopen(err_w)
            gate_r.read # released when the parent closes the write end
            described_class.ensure!
            exit!(0)
          end
        end
        gate_r.close
        err_w.close
        gate_w.close
        pids.each { |pid| Process.wait(pid) }

        expect(err_r.read).to eq("")
        expect(installed_version).to eq("0.1.7")
        expect(installed_identity).to eq("new\n")
      end
    end
  end
end
