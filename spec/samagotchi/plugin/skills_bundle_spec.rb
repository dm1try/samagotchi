# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "samagotchi/memory_bundle/installer"

# The shipped skills bundle (lib/samagotchi/bundles/skills): the plugin on its
# own with a recording chi and ctx, then installed as a user would and loaded
# by an Engine.
RSpec.describe "The skills plugin" do
  let(:source) { File.expand_path("../../../lib/samagotchi/bundles/skills/plugin.rb", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("skills-") }
  let(:system_dir) { File.join(tmpdir, "mem") }
  let(:project_dir) { File.join(tmpdir, "proj") }
  let(:ctx) do
    Class.new do
      attr_reader :notices, :sent, :data_dir
      attr_accessor :session_id, :send_error

      def initialize(data_dir)
        @notices = []
        @sent = []
        @data_dir = data_dir
        @session_id = "sess-1"
      end

      def notify(text, level: :info) = @notices << [text, level]

      def sessions
        ctx = self
        Object.new.tap do |sessions|
          sessions.define_singleton_method(:send) do |id, text|
            raise Samagotchi::Plugin::Sessions::Error, ctx.send_error if ctx.send_error

            ctx.sent << [id, text]
            id
          end
        end
      end
    end.new(File.join(tmpdir, "state"))
  end

  before do
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = project_dir
    FileUtils.mkdir_p([system_dir, project_dir])
  end

  after do
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    FileUtils.rm_rf(tmpdir)
  end

  # The plugin as the loader builds it: its file in a module of its own,
  # register(chi) collecting the chi.on blocks and the command.
  def plugin(settings = {})
    mod = Module.new
    mod.module_eval(File.read(source), source)
    hooks = Hash.new { |h, k| h[k] = [] }
    commands = {}
    chi = Object.new
    chi.define_singleton_method(:on) { |event, priority: 100, &block| hooks[event] << block }
    chi.define_singleton_method(:command) { |name, _description, anytime: false, &block| commands[name] = [block, anytime] }
    mod::Plugin.new(settings).register(chi)
    { hooks: hooks, commands: commands }
  end

  def skill(p, args = "") = p[:commands]["/skill"].first.call(args, ctx)

  it "is one anytime command, /skill, with a usage line" do
    p = plugin
    expect(p[:commands].keys).to eq(["/skill"])
    expect(p[:commands]["/skill"].last).to be(true)
    expect(skill(p)).to start_with("usage: /skill save")
    expect(skill(p, "frobnicate")).to start_with("usage: /skill save")
  end

  describe "/skill save" do
    it "sends this session a request holding the skill's shape, the name and the project scope" do
      reply = skill(plugin, "save Release")

      expect(reply).to eq("asked chi to save skill release (project scope); a running turn gets it at its next step")
      id, text = ctx.sent.first
      expect(id).to eq("sess-1")
      expect(text).to start_with("Save what we just did as skill `skill_release` with memory_write, scope project.")
      expect(text).to include("finish it first", "no frontmatter", "# Skill: release", "## Steps", "## Gotchas",
                              "## Changelog", "- #{Date.today.iso8601} created", "description:", "show the skill briefly")
      expect(text).not_to include("exists already")
    end

    it "lets the model pick the name, takes --system, and says so when the skill exists" do
      skill(plugin, "save --system")
      expect(ctx.sent.last.last).to start_with("Save what we just did as a skill named `skill_<name>`")
      expect(ctx.sent.last.last).to include("scope system.")

      File.write(File.join(project_dir, "skill_deploy.md"), "# Skill: deploy\n")
      expect(skill(plugin, "save skill_deploy")).to include("skill deploy (project scope)")
      expect(ctx.sent.last.last).to include("It exists already: read it, keep what still holds")
    end

    it "refuses a bad name or extra words, sending nothing" do
      expect(skill(plugin, "save ../x")).to eq("/skill save: a name is letters, digits, _ and - (got ../x)")
      expect(skill(plugin, "save a b")).to start_with("usage:")
      expect(skill(plugin, "save --project")).to start_with("usage:")
      expect(ctx.sent).to be_empty
    end

    it "shows the request for the user to send when the session takes no messages (a REPL)" do
      ctx.send_error = "session sess-1 is open in a chi REPL, which takes no messages from others"
      reply = skill(plugin, "save release")
      expect(reply).to start_with("/skill save: session sess-1 is open in a chi REPL, which takes no messages from others. " \
                                  "Send this yourself:\n\nSave what we just did as skill `skill_release`")
    end
  end
end

RSpec.describe "The skills bundle, installed" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/skills", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("skills-") }
  let(:system_dir) { File.join(tmpdir, "mem") }
  let(:state_dir) { File.join(tmpdir, "sessions") }
  let(:client) { instance_double(Samagotchi::Client) }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME", "SAMAGOTCHI_THINKING_LEVEL")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME SAMAGOTCHI_THINKING_LEVEL].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  before do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = File.join(system_dir, ".bundles")
    Samagotchi::MemoryBundle::Installer.system_dir_override = system_dir
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = File.join(tmpdir, "proj")
    FileUtils.mkdir_p(system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    @installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "skills", scope: "system", strict: true)
    @installer.run
  end

  after do
    Samagotchi::MemoryBundle::Provenance.bundles_dir_override = nil
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
    FileUtils.rm_rf(tmpdir)
  end

  let(:engine) { Samagotchi::Engine.new(mode: :assist, client: client).tap { |e| e.session_state_dir = state_dir } }

  it "installs cleanly, with no memory, as an anytime command" do
    expect(@installer.warnings).to be_empty
    entry = engine.command_registry.lookup("/skill list")
    expect([entry.name, entry.anytime, entry.source]).to eq(["/skill", true, "skills"])
    index = File.join(system_dir, "index.md")
    expect(File.exist?(index) ? File.read(index) : "").not_to include("skills")
  end
end
