# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/plugin/context"
require "samagotchi/memory_bundle/installer"
require "samagotchi/context_providers"

# The github-pr bundle as installed: its provider resolves PR URLs, and its
# plugin's init task attaches the branch's open PR to the session (not to a
# scratch session or a delegate child), quietly doing nothing without gh,
# a branch or an open PR.
RSpec.describe "The github-pr bundle" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/github-pr", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("github-pr-plugin") }
  let(:state_dir) { File.join(tmpdir, "state", "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                       .tap { |s| s.save(state_dir: state_dir) }
  end
  let(:scratch) { false }
  let(:ctx) do
    host = Samagotchi::Plugin::Host.new(session_id: -> { session.id }, cwd: -> { tmpdir }, state_dir: -> { state_dir },
                                        scratch: -> { scratch })
    Samagotchi::Plugin::Context.new(bundle: "github-pr", label: "plugin.rb (bundle github-pr)", settings: {}, host: host)
  end
  let(:plugin) do
    namespace = Module.new
    namespace.module_eval(File.read(File.join(shipped, "plugin.rb")), "plugin.rb", 1)
    namespace.const_get(:Plugin).new
  end
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  around do |example|
    path = ENV.fetch("PATH", nil)
    ENV["PATH"] = "#{bin}:/usr/bin:/bin"
    example.run
  ensure
    ENV["PATH"] = path
  end

  before do
    Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "github-pr", scope: "system", strict: true).run
  end

  after { FileUtils.rm_rf(tmpdir) }

  def fake(name, script)
    File.write(File.join(bin, name), "#!/bin/sh\n#{script}\n")
    File.chmod(0o755, File.join(bin, name))
  end

  def on_branch_with(pr)
    fake("git", 'echo "feat/x"')
    fake("gh", "echo '#{JSON.generate(pr)}'")
  end

  it "resolves a PR URL to pr-<n>, run by its installed script" do
    resolved = Samagotchi::ContextProviders.resolve("https://github.com/acme/app/pull/42/files")

    expect(resolved).to have_attributes(bundle: "github-pr", name: "pr-42", hint: "https://github.com/acme/app/pull/42",
                                        cmd: "ruby {bundle_dir}/scripts/pr_context.rb https://github.com/acme/app/pull/42",
                                        every_seconds: 300)
  end

  it "attaches the branch's open PR to the session, once" do
    on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")

    expect(plugin.attach_branch_pr(ctx)).to eq("attached pr-42")
    expect(own.source("pr-42")).to have_attributes(provider: "github-pr", added_by: "plugin:github-pr",
                                                   why: "branch feat/x has open PR #42", scope: "session")
    expect(plugin.attach_branch_pr(ctx)).to eq("pr-42 is attached already")
  end

  it "attaches nothing for a closed PR, no PR, no branch, or no gh" do
    on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "MERGED")
    expect(plugin.attach_branch_pr(ctx)).to eq("pull request #42 isn't open")

    fake("gh", "echo 'no pull requests found' >&2; exit 1")
    expect(plugin.attach_branch_pr(ctx)).to eq("no pull request for feat/x")

    FileUtils.rm(File.join(bin, "gh"))
    expect(plugin.attach_branch_pr(ctx)).to eq("no pull request for feat/x")

    fake("git", "exit 128")
    expect(plugin.attach_branch_pr(ctx)).to eq("not on a branch")
    expect(own.sources).to eq([])
  end

  context "in a scratch session" do
    let(:scratch) { true }

    it "attaches nothing" do
      on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")
      expect(plugin.attach_branch_pr(ctx)).to eq("skipped: a scratch session")
    end
  end

  context "in a delegate child" do
    let(:session) do
      parent = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
      parent.save(state_dir: state_dir)
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir, parent_id: parent.id,
                                      delegate: true).tap { |s| s.save(state_dir: state_dir) }
    end

    it "attaches nothing" do
      on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")
      expect(plugin.attach_branch_pr(ctx)).to eq("skipped: a delegate child")
    end
  end
end
