# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "digest"

require "samagotchi/memory_bundle/installer"
require "samagotchi/memory_bundle/uninstaller"

# A bundle's scripts (scripts/<file>, run by its context providers' commands)
# and its declarative context providers (attached context, §3.9): read from
# manifest.yml, installed into the bundle's own dir and recorded in its
# provenance, where any process resolves a URL without loading plugins.
RSpec.describe "Bundle scripts and context providers: manifest, install, provenance" do
  let(:tmpdir) { Dir.mktmpdir("samagotchi-providers-manifest-") }
  let(:bundles_dir) { File.join(Samagotchi::MemoryPaths.system_dir, ".bundles") }
  let(:provenance) { Samagotchi::MemoryBundle::Provenance.new(name: "prs") }
  let(:script) { "puts 1\n" }
  let(:provider) do
    { "match" => '\Ahttps://example\.com/(\w+)/pull/(\d+)', "name" => 'pr-\2',
      "cmd" => "ruby {bundle_dir}/scripts/pr.rb {url}", "why" => "a PR", "every_seconds" => 120 }
  end

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  after { FileUtils.rm_rf(tmpdir) }

  def write_source(scripts: { "pr.rb" => :real }, providers: [provider], content: script)
    src = File.join(tmpdir, "src-#{rand(100_000)}")
    FileUtils.mkdir_p(File.join(src, "scripts"))
    manifest = { "name" => "prs", "version" => "1.0.0", "files" => {} }
    if scripts
      manifest["scripts"] = scripts.to_h do |file, sha|
        File.write(File.join(src, "scripts", file), content) if content
        [file, sha == :real ? "sha256:#{Digest::SHA256.hexdigest(content.to_s)}" : sha]
      end
    end
    manifest["context_providers"] = providers if providers
    File.write(File.join(src, "manifest.yml"), YAML.dump(manifest))
    src
  end

  def install(src, **opts)
    installer = Samagotchi::MemoryBundle::Installer.new(source: src, name: "prs", scope: "system", strict: true, **opts)
    installer.run
    installer
  end

  describe Samagotchi::MemoryBundle::Manifest do
    it "reads scripts: {file: sha256} and context_providers:" do
      manifest = described_class.read(dir: write_source)

      expect(manifest.scripts).to eq("pr.rb" => "sha256:#{Digest::SHA256.hexdigest(script)}")
      expect(manifest.context_providers).to eq([
        Samagotchi::ContextProviders::Provider.new(match: provider["match"], name: 'pr-\2', cmd: provider["cmd"],
                                                   why: "a PR", every_seconds: 120)
      ])
    end

    it "has none when the manifest names none" do
      manifest = described_class.read(dir: write_source(scripts: nil, providers: nil))
      expect(manifest.scripts).to eq({})
      expect(manifest.context_providers).to eq([])
    end

    it "refuses a script outside scripts/, a provider without match, name or cmd, and a match that isn't a regexp" do
      expect { described_class.read(dir: write_source(scripts: { "../x.rb" => :real }, content: nil)) }
        .to raise_error(described_class::ValidationError, %r{scripts: "../x.rb"})
      %w[match name cmd].each do |key|
        expect { described_class.read(dir: write_source(providers: [provider.except(key)])) }
          .to raise_error(described_class::ValidationError, /context_providers: .*#{key}/)
      end
      expect { described_class.read(dir: write_source(providers: [provider.merge("match" => "(")])) }
        .to raise_error(described_class::ValidationError, /isn't a regular expression/)
      expect { described_class.read(dir: write_source(providers: [provider.merge("every_seconds" => 5)])) }
        .to raise_error(described_class::ValidationError, /every_seconds/)
    end
  end

  describe "install" do
    it "copies the scripts into scripts/ and records their sha256 and the providers" do
      installer = install(write_source)

      path = File.join(bundles_dir, "prs", "scripts", "pr.rb")
      expect(File.read(path)).to eq(script)
      data = provenance.read
      expect(data[:scripts]).to eq("pr.rb": { sha256: "sha256:#{Digest::SHA256.hexdigest(script)}" })
      expect(data[:context_providers]).to eq([provider.transform_keys(&:to_sym)])
      expect(installer.warnings).to be_empty
      expect(installer.results["scripts/pr.rb"]).to eq(status: "installed")
      expect(install(write_source, upgrade: true).results["scripts/pr.rb"]).to eq(status: "skipped", reason: "already up to date")
    end

    it "fails when the manifest names a script the bundle doesn't have" do
      expect { install(write_source(content: nil)) }
        .to raise_error(Samagotchi::MemoryBundle::Installer::InstallError, %r{scripts/pr.rb, which the bundle doesn't have})
    end

    it "warns on a declared sha256 that differs" do
      installer = install(write_source(scripts: { "pr.rb" => "sha256:#{"0" * 64}" }))
      expect(installer.warnings.join).to match(/Checksum mismatch for script pr.rb/)
    end

    it "removes the scripts and providers when an upgrade drops them" do
      install(write_source)
      install(write_source(scripts: nil, providers: nil), upgrade: true)

      expect(Dir.exist?(File.join(bundles_dir, "prs", "scripts"))).to be(false)
      expect(provenance.read).not_to include(:scripts, :context_providers)
    end
  end
end
