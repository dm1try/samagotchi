# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "digest"
require "rbconfig"
require "yaml"
require "samagotchi/context_providers"
require "samagotchi/context_sources"
require "samagotchi/context_fetch"
require "samagotchi/memory_bundle/installer"

# A URL resolves through the installed bundles' declarative providers
# (their provenance's context_providers); a provider's source finds its
# bundle's folder when its command runs.
RSpec.describe Samagotchi::ContextProviders do
  let(:tmpdir) { Dir.mktmpdir("context-providers") }
  let(:bundles_dir) { File.join(Samagotchi::MemoryPaths.system_dir, ".bundles") }
  let(:script) { "puts 'hi'\n" }
  let(:provider) do
    { "match" => '\Ahttps://example\.com/([^/]+)/pull/(\d+)', "name" => 'pr-\2',
      "cmd" => "ruby {bundle_dir}/scripts/pr.rb {url}", "why" => "a PR", "every_seconds" => 120 }
  end

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  after { FileUtils.rm_rf(tmpdir) }

  def install(name = "prs", providers: [provider], script_text: script, requires_chi: nil)
    dir = File.join(bundles_dir, name)
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    File.write(File.join(dir, "scripts", "pr.rb"), script_text)
    File.write(File.join(dir, "manifest.json"), JSON.generate(
      "name" => name, "version" => "1.0.0", "scope" => "system", "files" => {},
      "requires_chi" => requires_chi,
      "scripts" => { "pr.rb" => { "sha256" => "sha256:#{Digest::SHA256.hexdigest(script_text)}" } },
      "context_providers" => providers
    ))
    dir
  end

  def install_normally
    source_dir = File.join(tmpdir, "normal-source")
    FileUtils.mkdir_p(File.join(source_dir, "scripts"))
    File.write(File.join(source_dir, "scripts", "pr.rb"), script)
    File.write(File.join(source_dir, "manifest.yml"), YAML.dump(
      "name" => "prs", "version" => "1.0.0", "scope" => "system", "files" => {},
      "scripts" => { "pr.rb" => "sha256:#{Digest::SHA256.hexdigest(script)}" },
      "context_providers" => [provider]
    ))
    Samagotchi::MemoryBundle::Installer.new(source: source_dir, name: "prs", scope: "system", strict: true).run
    File.join(bundles_dir, "prs")
  end

  describe ".resolve" do
    it "fills the name from the match's groups and {url} shell-quoted, keeping {bundle_dir}" do
      install

      resolved = described_class.resolve("https://example.com/acme/pull/12")

      expect(resolved).to eq(described_class::Resolved.new(
        bundle: "prs", name: "pr-12", cmd: "ruby {bundle_dir}/scripts/pr.rb https://example.com/acme/pull/12",
        why: "a PR", hint: "https://example.com/acme/pull/12", every_seconds: 120
      ))
    end

    it "takes the matched URL only, quoted for the shell" do
      install(providers: [provider.merge("match" => '\Ahttps://example\.com/\S+')])

      resolved = described_class.resolve("https://example.com/a'b;x/pull/3 trailing")

      expect(resolved.cmd).to eq("ruby {bundle_dir}/scripts/pr.rb https://example.com/a\\'b\\;x/pull/3")
    end

    it "is nil for a URL no installed bundle matches, or with no bundles at all" do
      expect(described_class.resolve("https://example.com/acme/pull/12")).to be_nil
      install
      expect(described_class.resolve("https://other.example/pull/12")).to be_nil
    end

    it "refuses a name the provider makes that isn't a source name" do
      install(providers: [provider.merge("name" => 'PR \1')])
      expect { described_class.resolve("https://example.com/acme/pull/12") }
        .to raise_error(described_class::Invalid, /bundle prs makes "PR acme" of it, which isn't a source name/)
    end

    it "reads the providers from the kept manifest.yml when the record lacks them" do
      dir = install_normally
      record = File.join(dir, "manifest.json")
      File.write(record, JSON.generate(JSON.parse(File.read(record)).except("context_providers")))

      expect(described_class.resolve("https://example.com/acme/pull/12")&.name).to eq("pr-12")
      expect(described_class.any?).to be(true)
    end

    it "skips a bundle whose providers don't parse" do
      install("bad", providers: [{ "match" => "(" }])
      install
      expect(described_class.resolve("https://example.com/acme/pull/12")&.bundle).to eq("prs")
    end
  end

  describe ".command_for" do
    def source(provider: "prs", cmd: "ruby {bundle_dir}/scripts/pr.rb x")
      Samagotchi::ContextSources::Source.new(name: "pr-12", cmd: cmd, every_seconds: nil, why: nil, hint: nil,
                                             scope: "session", added_by: "cli", created_at: nil, provider: provider)
    end

    it "puts the installed bundle's folder in for {bundle_dir}" do
      dir = install
      expect(described_class.command_for(source)).to eq("ruby #{Shellwords.escape(dir)}/scripts/pr.rb x")
    end

    # Review item 2: `ruby` on PATH may be another Ruby (macOS 2.6, a
    # launchd PATH); {ruby} is the one chi runs on.
    it "puts chi's own Ruby in for {ruby}" do
      dir = install
      expect(described_class.command_for(source(cmd: "{ruby} {bundle_dir}/scripts/pr.rb x")))
        .to eq("#{Shellwords.escape(RbConfig.ruby)} #{Shellwords.escape(dir)}/scripts/pr.rb x")
    end

    it "leaves a source with no provider as it is" do
      expect(described_class.command_for(source(provider: nil, cmd: "echo {bundle_dir}"))).to eq("echo {bundle_dir}")
    end

    it "refuses when the bundle is gone, or a script changed since it was installed" do
      expect { described_class.command_for(source) }.to raise_error(described_class::Invalid, "bundle prs isn't installed")
      dir = install
      File.write(File.join(dir, "scripts", "pr.rb"), "puts 'edited'\n")
      expect { described_class.command_for(source) }
        .to raise_error(described_class::Invalid, %r{bundle prs's scripts/pr.rb differs from the installed one})
    end

    it "refuses a script edited after a normal bundle install" do
      dir = install_normally
      script_path = File.join(dir, "scripts", "pr.rb")
      expect(File.symlink?(script_path)).to be(false)
      File.write(script_path, "puts 'edited after install'\n")

      expect { described_class.command_for(source) }
        .to raise_error(described_class::Invalid, %r{bundle prs's scripts/pr.rb differs from the installed one})
    end
  end

  describe "a bundle whose requires_chi this chi doesn't meet" do
    def source(provider)
      Samagotchi::ContextSources::Source.new(name: "pr-12", cmd: "ruby {bundle_dir}/scripts/pr.rb x",
                                             every_seconds: nil, why: nil, hint: nil, scope: "session",
                                             added_by: "cli", created_at: nil, provider: provider)
    end

    it "is skipped by .resolve and .any?, and said once" do
      install("old-prs", requires_chi: ">= 99.0")

      expect(Samagotchi::Log).to receive(:warn).with(:context, "providers_too_new",
                                                     hash_including(bundle: "old-prs", version: "1.0.0", requires_chi: ">= 99.0"))
      expect(described_class.resolve("https://example.com/acme/pull/12")).to be_nil
      expect(described_class.any?).to be(false)
    end

    it "says it once per process per bundle and version, not per call" do
      dir = install("again-prs", requires_chi: ">= 99.0")
      notices = []
      allow(Samagotchi::Log).to receive(:warn) { |_tag, event, fields| notices << [event, fields[:version]] }

      3.times { described_class.resolve("https://example.com/acme/pull/12") }
      described_class.any?
      expect(notices.count { |event, _| event == "providers_too_new" }).to eq(1)

      # A new version of the same bundle is worth saying again.
      record = File.join(dir, "manifest.json")
      File.write(record, JSON.generate(JSON.parse(File.read(record)).merge("version" => "2.0.0")))
      described_class.resolve("https://example.com/acme/pull/12")
      expect(notices.count { |event, _| event == "providers_too_new" }).to eq(2)
    end

    it "refuses a source already attached to it, by name" do
      install("command-old", requires_chi: ">= 99.0")

      expect { described_class.command_for(source("command-old")) }
        .to raise_error(described_class::Invalid, "bundle command-old: it requires chi >= 99.0 (this is chi #{Samagotchi::VERSION})")
    end

    it "leaves a bundle this chi does meet alone" do
      dir = install("current-prs", requires_chi: ">= 0.1.0")

      expect(described_class.resolve("https://example.com/acme/pull/12")&.bundle).to eq("current-prs")
      expect(described_class.command_for(source("current-prs"))).to eq("ruby #{Shellwords.escape(dir)}/scripts/pr.rb x")
    end
  end

  it "makes a provider source whose bundle is gone a failed fetch (ContextFetch)" do
    location = Samagotchi::ContextSources.session_location("11111111-2222-3333-4444-555555555555",
                                                           state_dir: File.join(tmpdir, "state", "sessions"))
    location.add(Samagotchi::ContextSources::Source.new(name: "pr-12", cmd: "ruby {bundle_dir}/scripts/pr.rb x",
                                                        every_seconds: nil, why: nil, hint: nil, scope: "session",
                                                        added_by: "cli", created_at: nil, provider: "prs"))
    attached = Samagotchi::ContextSources::Attached.new(source: location.source("pr-12"), location: location, shadowed: false)

    outcome = Samagotchi::ContextFetch.fetch(attached, cwd: tmpdir)

    expect(outcome).to have_attributes(status: :error, error: "bundle prs isn't installed")
  end
end
