# frozen_string_literal: true

require "tmpdir"
require "yaml"
require "digest"
require "samagotchi/guardrails"
require "samagotchi/hooks"

# The known-names bundle (lib/samagotchi/bundles/known-names): a near miss
# of a protected name in a tool call's command or paths is rejected with
# the right spelling (or corrected, or asked about).
RSpec.describe "The known-names bundle" do
  let(:bundle_dir) { File.expand_path("../../lib/samagotchi/bundles/known-names", __dir__) }
  let(:manifest) { YAML.safe_load(File.read(File.join(bundle_dir, "manifest.yml"))) }
  # A repo named samagotchi whose git user is "Dm1tri Dedov" <dm1try@x.io>.
  let(:repo) do
    base = File.realpath(Dir.mktmpdir("known-names"))
    dir = File.join(base, "samagotchi")
    Dir.mkdir(dir)
    system("git", "-C", dir, "init", "-q")
    system("git", "-C", dir, "config", "user.name", "Dm1tri Dedov")
    system("git", "-C", dir, "config", "user.email", "dm1try@x.io")
    dir
  end
  let(:context) { Samagotchi::Guardrails::Context.new(cwd: repo) }
  let(:settings) { { "names" => ["dzmitrydziadou"] } }
  let(:notices) { [] }
  let(:asked) { [] }
  let(:answer) { nil }
  let(:registry) do
    registry = Samagotchi::Hooks::Registry.new
    loaded = Samagotchi::Hooks::BundleLoader.load(bundle_name: "known-names", hooks_dir: File.join(bundle_dir, "hooks"),
                                                  metadata: manifest["hooks"], registry: registry, settings: settings)
    raise "the hook did not load" unless loaded == 1

    registry.runtime = Samagotchi::Hooks::Runtime.new(
      notify: ->(**kw) { notices << kw },
      ask_user: ->(**kw) { asked << kw; answer },
      stop_turn: ->(**) { false }
    )
    registry
  end
  let(:gate) { Samagotchi::Guardrails::Gate.new(-> { registry }, context_lookup: -> { context }) }

  before do
    allow(Dir).to receive(:home).and_return("/Users/dmitrydedov")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("USER").and_return("dmitrydedov")
  end

  after { FileUtils.rm_rf(File.dirname(repo)) }

  def verdict_for(call) = gate.evaluate(call, iteration: 1, params: "#{call[:name]} #{call[:content] || call[:path]}")
  def shell(command) = verdict_for({ name: "execute", content: command })

  CAUGHT = {
    "ls /Users/dmitrydedvo" => %w[dmitrydedvo dmitrydedov],
    "cat ~/../dmitrydedvo/x" => %w[dmitrydedvo dmitrydedov],
    "git -C /Users/dmitrydedov/projects/samagothci status" => %w[samagothci samagotchi],
    "ssh dm1tro@host" => %w[dm1tro Dm1tri],
    "ls /home/dzmitryziadou/work" => %w[dzmitryziadou dzmitrydziadou],
    "cd ~/projects && cat /Users/Dmitrydedvo/notes.txt" => %w[Dmitrydedvo dmitrydedov]
  }.freeze

  LET_THROUGH = [
    "ls /Users/dmitrydedov", "ls ~/projects", "echo $HOME/x", "cat ~/x", "ls dmitr", "ls dmitrz",
    "cd samagotchi-known-names && git status", "ls /Users/dmitrydedov/projects/samagotchi", "ps aux | grep processes",
    "ssh dm1try@host", "echo dzmitrydziadou"
  ].freeze

  CAUGHT.each do |command, (miss, name)|
    it "rejects: #{command}" do
      v = shell(command)
      expect(v).to be_deny
      expect(v.deny_text).to eq(
        "denied by guardrail (hook known_names, bundle known-names): \"#{miss}\" in the command is 1 edit away from the known name \"#{name}\". " \
        "The user was not asked. Retry with \"#{name}\". If \"#{miss}\" is really what you meant, say so to the user instead of retrying."
      )
      expect(notices).to eq([{ text: "rejected execute: \"#{miss}\" looks like \"#{name}\"", level: :info,
                               hook: "known_names.rb (bundle known-names)" }])
    end
  end

  LET_THROUGH.each do |command|
    it "lets through: #{command}" do
      expect(shell(command)).to be_allow
      expect(notices).to be_empty
    end
  end

  it "scans a read's path and a write's path, not a write's content" do
    expect(verdict_for({ name: "read", content: "~/../dmitrydedvo/x" }).reason).to include('"dmitrydedvo" in the path')
    expect(verdict_for({ name: "write", path: "/Users/dmitrydedvo/a.txt", content: "x" })).to be_deny
    expect(verdict_for({ name: "write", path: "a.txt", content: "dmitrydedvo wrote this" })).to be_allow
  end

  it "counts two edits for a long name" do
    v = shell("ls /home/dzmitridzadou")
    expect(v.reason).to eq('"dzmitridzadou" in the command is 2 edits away from the known name "dzmitrydziadou"')
  end

  describe "settings" do
    context "ignore:" do
      let(:settings) { { "ignore" => ["dm1tri"] } }

      it "drops a name" do
        expect(shell("ssh dm1tro@host").reason).to include('known name "dm1try"')
      end
    end

    context "min_length:" do
      let(:settings) { { "names" => ["dzmitrydziadou"], "min_length" => 12 } }

      it "skips shorter names and tokens" do
        expect(shell("ssh dm1tro@host")).to be_allow
        expect(shell("ls /home/dzmitryziadou")).to be_deny
      end
    end

    context "max_distance:" do
      let(:settings) { { "max_distance" => 2 } }

      it "widens the match" do
        expect(shell("ls dmitrz").reason).to include('2 edits away from the known name "Dm1tri"')
      end
    end

    context "derive: []" do
      let(:settings) { { "names" => ["dzmitrydziadou"], "derive" => [] } }

      it "protects only the configured names" do
        expect(shell("ls /Users/dmitrydedvo")).to be_allow
        expect(shell("ls /home/dzmitryziadou")).to be_deny
      end
    end
  end

  describe "mode: correct" do
    before { settings.merge!("mode" => "correct") }

    it "replaces the near miss in the call (whole tokens, everywhere) and says so" do
      v = shell("ls /Users/dmitrydedvo/a /Users/dmitrydedvo-old; echo dmitrydedvox")
      expect(v).to be_allow
      expect(v.call[:content]).to eq("ls /Users/dmitrydedov/a /Users/dmitrydedov-old; echo dmitrydedvox")
      expect(notices).to eq([{ text: 'corrected "dmitrydedvo" → "dmitrydedov" in execute', level: :info,
                               hook: "known_names.rb (bundle known-names)" }])
    end

    it "corrects a path call's path and a command's cwd" do
      expect(verdict_for({ name: "edit", path: "/Users/dmitrydedvo/a.txt", content: "x" }).call[:path]).to eq("/Users/dmitrydedov/a.txt")
      v = verdict_for({ name: "execute", content: "ls", cwd: "/Users/dmitrydedvo" })
      expect(v.call[:cwd]).to eq("/Users/dmitrydedov")
    end
  end

  describe "mode: ask" do
    before { settings.merge!("mode" => "ask") }

    it "asks with the call and the three options" do
      shell("ls /Users/dmitrydedvo")
      expect(asked).to eq([{ question: "execute: execute ls /Users/dmitrydedvo\n\"dmitrydedvo\" looks like a misspelling of \"dmitrydedov\".",
                             options: ["Correct it and run", "Run as is", "Deny"], header: "known-names", allow_freeform: false,
                             hook: "known_names.rb (bundle known-names)" }])
    end

    context "when the user picks Correct it and run" do
      let(:answer) { { selected: ["Correct it and run"], freeform: nil } }

      it "runs the corrected call" do
        v = shell("ls /Users/dmitrydedvo")
        expect(v).to be_allow
        expect(v.call[:content]).to eq("ls /Users/dmitrydedov")
        expect(notices.map { |n| n[:text] }).to eq(['corrected "dmitrydedvo" → "dmitrydedov" in execute'])
      end
    end

    context "when the user picks Run as is" do
      let(:answer) { { selected: ["Run as is"], freeform: nil } }

      it "runs the call unchanged, quietly" do
        v = shell("ls /Users/dmitrydedvo")
        expect(v).to be_allow
        expect(v.call[:content]).to eq("ls /Users/dmitrydedvo")
        expect(notices).to be_empty
      end
    end

    context "when the user picks Deny" do
      let(:answer) { { selected: ["Deny"], freeform: nil } }

      it "rejects with the advice" do
        expect(shell("ls /Users/dmitrydedvo").deny_text).to include('Retry with "dmitrydedov".')
      end
    end

    it "rejects when there is no one to ask (non-interactive) or the question was dismissed" do
      expect(shell("ls /Users/dmitrydedvo")).to be_deny
      expect(notices.map { |n| n[:text] }).to eq(['rejected execute: "dmitrydedvo" looks like "dmitrydedov"'])
    end
  end

  it "never raises out: a failure inside becomes one warn notice and the call runs" do
    klass = registry && Samagotchi::Hooks::BundleLoader.namespace_for("known-names").const_get(:KnownNames)
    allow(klass).to receive(:distance).and_raise(RuntimeError, "boom")
    expect(shell("ls /Users/dmitrydedvo")).to be_allow
    expect(notices).to eq([{ text: "known-names failed: RuntimeError: boom", level: :warn, hook: "known_names.rb (bundle known-names)" }])
  end

  describe "the distance" do
    let(:klass) { registry && Samagotchi::Hooks::BundleLoader.namespace_for("known-names").const_get(:KnownNames) }

    { %w[dedov dedvo] => 1, %w[dmitrydedov dmitrydedvo] => 1, %w[samagotchi samagothci] => 1, %w[dmitry dmitri] => 1,
      %w[dzmitrydziadou dzmitryziadou] => 1, %w[dzmitrydziadou dzmitridzadou] => 2, %w[abc abc] => 0, %w[abc xyz] => 3,
      %w[samagotchi samagotchi-tui-steering] => 13, ["", "abc"] => 3 }.each do |(a, b), expected|
      it "#{a.inspect} ~ #{b.inspect} = #{expected}" do
        expect(klass.distance(a, b)).to eq(expected)
      end
    end
  end

  it "has a manifest whose file and hook checksums match" do
    manifest["files"].each do |file, sha|
      expect(sha).to eq("sha256:#{Digest::SHA256.hexdigest(File.binread(File.join(bundle_dir, file)))}")
    end
    manifest["hooks"].each do |file, meta|
      expect(meta["sha256"]).to eq("sha256:#{Digest::SHA256.hexdigest(File.binread(File.join(bundle_dir, "hooks", file)))}")
      expect(meta).to include("event" => "before_tool_call", "on_error" => "log")
    end
  end
end
