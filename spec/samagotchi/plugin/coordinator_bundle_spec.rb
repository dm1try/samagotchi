# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "yaml"
require "samagotchi/memory_paths"
require "samagotchi/plugin/sessions"
require "samagotchi/memory_bundle/manifest"
require "samagotchi/memory_bundle/provenance"
require "samagotchi/config"

# The shipped coordinator bundle (lib/samagotchi/bundles/coordinator): the
# plugin on its own with a recording chi and ctx.
RSpec.describe "The coordinator plugin" do
  let(:dir) { File.expand_path("../../../lib/samagotchi/bundles/coordinator", __dir__) }
  let(:source) { File.join(dir, "plugin.rb") }
  let(:ctx) do
    Class.new do
      attr_reader :cards, :sent, :stopped, :children_asked
      attr_accessor :session_id, :children, :send_error, :stop_error, :cwd

      def initialize
        @cards = []
        @sent = []
        @stopped = []
        @children_asked = []
        @children = []
        @session_id = "aaaabbbb-1111-2222-3333-444455556666"
      end

      def card(title:, body: "", actions: [], level: :info, id: nil)
        @cards << { id: id, title: title, body: body, actions: actions, level: level }
        id
      end

      def sessions
        ctx = self
        Object.new.tap do |sessions|
          sessions.define_singleton_method(:children) do |all: false|
            ctx.children_asked << all
            ctx.children
          end
          sessions.define_singleton_method(:stop) do |id|
            raise Samagotchi::Plugin::Sessions::Error, ctx.stop_error if ctx.stop_error

            ctx.stopped << id
            "#{id}-full-id"
          end
          sessions.define_singleton_method(:send) do |id, text|
            raise Samagotchi::Plugin::Sessions::Error, ctx.send_error if ctx.send_error

            ctx.sent << [id, text]
            id
          end
        end
      end
    end.new
  end

  let(:inits) { [] }
  # The plugin as the loader builds it: its file in a module of its own,
  # register(chi) collecting the commands and init tasks.
  let(:commands) do
    mod = Module.new
    mod.module_eval(File.read(source), source)
    found = {}
    tasks = inits
    chi = Object.new
    chi.define_singleton_method(:command) { |name, _description, anytime: false, &block| found[name] = [block, anytime] }
    chi.define_singleton_method(:init) { |label, quiet: false, **, &block| tasks << [label, quiet, block] }
    mod::Plugin.new({}).register(chi)
    found
  end

  # The plain setup: no guardrails bundle, auto mode.
  let(:guardrails_installed) { false }
  let(:guardrails) { { "guardrails.enabled" => true, "guardrails.mode" => nil } }

  before do
    record = instance_double(Samagotchi::MemoryBundle::Provenance, installed?: guardrails_installed)
    allow(Samagotchi::MemoryBundle::Provenance).to receive(:new).with(name: "guardrails").and_return(record)
    allow(Samagotchi::Config).to receive(:get).and_call_original
    guardrails.each { |key, value| allow(Samagotchi::Config).to receive(:get).with(key).and_return(value) }
  end

  def run(name, args = "") = commands.fetch(name).first.call(args, ctx)

  def child(short, state, **fields)
    { id: "#{short}-full", short_id: short, title: "task of #{short}", state: state, waiting: nil, live: true,
      delegate: true, cwd: "/work/app-#{short}", branch: nil, last_reply: nil, last_reply_at: nil, reported: false,
      updated_at: "2026-10-06T10:00:00.000+02:00", archived: false }.merge(fields)
  end

  it "registers /children and /coordinate as anytime commands" do
    expect(commands.transform_values(&:last)).to eq("/children" => true, "/coordinate" => true)
  end

  describe "/children" do
    it "shows a card, one line per child, with Refresh and a Stop per running or waiting child; no text of its own" do
      ctx.children = [
        child("ab12cd34", "running", branch: "fix/flaky", title: "fix the flaky spec in spec/foo_spec.rb"),
        child("9a8b7c6d", "done", branch: "feat/x", last_reply: "All 12 specs pass; changed two files", reported: true),
        child("77aa66bb", "waiting", waiting: "approval"),
        child("55443322", "idle", last_reply: "half done", delegate: false),
        child("11223344", "failed", title: "")
      ]

      expect(run("/children")).to be_nil

      card = ctx.cards.last
      expect(card).to include(id: "children", title: "children of aaaabbbb (5)", level: :info)
      expect(card[:body]).to eq(<<~BODY.chomp)
        - `ab12cd34` · running · fix/flaky · "fix the flaky spec in spec/foo_spec.rb"
        - `9a8b7c6d` · done · feat/x · reported · "All 12 specs pass; changed two files"
        - `77aa66bb` · waiting (approval) · open it: chi --attach 77aa66bb
        - `55443322` · idle · fork · not reported yet · "half done"
        - `11223344` · failed
      BODY
      expect(card[:actions]).to eq([{ label: "Refresh", command: "/children" },
                                    { label: "Stop ab12cd34", command: "/children stop ab12cd34" },
                                    { label: "Stop 77aa66bb", command: "/children stop 77aa66bb" }])
      expect(ctx.children_asked).to eq([false])
    end

    it "says no children, and offers only Refresh" do
      run("/children")
      expect(ctx.cards.last).to include(title: "children of aaaabbbb", body: "no children",
                                        actions: [{ label: "Refresh", command: "/children" }])
    end

    it "with all lists archived children too, and Refresh keeps all" do
      ctx.children = [child("ab12cd34", "idle", archived: true)]
      run("/children", "all")

      expect(ctx.children_asked).to eq([true])
      expect(ctx.cards.last[:body]).to eq("- `ab12cd34` · idle · archived · \"task of ab12cd34\"")
      expect(ctx.cards.last[:actions].first).to eq(label: "Refresh", command: "/children all")
    end

    it "offers at most 5 Stops (a card takes 6 actions) and cuts a long reply" do
      ctx.children = (1..7).map { |n| child("0000000#{n}", "running") }
      ctx.children << child("deadbeef", "done", last_reply: "x" * 200)
      run("/children")

      expect(ctx.cards.last[:actions].size).to eq(6)
      expect(ctx.cards.last[:body].lines.last).to eq("- `deadbeef` · done · not reported yet · \"#{"x" * 79}…\"")
    end

    it "stop stops the child and shows the card again with a note" do
      ctx.children = [child("ab12cd34", "stopped")]

      expect(run("/children", "stop ab12cd34")).to be_nil

      expect(ctx.stopped).to eq(["ab12cd34"])
      expect(ctx.cards.last[:id]).to eq("children")
      expect(ctx.cards.last[:body]).to start_with("stopped ab12cd34\n\n- `ab12cd34` · stopped")
    end

    it "stop says why it couldn't, and shows no card" do
      ctx.stop_error = "session 12345678 is not a child of this session"

      expect(run("/children", "stop 12345678")).to eq("/children stop: session 12345678 is not a child of this session")
      expect(ctx.cards).to be_empty
    end

    it "gives the usage for anything else" do
      expect(run("/children", "stop")).to eq("usage: /children [all] | /children stop <id>")
      expect(run("/children", "everything")).to eq("usage: /children [all] | /children stop <id>")
      expect(run("/children", "all extra")).to eq("usage: /children [all] | /children stop <id>")
    end
  end

  describe "/coordinate" do
    it "asks the model in this session to follow the skill for the goal" do
      expect(run("/coordinate", "add two small features")).to eq("asked chi to coordinate it; a running turn gets it at its next step")
      expect(ctx.sent).to eq([[ctx.session_id, "Read the skill_coordinator memory and follow it for this goal:\n\nadd two small features"]])
    end

    it "shows the request to send yourself where the session takes no messages (a REPL)" do
      ctx.send_error = "session aaaabbbb is open in a chi REPL, which takes no messages from others"

      expect(run("/coordinate", "do x")).to eq(
        "/coordinate: session aaaabbbb is open in a chi REPL, which takes no messages from others. Send this yourself:\n\n" \
        "Read the skill_coordinator memory and follow it for this goal:\n\ndo x"
      )
    end

    it "warns about nothing and checks nothing at load, without the guardrails bundle in auto mode (chi asks a child itself)" do
      expect(run("/coordinate", "do x")).to eq("asked chi to coordinate it; a running turn gets it at its next step")
      expect(inits).to be_empty
    end

    it "needs a goal" do
      expect(run("/coordinate")).to start_with("usage: /coordinate <goal>")
      expect(ctx.sent).to be_empty
    end
  end

  describe "/coordinate resume" do
    let(:memories) { Dir.mktmpdir("coord-resume") }

    before do
      ctx.cwd = "/work/app"
      allow(Samagotchi::MemoryPaths).to receive(:scope_dir).with("project", cwd: "/work/app").and_return(memories)
    end

    after { FileUtils.rm_rf(memories) }

    def handoff(name, description, file: true)
      File.write(File.join(memories, "#{name}.md"), "# #{name}\n") if file
      line = "- **#{name}** · project · 2026-10-07 · 12#{" — #{description}" if description}\n"
      File.write(File.join(memories, "index.md"), line, mode: "a")
    end

    it "asks the model to resume the one open handoff, skipping DONE ones, other memories and lines without a file" do
      handoff("handoff_calc-v2", "OPEN coordinator handoff calc-v2 (session aaaabbbb): 1/2 merged")
      handoff("handoff_old", "DONE: all merged")
      handoff("handoff_gone", "OPEN coordinator handoff gone", file: false)
      handoff("notes", "OPEN notes")

      expect(run("/coordinate", "resume")).to eq("asked chi to resume handoff_calc-v2; a running turn gets it at its next step")
      expect(ctx.sent).to eq([[ctx.session_id, "Read the skill_coordinator memory and resume the coordinator handoff " \
                                               "handoff_calc-v2: follow the skill's Resume (step 0) before anything else."]])
    end

    it "shows a card with one Resume per open handoff when there are several, and resumes the one picked" do
      handoff("handoff_a", "OPEN coordinator handoff a: 0/2 merged")
      handoff("handoff_b", nil)

      expect(run("/coordinate", "resume")).to be_nil
      expect(ctx.cards.last).to include(id: "coordinate-resume", title: "open handoffs (2)",
                                        body: "- handoff_a — OPEN coordinator handoff a: 0/2 merged\n- handoff_b")
      expect(ctx.cards.last[:actions]).to eq([{ label: "Resume a", command: "/coordinate resume handoff_a" },
                                              { label: "Resume b", command: "/coordinate resume handoff_b" }])
      expect(ctx.sent).to be_empty

      expect(run("/coordinate", "resume b")).to eq("asked chi to resume handoff_b; a running turn gets it at its next step")
    end

    it "says when none is open, or the one named isn't" do
      expect(run("/coordinate", "resume")).to eq("no open coordinator handoff (handoff_* memory) in this project")
      handoff("handoff_done", "DONE: merged")
      expect(run("/coordinate", "resume")).to eq("no open coordinator handoff (handoff_* memory) in this project")
      handoff("handoff_a", "OPEN a")
      expect(run("/coordinate", "resume handoff_done"))
        .to eq("/coordinate resume: no open handoff handoff_done in this project (open: handoff_a)")
      expect(ctx.sent).to be_empty
    end

    it "takes \"resume\" with more words as a goal" do
      run("/coordinate", "resume the old work on payments")
      expect(ctx.sent.last.last).to eq("Read the skill_coordinator memory and follow it for this goal:\n\nresume the old work on payments")
    end
  end

  describe "the bundle" do
    let(:manifest) { Samagotchi::MemoryBundle::Manifest.read(dir: dir) }

    it "ships the skill with its index description, and its plugin" do
      expect(manifest.files.keys).to eq(["skill_coordinator.md"])
      expect(manifest.file_descriptions["skill_coordinator.md"]).to start_with("Coordinate parallel work")
      expect(manifest.plugin[:file]).to eq("plugin.rb")
    end

    it "keeps the skill's merge step: ask, check main first, ff-only, never push" do
      skill = File.read(File.join(dir, "skill_coordinator.md"))
      expect(skill).to start_with("# Skill: coordinator\n")
      expect(skill).to include("ask_user_question", "git merge-base --is-ancestor <branch> <default>", "git branch --show-current", "git merge --ff-only",
                               "Never push unless asked", "Children\n   never merge", "never `-D`",
                               "Work only in <absolute worktree path>", "Don't call delegate_result")
    end

    it "keeps the handoff memory: status in a descriptive description, resume reads the body, saves first, removes when done" do
      skill = File.read(File.join(dir, "skill_coordinator.md"))
      expect(skill).to include("handoff_<epic-slug>", "never what to do", "description only (no content)",
                               "memory_read the handoff", "list_sessions", "not listed is not proof a child is gone",
                               "save the answer in the handoff before you act on it",
                               "git merge-base --is-ancestor <default> <branch>", "status --short --ignored", "never\n   `rm -rf`",
                               "\"DONE: …\"", "remove: true", "don't write or edit any handoff_* memory")
    end
  end
end
