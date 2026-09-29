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
  # MemoryRead takes the project override as the project's own dir,
  # IndexUpdater as the base the project key goes under: this one path is
  # both.
  let(:project_dir) { File.join(tmpdir, "proj", Samagotchi::MemoryPaths.project_key) }
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
      def log = Logger.new(nil)

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
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = system_dir
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = File.dirname(project_dir)
    FileUtils.mkdir_p([system_dir, project_dir])
  end

  after do
    Samagotchi::MemoryBundle::Installer.system_dir_override = nil
    Samagotchi::MemoryBundle::Installer.project_dir_base_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.system_dir_override = nil
    Samagotchi::MemoryBundle::IndexUpdater.project_dir_base_override = nil
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

  def write_skill(name, content, scope: "project", description: nil)
    Samagotchi::Tools::MemoryWrite.call(content, path: "skill_#{name}", scope: scope, description: description)
  end

  describe "/skill list and show" do
    it "lists both scopes' skills with their index date and description, and shows one (project first)" do
      expect(skill(plugin, "list")).to eq("no skills yet: after a task we did together, /skill save [name]")

      write_skill("release", "# Skill: release\n\n## Steps\n1. tag\n", description: "Release a new version: tag, push")
      write_skill("deploy", "# Skill: deploy (system)\n", scope: "system")
      write_skill("deploy", "# Skill: deploy (project)\n")
      Samagotchi::Tools::MemoryWrite.call("not a skill", path: "notes", scope: "project")
      File.write(File.join(project_dir, "skill_release.qwen36.md"), "an overlay")
      today = Date.today.iso8601

      expect(skill(plugin, "list")).to eq(<<~TEXT.strip)
        skills:
          deploy · project · #{today}
          release · project · #{today} — Release a new version: tag, push
          deploy · system · #{today}
      TEXT
      expect(skill(plugin, "show release")).to eq("skill release · project\n\n# Skill: release\n\n## Steps\n1. tag")
      expect(skill(plugin, "show skill_deploy")).to eq("skill deploy · project\n\n# Skill: deploy (project)")
      expect(skill(plugin, "show nope")).to eq("no skill nope (/skill list shows them)")
      expect(skill(plugin, "show")).to start_with("usage:")
    end
  end

  # A write of +tool+ to +path+ as the ToolRunner runs it: the before hook,
  # the write (unless denied), the after hook.
  def write_call(p, tool, path, content, denied: false)
    fire(p, :before_tool_call, call: { name: tool }, targets: { paths: [path] })
    File.write(path, content) unless denied
    fire(p, :after_tool_call, tool: tool, output: denied ? "[#{tool}] Error: denied" : "ok")
  end

  def fire(p, type, **event)
    p[:hooks][type].each { |block| block.call({ type: type, **event }, ctx) }
  end

  def history(scope, name)
    key = scope == "system" ? "system" : "project-#{File.basename(project_dir)}"
    Dir.glob(File.join(ctx.data_dir, "history", key, name, "*.md")).sort
  end

  describe "history and the change notice" do
    let(:path) { File.join(project_dir, "skill_release.md") }
    let(:v1) { "# Skill: release\n\n## Steps\n1. Run `scripts/check.sh`; stop if it fails.\n2. Tag it.\n" }
    let(:v2) { "# Skill: release\n\n## Steps\n1. Run `scripts/verify.sh`; stop if it fails.\n2. Tag it.\n3. Push.\n" }

    it "says a new skill was saved, keeps the old version before an update and says what changed" do
      p = plugin
      write_call(p, "memory_write", path, v1)
      expect(ctx.notices.last).to eq(["skill release saved (project, 5 lines)", :info])
      expect(history("project", "release")).to be_empty

      write_call(p, "edit", path, v2)
      expect(ctx.notices.last.first)
        .to eq("skill release updated (+2 −1): 1. Run `scripts/verify.sh`; stop if it fails. · /skill diff release")
      expect(history("project", "release").map { |f| File.read(f) }).to eq([v1])
    end

    it "cuts a long changed line, and covers the system scope and the write tool" do
      p = plugin
      sys = File.join(system_dir, "skill_deploy.md")
      File.write(sys, "a\n")
      write_call(p, "write", sys, "a\n#{"x" * 100}\n")
      expect(ctx.notices.last.first).to eq("skill deploy updated (+1 −0): #{"x" * 59}… · /skill diff deploy")
      expect(history("system", "deploy").size).to eq(1)
    end

    it "shows nothing for a denied or unchanged write, and keeps one copy of the same content" do
      p = plugin
      File.write(path, v1)
      write_call(p, "memory_write", path, v1, denied: true)
      write_call(p, "memory_write", path, v1)
      expect(ctx.notices).to be_empty
      expect(history("project", "release").size).to eq(1)
    end

    it "keeps history_keep versions, the newest" do
      p = plugin("history_keep" => 2)
      File.write(path, "0\n")
      (1..4).each { |n| write_call(p, "memory_write", path, "#{n}\n") }
      expect(history("project", "release").map { |f| File.read(f) }).to eq(["2\n", "3\n"])
    end

    it "leaves other files alone: other memories, overlays, files elsewhere, a mismatched after" do
      p = plugin
      [File.join(project_dir, "notes.md"), File.join(project_dir, "skill_release.qwen36.md"),
       File.join(tmpdir, "skill_release.md")].each do |other|
        File.write(other, "old")
        write_call(p, "write", other, "new")
      end
      File.write(path, v1)
      fire(p, :before_tool_call, call: { name: "edit" }, targets: { paths: [path] })
      File.write(path, v2)
      fire(p, :after_tool_call, tool: "execute", output: "exit: 0")
      fire(p, :after_tool_call, tool: "edit", output: "ok")
      fire(p, :after_tool_call, tool: "memory_read", output: "x")
      expect(ctx.notices).to be_empty
    end
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

  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir) }
  let(:events) { [] }

  before do
    engine.session = session
    engine.subscribe(observer: ->(e) { events << e })
  end

  def tool_call(name, **args)
    body = args.map { |key, value| %(#{key}: <|"|>#{value}<|"|>) }.join(", ")
    %(<|tool_call>call:#{name}{#{body}}<tool_call|>)
  end

  def notices = events.select { |e| e[:type] == :hook_notice }.map { |e| e[:text] }

  it "keeps the old version and shows the change when the model rewrites a skill in a real turn" do
    replies = [tool_call("memory_write", name: "skill_release", scope: "system", content: "# Skill: release\n1. check\n",
                         description: "Release this repo"),
               tool_call("memory_write", name: "skill_release", scope: "system", content: "# Skill: release\n1. verify\n"),
               "done"]
    allow(client).to receive(:complete) { replies.shift || "done" }

    engine.run_turn(session, "save it, then fix it")

    expect(File.read(File.join(system_dir, "skill_release.md"))).to eq("# Skill: release\n1. verify\n")
    expect(notices).to eq(["skill release saved (system, 2 lines)",
                           "skill release updated (+1 −1): 1. verify · /skill diff release"])
    kept = Dir.glob(File.join(tmpdir, "state", "samagotchi", "plugins", "skills", "history", "system", "release", "*.md"))
    expect(kept.map { |f| File.read(f) }).to eq(["# Skill: release\n1. check\n"])
  end

  it "installs cleanly, with no memory, as an anytime command" do
    expect(@installer.warnings).to be_empty
    entry = engine.command_registry.lookup("/skill list")
    expect([entry.name, entry.anytime, entry.source]).to eq(["/skill", true, "skills"])
    index = File.join(system_dir, "index.md")
    expect(File.exist?(index) ? File.read(index) : "").not_to include("skills")
  end
end
