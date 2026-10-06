# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "digest"
require "rbconfig"
require "samagotchi/context_providers"
require "samagotchi/context_sources"
require "samagotchi/context_fetch"

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

  def install(name = "prs", providers: [provider], script_text: script)
    dir = File.join(bundles_dir, name)
    FileUtils.mkdir_p(File.join(dir, "scripts"))
    File.write(File.join(dir, "scripts", "pr.rb"), script_text)
    File.write(File.join(dir, "manifest.json"), JSON.generate(
      "name" => name, "version" => "1.0.0", "scope" => "system", "files" => {},
      "scripts" => { "pr.rb" => { "sha256" => "sha256:#{Digest::SHA256.hexdigest(script_text)}" } },
      "context_providers" => providers
    ))
    dir
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
