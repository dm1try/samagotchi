# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "delegate"
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

  it "declines by URL (the provider's name and hint) and by name; an attach then returns nil" do
    install_provider

    expect(ctx.context.decline(url: "https://example.com/pull/4")).to eq("pr-4")
    expect(File.read(own.declined_path("pr-4"))).to eq("https://example.com/pull/4\n")
    expect(ctx.context.attach(url: "https://example.com/pull/4", name: "other")).to be_nil
    expect(ctx.context.declined?(url: "https://example.com/pull/4")).to be(true)
    expect(ctx.context.declined?("other", url: "https://example.com/pull/5")).to be(false)

    expect(ctx.context.decline(name: "ci")).to eq("ci")
    expect(ctx.context.declined?("ci")).to be(true)
    expect(ctx.context.attach(name: "ci", cmd: "date")).to be_nil
    expect(own.sources).to eq([])
  end

  it "keeps an attached source when it declines it" do
    ctx.context.attach(name: "ci", cmd: "date")
    ctx.context.decline(name: "ci")
    expect(own.source("ci")).not_to be_nil
  end

  it "attaches with force: true past a decline, clearing the markers by name and by URL" do
    install_provider
    ctx.context.decline(url: "https://example.com/pull/4", name: "old-name")
    ctx.context.decline(name: "pr-4")

    expect(ctx.context.attach(url: "https://example.com/pull/4", name: "pr-4", force: true)).to eq("pr-4")
    expect(own.source("pr-4")).not_to be_nil
    expect(ctx.context.declined?("pr-4")).to be(false)
    expect(ctx.context.declined?("old-name", url: "https://example.com/pull/4")).to be(false)
  end

  it "checks the URL even when the name isn't a source name" do
    install_provider
    ctx.context.decline(url: "https://example.com/pull/4")

    expect(ctx.context.declined?("Bad Name", url: "https://example.com/pull/4")).to be(true)
    expect(ctx.context.declined?("Bad Name")).to be(false)
  end

  it "returns the name when a second attach of the same source loses the race (a double click)" do
    install_provider
    racing = Class.new(SimpleDelegator) do
      def add(source)
        __getobj__.add(source) # the other attach, between the check and this add
        __getobj__.add(source)
      end
    end
    allow(Samagotchi::ContextSources).to receive(:session_location).and_return(racing.new(own))

    expect(ctx.context.attach(url: "https://example.com/pull/4", force: true)).to eq("pr-4")
    expect(own.source("pr-4")).not_to be_nil
  end

  it "proposes a candidate, once by name, and reads it back" do
    install_provider
    expect(ctx.context.candidates).to eq([])

    candidate = ctx.context.propose(url: "https://example.com/pull/4", title: "#4  Fix\nthe thing",
                                    describe: "more", mentions: ["#4", "feat/x", "#4", " "])

    expect(candidate).to have_attributes(name: "pr-4", url: "https://example.com/pull/4", cmd: nil, title: "#4 Fix the thing",
                                         describe: "more", mentions: ["#4", "feat/x"], proposed_by: "plugin:prs")
    expect(Time.iso8601(candidate.at)).to be_within(5).of(Time.now)
    expect(ctx.context.candidates).to eq([candidate])
    # Idempotent: the first proposal stays.
    expect(ctx.context.propose(url: "https://example.com/pull/4", title: "other")).to eq(candidate)
    expect(ctx.context.propose(name: "ci", cmd: "bin/ci", title: "CI")).to have_attributes(name: "ci", cmd: "bin/ci", url: nil)
    expect(ctx.context.candidates.map(&:name)).to eq(%w[ci pr-4])
    # Neither an attach nor a decline clears it.
    ctx.context.decline(name: "pr-4")
    expect(ctx.context.candidates.first(2).last).to eq(candidate)
  end

  it "proposes nothing the user removed (by name or URL), and says what it can't propose" do
    install_provider
    own.decline("pr-5", "https://example.com/pull/5")
    own.decline("other", "https://example.com/pull/6")

    expect(ctx.context.propose(url: "https://example.com/pull/5", title: "#5")).to be_nil
    expect(ctx.context.propose(url: "https://example.com/pull/6", title: "#6")).to be_nil
    expect(ctx.context.candidates).to eq([])
    expect { ctx.context.propose(url: "https://nowhere.example/1", title: "x") }.to raise_error(described_class::Error, /no installed bundle/)
    expect { ctx.context.propose(name: "x", title: "x") }.to raise_error(described_class::Error, /give url: or cmd:/)
    expect { ctx.context.propose(name: "x", cmd: "date", title: " ") }.to raise_error(described_class::Error, "give title:")
  end

  it "proposes nothing in a review session, or for a source attached already (by name or URL, any scope)" do
    install_provider
    ctx.context.attach(url: "https://example.com/pull/7")
    expect(ctx.context.propose(url: "https://example.com/pull/7", title: "#7")).to be_nil
    expect(ctx.context.propose(url: "https://example.com/pull/7", name: "other", title: "#7")).to be_nil

    session.review = { "subjects" => ["a.md"] }
    session.save(state_dir: state_dir)
    expect(ctx.context.propose(url: "https://example.com/pull/8", title: "#8")).to be_nil
    expect(ctx.context.candidates).to eq([])
  end

  context "with the owner's prompts in the session already (a late proposal)" do
    let(:messages) { [{ role: "user", turn_id: "t1", content: "please review PR #4" }] }
    let(:host) do
      Samagotchi::Plugin::Host.new(session_id: -> { session_id }, cwd: -> { tmpdir }, state_dir: -> { state_dir },
                                   messages: -> { messages })
    end

    it "attaches a new candidate one of them mentions, its why naming the mention" do
      install_provider
      ctx.context.propose(url: "https://example.com/pull/4", title: "#4 Fix", mentions: ["#4"])

      expect(own.source("pr-4")).to have_attributes(why: "you mentioned #4", title: "#4 Fix", provider: "prs",
                                                    hint: "https://example.com/pull/4", added_by: "plugin:prs")
    end

    it "attaches nothing they don't mention" do
      install_provider
      ctx.context.propose(url: "https://example.com/pull/5", title: "#5 Other", mentions: ["#5"])

      expect(own.sources).to eq([])
    end

    it "hands a candidate none of them mentions to the judge, and a mentioned one not, logging each" do
      install_provider
      proposed = []
      host.candidate_proposed = ->(candidate) { proposed << candidate.name }
      ctx.context.propose(url: "https://example.com/pull/5", title: "#5 Other", mentions: ["#5"])
      ctx.context.propose(url: "https://example.com/pull/4", title: "#4 Fix", mentions: ["#4"])

      expect(proposed).to eq(["pr-5"])
      lines = log_lines.map { |line| line.values_at("kind", "name") }
      expect(lines).to eq([%w[proposed pr-5], %w[proposed pr-4], %w[mentioned pr-4]])
      expect(log_lines.last).to include("mention" => "#4", "session_id" => session_id)
    end
  end

  def log_lines
    path = Samagotchi::ContextCandidatesLog.path(state_dir)
    File.exist?(path) ? File.readlines(path).map { |line| JSON.parse(line) } : []
  end

  it "logs a proposal once (with its title and plugin) and a withdrawal" do
    ctx.context.propose(name: "ci", cmd: "date", title: "CI")
    ctx.context.propose(name: "ci", cmd: "date", title: "CI again")
    ctx.context.withdraw("ci")
    ctx.context.withdraw("ci")

    expect(log_lines.map { |line| line["kind"] }).to eq(%w[proposed withdrawn])
    expect(log_lines.first).to include("title" => "CI", "by" => "plugin:prs", "name" => "ci")
    expect(File.stat(Samagotchi::ContextCandidatesLog.path(state_dir)).mode & 0o777).to eq(0o600)
  end

  it "withdraws a candidate, never detaching its source" do
    ctx.context.propose(name: "ci", cmd: "date", title: "CI")
    ctx.context.attach(name: "ci", cmd: "date")

    expect(ctx.context.withdraw("ci")).to be(true)
    expect(ctx.context.withdraw("ci")).to be(false)
    expect(ctx.context.withdraw("Bad Name")).to be(false)
    expect(ctx.context.candidates).to eq([])
    expect(own.source("ci")).not_to be_nil
  end

  it "lists the session's sources" do
    ctx.context.attach(name: "date", cmd: "date", why: "the time")
    expect(ctx.context.list).to eq([{ name: "date", scope: "session", why: "the time", hint: nil, fetched_at: nil,
                                      error: nil, provider: nil, summary: nil }])
  end

  it "lists a source's last summary and the hint its text gave" do
    ctx.context.attach(name: "date", cmd: "date", why: "the time", hint: "first hint")
    own.record_text("date", Samagotchi::ContextSources::Fetched.new(text: "noon", summary: "it is noon", wake: false,
                                                                    hint: "pushed hint"))

    expect(ctx.context.list.first).to include(hint: "pushed hint", summary: "it is noon")
    expect(ctx.context.list.first[:fetched_at]).not_to be_nil
  end

  it "says why it can't attach" do
    expect { ctx.context.attach(url: "https://nowhere.example/1") }
      .to raise_error(described_class::Error, "no installed bundle resolves https://nowhere.example/1")
    expect { ctx.context.attach(name: "x") }.to raise_error(described_class::Error, /give url: or cmd:/)
    expect { ctx.context.attach(name: "Bad Name", cmd: "date") }.to raise_error(described_class::Error, /isn't a source name/)
    expect { ctx.context.attach(name: "x", cmd: "date", every_seconds: 5) }.to raise_error(described_class::Error, /least is 30/)
  end

  context "with a session id whose file isn't saved yet (a plugin command before the first turn)" do
    let(:session_id) { "aaaabbbb-1111-2222-3333-444455556666" }

    it "lists nothing" do
      expect(ctx.context.list).to eq([])
    end
  end

  context "with no session yet" do
    let(:session_id) { nil }

    it "attaches, declines and offers nothing" do
      expect { ctx.context.attach(name: "date", cmd: "date") }.to raise_error(described_class::Error, "this session has no id yet")
      expect { ctx.context.decline(name: "date") }.to raise_error(described_class::Error, "this session has no id yet")
      expect { ctx.context.propose(name: "date", cmd: "date", title: "date") }.to raise_error(described_class::Error, "this session has no id yet")
      expect(ctx.context.list).to eq([])
      expect(ctx.context.declined?("date", url: "https://x")).to be(false)
      expect(ctx.context.candidates).to eq([])
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
