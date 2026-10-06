# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/plugin/context"

# ctx.context (docs/plugins.md, Attached context): a plugin attaches
# context to its session, through a bundle's provider (a URL) or with its
# own command, and lists what's attached.
RSpec.describe Samagotchi::Plugin::AttachedContext do
  let(:tmpdir) { Dir.mktmpdir("plugin-context") }
  let(:state_dir) { File.join(tmpdir, "state", "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir).tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:session_id) { session.id }
  let(:host) do
    Samagotchi::Plugin::Host.new(session_id: -> { session_id }, cwd: -> { tmpdir }, state_dir: -> { state_dir })
  end
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "prs", label: "plugin.rb (bundle prs)", settings: {}, host: host) }
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }
  after { FileUtils.rm_rf(tmpdir) }

  def install_provider
    dir = File.join(Samagotchi::MemoryPaths.system_dir, ".bundles", "prs")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "manifest.json"), JSON.generate(
      "name" => "prs", "version" => "1.0.0", "files" => {},
      "context_providers" => [{ "match" => '\Ahttps://example\.com/pull/(\d+)', "name" => 'pr-\1',
                                "cmd" => "ruby {bundle_dir}/scripts/pr.rb {url}", "why" => "a PR" }]
    ))
  end

  it "attaches a URL through a provider to the session, by the plugin, with its own name and why" do
    install_provider

    name = ctx.context.attach(url: "https://example.com/pull/4", name: "pr-4", why: "branch x has open PR #4")

    expect(name).to eq("pr-4")
    expect(own.source("pr-4")).to have_attributes(
      provider: "prs", added_by: "plugin:prs", why: "branch x has open PR #4", hint: "https://example.com/pull/4",
      cmd: "ruby {bundle_dir}/scripts/pr.rb https://example.com/pull/4", scope: "session"
    )
  end

  it "attaches its own command, and leaves a source already attached as it is" do
    expect(ctx.context.attach(name: "date", cmd: "date", why: "the time", every_seconds: 60)).to eq("date")
    expect(own.source("date")).to have_attributes(cmd: "date", every_seconds: 60, added_by: "plugin:prs", provider: nil)

    expect(ctx.context.attach(name: "date", cmd: "other")).to eq("date")
    expect(own.source("date").cmd).to eq("date")
  end

  it "doesn't attach again what was removed from the session (by its name or its URL), until an explicit add" do
    install_provider
    ctx.context.attach(url: "https://example.com/pull/4", name: "pr-4")
    own.remove("pr-4")

    expect(ctx.context.attach(url: "https://example.com/pull/4", name: "pr-4")).to be_nil
    expect(ctx.context.attach(url: "https://example.com/pull/4", name: "other")).to be_nil
    expect(ctx.context.declined?("pr-4")).to be(true)
    expect(own.sources).to eq([])

    # The user's own add (chi context add, the web's + URL) clears it.
    own.add(Samagotchi::ContextSources::Source.new(name: "pr-4", cmd: "x", every_seconds: nil, why: nil, hint: nil,
                                                   scope: "session", added_by: "cli", created_at: nil))
    expect(ctx.context.declined?("pr-4")).to be(false)
  end

  it "lists the session's sources" do
    ctx.context.attach(name: "date", cmd: "date", why: "the time")
    expect(ctx.context.list).to eq([{ name: "date", scope: "session", why: "the time", hint: nil, fetched_at: nil,
                                      error: nil, provider: nil }])
  end

  it "says why it can't attach" do
    expect { ctx.context.attach(url: "https://nowhere.example/1") }
      .to raise_error(described_class::Error, "no installed bundle resolves https://nowhere.example/1")
    expect { ctx.context.attach(name: "x") }.to raise_error(described_class::Error, /give url: or cmd:/)
    expect { ctx.context.attach(name: "Bad Name", cmd: "date") }.to raise_error(described_class::Error, /isn't a source name/)
    expect { ctx.context.attach(name: "x", cmd: "date", every_seconds: 5) }.to raise_error(described_class::Error, /least is 30/)
  end

  context "with no session yet" do
    let(:session_id) { nil }

    it "attaches nothing" do
      expect { ctx.context.attach(name: "date", cmd: "date") }.to raise_error(described_class::Error, "this session has no id yet")
      expect(ctx.context.list).to eq([])
    end
  end
end

# ctx.scratch? and ctx.delegate?: what a plugin's auto-attach skips (D12).
RSpec.describe Samagotchi::Plugin::Context, "session kind" do
  let(:tmpdir) { Dir.mktmpdir("plugin-kind") }
  let(:state_dir) { File.join(tmpdir, "sessions").tap { |d| FileUtils.mkdir_p(d) } }

  after { FileUtils.rm_rf(tmpdir) }

  def ctx_for(session, scratch: false)
    host = Samagotchi::Plugin::Host.new(session_id: -> { session&.id }, cwd: -> { tmpdir }, state_dir: -> { state_dir },
                                        scratch: -> { scratch })
    described_class.new(bundle: "b", label: "l", settings: {}, host: host)
  end

  def make(**opts)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir, **opts)
                       .tap { |s| s.save(state_dir: state_dir) }
  end

  it "says whether the session is a scratch one or a delegate child" do
    parent = make
    expect(ctx_for(parent)).to have_attributes(scratch?: false, delegate?: false)
    expect(ctx_for(parent, scratch: true).scratch?).to be(true)
    expect(ctx_for(make(parent_id: parent.id, delegate: true)).delegate?).to be(true)
    expect(ctx_for(nil).delegate?).to be(false)
  end
end
