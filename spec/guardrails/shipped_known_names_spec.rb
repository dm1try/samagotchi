# frozen_string_literal: true

require "tmpdir"
require "yaml"
require "digest"
require "samagotchi/guardrails"
require "samagotchi/hooks"
require "samagotchi/tool_call_parser"

# The known-names bundle (lib/samagotchi/bundles/known-names): a near miss
# of a protected name in a tool call's command or paths is rejected with
# the right spelling (or corrected, or asked about).
RSpec.describe "The known-names bundle" do
  let(:bundle_dir) { File.expand_path("../../lib/samagotchi/bundles/known-names", __dir__) }
  let(:manifest) { YAML.safe_load_file(File.join(bundle_dir, "manifest.yml")) }
  # A repo named samagotchi whose git user is "J0hnni Doe" <j0hnny@example.com>.
  let(:repo) do
    base = File.realpath(Dir.mktmpdir("known-names"))
    dir = File.join(base, "samagotchi")
    Dir.mkdir(dir)
    system("git", "-C", dir, "init", "-q")
    system("git", "-C", dir, "config", "user.name", "J0hnni Doe")
    system("git", "-C", dir, "config", "user.email", "j0hnny@example.com")
    dir
  end
  let(:context) { Samagotchi::Guardrails::Context.new(cwd: repo) }
  let(:settings) { { "names" => ["jonathandoe"] } }
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
    allow(Dir).to receive(:home).and_return("/home/johndoe")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("USER").and_return("johndoe")
  end

  after { FileUtils.rm_rf(File.dirname(repo)) }

  def verdict_for(call) = gate.evaluate(call, iteration: 1, params: "#{call[:name]} #{call[:content] || call[:path]}")
  def shell(command) = verdict_for({ name: "execute", content: command })

  caught = {
    "ls /home/johndeo" => %w[johndeo johndoe],
    "cat ~/../johndeo/x" => %w[johndeo johndoe],
    "git -C /home/johndoe/projects/samagothci status" => %w[samagothci samagotchi],
    "ssh j0hnno@host" => %w[j0hnno J0hnni],
    "ls /home/jonathndoe/work" => %w[jonathndoe jonathandoe],
    "cd ~/projects && cat /home/Johndeo/notes.txt" => %w[Johndeo johndoe],
    # A glob in another path segment: "/" splits first, the typo is still caught.
    "ls /home/johndeo/*" => %w[johndeo johndoe],
    # "~name" is that user's home: "~" splits, the name after it is checked.
    "ls ~johndeo/x" => %w[johndeo johndoe]
  }.freeze

  let_through = [
    "ls /home/johndoe", "ls ~/projects", "echo $HOME/x", "cat ~/x", "ls johnn", "ls johnnz",
    "cd samagotchi-known-names && git status", "ls /home/johndoe/projects/samagotchi", "ps aux | grep processes",
    "ssh j0hnny@host", "echo jonathandoe", "ls ~johndoe", "cat ~johndoe/projects/samagotchi/x",
    # A token with a shell glob (*?[]{}) is not checked: a glob of a known name isn't a typo.
    "ls -d johndoe*", "ls /home/johndoe?", "ls /home/johndoe/project?", "cat samagotchi[12].log",
    "ls {johndoe,other}", "rm -rf samagotchi-*", "ls -d samagotchi*"
  ].freeze

  caught.each do |command, (miss, name)|
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

  let_through.each do |command|
    it "lets through: #{command}" do
      expect(shell(command)).to be_allow
      expect(notices).to be_empty
    end
  end

  it "scans a read's path and a write's path, not a write's content" do
    expect(verdict_for({ name: "read", content: "~/../johndeo/x" }).reason).to include('"johndeo" in the path')
    expect(verdict_for({ name: "write", path: "/home/johndeo/a.txt", content: "x" })).to be_deny
    expect(verdict_for({ name: "write", path: "a.txt", content: "johndeo wrote this" })).to be_allow
  end

  it "counts two edits for a long name" do
    v = shell("ls /home/jonathendou")
    expect(v.reason).to eq('"jonathendou" in the command is 2 edits away from the known name "jonathandoe"')
  end

  describe "settings" do
    context "ignore:" do
      let(:settings) { { "ignore" => ["j0hnni"] } }

      it "drops a name" do
        expect(shell("ssh j0hnno@host").reason).to include('known name "j0hnny"')
      end
    end

    context "min_length:" do
      let(:settings) { { "names" => ["jonathandoe"], "min_length" => 10 } }

      it "skips shorter names and tokens" do
        expect(shell("ssh j0hnno@host")).to be_allow
        expect(shell("ls /home/jonathndoe")).to be_deny
      end
    end

    context "max_distance:" do
      let(:settings) { { "max_distance" => 2 } }

      it "widens the match" do
        expect(shell("ls johnnz").reason).to include('2 edits away from the known name "J0hnni"')
      end
    end

    context "derive: []" do
      let(:settings) { { "names" => ["jonathandoe"], "derive" => [] } }

      it "protects only the configured names" do
        expect(shell("ls /home/johndeo")).to be_allow
        expect(shell("ls /home/jonathndoe")).to be_deny
      end
    end
  end

  describe "mode: correct" do
    before { settings.merge!("mode" => "correct") }

    it "replaces the near miss in the call (whole tokens, everywhere) and says so" do
      v = shell("ls /home/johndeo/a /home/johndeo-old; echo johndeox")
      expect(v).to be_allow
      expect(v.call[:content]).to eq("ls /home/johndoe/a /home/johndoe-old; echo johndeox")
      expect(notices).to eq([{ text: 'corrected "johndeo" → "johndoe" in execute', level: :info,
                               hook: "known_names.rb (bundle known-names)" }])
    end

    it "keeps the \"~\" of a \"~name\" it corrects" do
      expect(shell("ls ~johndeo/x").call[:content]).to eq("ls ~johndoe/x")
    end

    it "corrects a path call's path and a command's cwd" do
      expect(verdict_for({ name: "edit", path: "/home/johndeo/a.txt", content: "x" }).call[:path]).to eq("/home/johndoe/a.txt")
      v = verdict_for({ name: "execute", content: "ls", cwd: "/home/johndeo" })
      expect(v.call[:cwd]).to eq("/home/johndoe")
    end

    it "also replaces it in an edit's old and new text" do
      gemma = Samagotchi::ToolCallParser::Gemma.new(Samagotchi::ModelProfile.gemma4)
      d = '<|"|>'
      edit = gemma.parse("<|tool_call>call:edit{path:#{d}/home/johndeo/a.txt#{d},old_text:#{d}johndeo#{d}," \
                         "new_text:#{d}johndeo!#{d}}<tool_call|>").first
      expect(verdict_for(edit).call).to include(path: "/home/johndoe/a.txt", old_text: "johndeo", new_text: "johndeo!")
      write = { name: "write", path: "/home/johndeo/a.txt", content: "johndeo" }
      expect(verdict_for(write).call).to include(path: "/home/johndoe/a.txt", content: "johndeo")
    end
  end

  describe "mode: ask" do
    before { settings.merge!("mode" => "ask") }

    it "asks with the call and the three options" do
      shell("ls /home/johndeo")
      expect(asked).to eq([{ question: "execute: execute ls /home/johndeo\n\"johndeo\" looks like a misspelling of \"johndoe\".",
                             options: ["Correct it and run", "Run as is", "Deny"], header: "known-names", allow_freeform: false,
                             hook: "known_names.rb (bundle known-names)" }])
    end

    context "when the user picks Correct it and run" do
      let(:answer) { { selected: ["Correct it and run"], freeform: nil } }

      it "runs the corrected call" do
        v = shell("ls /home/johndeo")
        expect(v).to be_allow
        expect(v.call[:content]).to eq("ls /home/johndoe")
        expect(notices.map { |n| n[:text] }).to eq(['corrected "johndeo" → "johndoe" in execute'])
      end
    end

    context "when the user picks Run as is" do
      let(:answer) { { selected: ["Run as is"], freeform: nil } }

      it "runs the call unchanged, quietly" do
        v = shell("ls /home/johndeo")
        expect(v).to be_allow
        expect(v.call[:content]).to eq("ls /home/johndeo")
        expect(notices).to be_empty
      end
    end

    context "when the user picks Deny" do
      let(:answer) { { selected: ["Deny"], freeform: nil } }

      it "rejects with the advice" do
        expect(shell("ls /home/johndeo").deny_text).to include('Retry with "johndoe".')
      end
    end

    it "rejects when there is no one to ask (non-interactive) or the question was dismissed" do
      expect(shell("ls /home/johndeo")).to be_deny
      expect(notices.map { |n| n[:text] }).to eq(['rejected execute: "johndeo" looks like "johndoe"'])
    end
  end

  it "never raises out: a failure inside becomes one warn notice and the call runs" do
    klass = registry && Samagotchi::Hooks::BundleLoader.namespace_for("known-names").const_get(:KnownNames)
    allow(klass).to receive(:distance).and_raise(RuntimeError, "boom")
    expect(shell("ls /home/johndeo")).to be_allow
    expect(notices).to eq([{ text: "known-names failed: RuntimeError: boom", level: :warn, hook: "known_names.rb (bundle known-names)" }])
  end

  describe "the distance" do
    let(:klass) { registry && Samagotchi::Hooks::BundleLoader.namespace_for("known-names").const_get(:KnownNames) }

    { %w[jdoe jdeo] => 1, %w[johndoe johndeo] => 1, %w[samagotchi samagothci] => 1, %w[johnny johnni] => 1,
      %w[jonathandoe jonathndoe] => 1, %w[jonathandoe jonathendou] => 2, %w[abc abc] => 0, %w[abc xyz] => 3,
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
