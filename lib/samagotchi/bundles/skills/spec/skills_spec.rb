# frozen_string_literal: true

require "date"
require "samagotchi/testing/rspec"

# The skills plugin on its own, through the bundle test kit (docs/plugins.md,
# "Testing a bundle"); spec/samagotchi/plugin/skills_bundle_spec.rb installs it
# and runs real turns.
RSpec.describe "The skills plugin", :bundle do
  let(:tmpdir) { Dir.mktmpdir("skills-") }
  let(:system_dir) { sandbox.memory_dir }
  # The project scope of the checkout the process runs in, as the memory
  # tools find it.
  let(:project_dir) { sandbox.memory_dir("project") }
  let(:loaded) { [] }

  after do
    FileUtils.rm_rf(tmpdir)
  end

  # The plugin as chi loads it, for session sess-1. Each call is a new load
  # in the same sandbox (one data dir); what they all did is read together.
  def plugin(settings = {})
    shipped_bundle("skills", settings: settings, host: { session_id: "sess-1" }).tap do |bundle|
      bundle.sessions.on(:send) do |id, _text, delivery:|
        raise Samagotchi::Plugin::Sessions::Error, @send_error if @send_error

        id
      end
      loaded << bundle
    end
  end

  def skill(p, args = "") = p.command("/skill #{args}")

  # The notices of every plugin loaded, as [text, level].
  def notices = loaded.flat_map(&:notices).map { |notice| [notice.text, notice.level] }

  # The texts every plugin steered.
  def steered = loaded.flat_map(&:steers).map(&:text)

  # What ctx.sessions.send took: [id, text] (nothing while sends fail).
  def sent = @send_error ? [] : loaded.flat_map { |bundle| bundle.sessions.calls_to(:send).map(&:args) }

  it "is one anytime command, /skill, with a usage line" do
    p = plugin
    expect(p.bundle_commands.map { |entry| [entry.name, entry.anytime] }).to eq([["/skill", true]])
    expect(skill(p)).to start_with("usage: /skill save")
    expect(skill(p, "frobnicate")).to start_with("usage: /skill save")
  end

  def write_skill(name, content, scope: "project", description: nil)
    sandbox.write_memory("skill_#{name}", content, scope: scope, description: description)
  end

  describe "/skill list and show" do
    it "lists both scopes' skills with their index date and description, and shows one (project first)" do
      expect(skill(plugin, "list")).to eq("no skills yet: after a task we did together, /skill save [name]")

      write_skill("release", "# Skill: release\n\n## Steps\n1. tag\n", description: "Release a new version: tag, push")
      write_skill("deploy", "# Skill: deploy (system)\n", scope: "system")
      write_skill("deploy", "# Skill: deploy (project)\n")
      sandbox.write_memory("notes", "not a skill", scope: "project")
      File.write(File.join(project_dir, "skill_release.qwen36.md"), "an overlay")
      today = Date.today.iso8601

      expect(skill(plugin, "list")).to eq(<<~TEXT.strip)
        skills:
          deploy · project · #{today}
          release · project · #{today} — Release a new version: tag, push
          deploy · system · #{today}
      TEXT
      # a bundle's skill: its line carries "· from <bundle>"
      sandbox.write_memory("skill_release", File.read(File.join(project_dir, "skill_release.md")), scope: "project",
                                                                                                   source: "team-skills")
      expect(skill(plugin, "list")).to include("release · project · #{today} — Release a new version: tag, push")
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

  def fire(p, type, **event) = p.fire(type, **event)

  def history(scope, name)
    key = scope == "system" ? "system" : "project-#{File.basename(project_dir)}"
    Dir.glob(File.join(loaded.first.ctx.data_dir, "history", key, name, "*.md")).sort
  end

  describe "history and the change notice" do
    let(:path) { File.join(project_dir, "skill_release.md") }
    let(:v1) { "# Skill: release\n\n## Steps\n1. Run `scripts/check.sh`; stop if it fails.\n2. Tag it.\n" }
    let(:v2) { "# Skill: release\n\n## Steps\n1. Run `scripts/verify.sh`; stop if it fails.\n2. Tag it.\n3. Push.\n" }

    it "says a new skill was saved, keeps the old version before an update and says what changed" do
      p = plugin
      write_call(p, "memory_write", path, v1)
      expect(notices.last).to eq(["skill release saved (project, 5 lines)", :info])
      expect(history("project", "release")).to be_empty

      write_call(p, "edit", path, v2)
      expect(notices.last.first)
        .to eq("skill release updated (+2 −1): 1. Run `scripts/verify.sh`; stop if it fails. · /skill diff release")
      expect(history("project", "release").map { |f| File.read(f) }).to eq([v1])
    end

    it "cuts a long changed line, and covers the system scope and the write tool" do
      p = plugin
      sys = File.join(system_dir, "skill_deploy.md")
      File.write(sys, "a\n")
      write_call(p, "write", sys, "a\n#{"x" * 100}\n")
      expect(notices.last.first).to eq("skill deploy updated (+1 −0): #{"x" * 59}… · /skill diff deploy")
      expect(history("system", "deploy").size).to eq(1)
    end

    it "shows nothing for a denied or unchanged write, and keeps one copy of the same content" do
      p = plugin
      File.write(path, v1)
      write_call(p, "memory_write", path, v1, denied: true)
      write_call(p, "memory_write", path, v1)
      expect(notices).to be_empty
      expect(history("project", "release").size).to eq(1)
    end

    it "keeps history_keep versions, the newest" do
      p = plugin("history_keep" => 2)
      File.write(path, "0\n")
      (1..4).each { |n| write_call(p, "memory_write", path, "#{n}\n") }
      expect(history("project", "release").map { |f| File.read(f) }).to eq(%W[2\n 3\n])
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
      expect(notices).to be_empty
    end
  end

  describe "/skill diff" do
    let(:path) { File.join(project_dir, "skill_release.md") }

    it "diffs the skill now against the version before the last change, or the N-th newest" do
      p = plugin
      expect(skill(p, "diff release")).to eq("no skill release (/skill list shows them)")
      write_call(p, "memory_write", path, "# Skill: release\n1. check\n2. tag\n")
      expect(skill(p, "diff release")).to eq("skill release has no older version yet")
      write_call(p, "memory_write", path, "# Skill: release\n1. verify\n2. tag\n")
      write_call(p, "memory_write", path, "# Skill: release\n1. verify\n2. tag\n3. push\n")

      expect(skill(p, "diff release")).to match(<<~TEXT.strip)
        --- skill_release \\(\\d{4}-\\d\\d-\\d\\d \\d\\d:\\d\\d UTC\\)
        \\+\\+\\+ skill_release \\(now\\)
        @@ -1,3 \\+1,4 @@
         # Skill: release
         1. verify
         2. tag
        \\+3. push
      TEXT
      expect(skill(p, "diff skill_release 2").lines.drop(2).join).to eq(<<~TEXT.strip)
        @@ -1,3 +1,4 @@
         # Skill: release
        -1. check
        +1. verify
         2. tag
        +3. push
      TEXT
      expect(skill(p, "diff release 3")).to eq("skill release has 2 older versions (/skill diff release 1..2)")
      expect(skill(p, "diff release 0")).to start_with("usage:")
      expect(skill(p, "diff")).to start_with("usage:")
    end

    it "prints hunks as diff -u does" do
      p = plugin
      rng = Random.new(7)
      base = (1..40).map { |n| "line #{n}" }
      8.times do
        old = base.dup
        new = base.each_with_object([]) do |line, out|
          case rng.rand(10)
          when 0 then nil
          when 1 then out.push(line, "added #{rng.rand(1000)}")
          when 2 then out << "changed #{rng.rand(1000)}"
          else out << line
          end
        end
        File.write(path, old.join("\n") + "\n")
        write_call(p, "write", path, new.join("\n") + "\n")
        Dir.mktmpdir do |dir|
          File.write(File.join(dir, "a"), old.join("\n") + "\n")
          File.write(File.join(dir, "b"), new.join("\n") + "\n")
          expected = `diff -U3 #{dir}/a #{dir}/b`.lines.drop(2).join.chomp
          expect(skill(p, "diff release").lines.drop(2).join).to eq(expected)
        end
      end
    end
  end

  describe "the nudge" do
    let(:path) { File.join(project_dir, "skill_release.md") }

    def read_skill(p, names = "skill_release")
      fire(p, :before_tool_call, call: { name: "memory_read", content: names }, targets: { paths: [] })
      fire(p, :after_tool_call, tool: "memory_read", output: "# Skill: release")
    end

    # +status+ as core sends it (ToolRunner: the call's activity status).
    def run(p, tool, output, status = "ok")
      fire(p, :before_tool_call, call: { name: tool }, targets: { paths: [] })
      fire(p, :after_tool_call, tool: tool, output: output, status: status)
    end

    it "steers once at the first failing step after a skill was read, and notes it at the turn's end" do
      p = plugin
      fire(p, :before_turn, prompt: "release 1.3.0")
      run(p, "execute", "[execute]\nstderr:\nno such file\nexit: 1", "error") # before the read: not the skill's
      read_skill(p, "notes, skill_release")
      run(p, "execute", "[execute]\nstdout:\nok\nexit: 0")
      run(p, "execute", "[execute]\nstderr:\nbash: scripts/check.sh: No such file or directory\nexit: 127", "error")
      run(p, "read", "[read] Error: file not found", "error")

      expect(steered).to eq(["A step of skill release failed. Find out why before skipping it; if the skill is out of " \
                             "date, fix it now: edit the step that changed in its file (or memory_write the whole " \
                             "skill) and add a Changelog line."])
      fire(p, :after_turn, status: "completed")
      expect(notices).to eq([["skill release was followed, a step failed, the skill wasn't updated", :info]])
    end

    it "is quiet when the skill was updated, or nothing failed, and starts over each turn" do
      p = plugin
      fire(p, :before_turn, prompt: "go")
      fire(p, :before_tool_call, call: { name: "read" }, targets: { paths: [path] })
      fire(p, :after_tool_call, tool: "read", output: "x", status: "ok")
      run(p, "execute", "[execute]\nError: command timed out after 60s", "error")
      File.write(path, "old\n")
      write_call(p, "memory_write", path, "new\n")
      fire(p, :after_turn, status: "completed")
      expect(steered.size).to eq(1)
      expect(notices.map(&:first)).to eq(["skill release updated (+1 −1): new · /skill diff release"])

      fire(p, :before_turn, prompt: "again")
      run(p, "execute", "[execute]\nexit: 2 (no output)", "error")
      read_skill(p)
      run(p, "execute", "[execute]\nexit: 0 (no output)")
      fire(p, :after_turn, status: "completed")
      expect(steered.size).to eq(1)
      expect(notices.size).to eq(1)
    end

    it "goes by the call's status, not its output: an Error: line in an ok call is no failure, a stopped wait neither" do
      p = plugin
      read_skill(p)
      run(p, "execute", "[execute]\nstdout:\nError: bad config\nexit: 0")
      run(p, "task_wait", "[task_wait]\nwait_result: canceled", "stopped")
      expect(steered).to be_empty
      run(p, "execute", "[execute]\nstdout:\nfine\nexit: 1 (output cut)", "error")
      expect(steered.size).to eq(1)
    end

    it "is no failed step for a call a guardrail or the user denied (blocked); a real failure after it still steers once" do
      p = plugin
      fire(p, :before_turn, prompt: "release")
      read_skill(p)
      run(p, "execute", "[execute] Error: denied by guardrail (rule no-rm): rm -rf. Do not retry it", "blocked")
      run(p, "write", "[write] Error: The user declined this call: \"not now\".", "blocked")
      expect(steered).to be_empty

      run(p, "execute", "[execute]\nstderr:\nboom\nexit: 1", "error")
      run(p, "read", "[read] Error: file not found", "error")
      expect(steered.size).to eq(1)
      fire(p, :after_turn, status: "completed")
      expect(notices.map(&:first)).to eq(["skill release was followed, a step failed, the skill wasn't updated"])
    end

    describe "a skill changed by another tool (an execute's sed)" do
      let(:v1) { "# Skill: release\n\n## Steps\n1. Run `scripts/check.sh`.\n" }
      let(:v2) { "# Skill: release\n\n## Steps\n1. Run `scripts/verify.sh`.\n" }

      it "counts as updated: a notice, the old text kept, no steer at a later failure, no turn-end line" do
        File.write(path, v1)
        p = plugin
        fire(p, :before_turn, prompt: "release")
        read_skill(p)
        File.write(path, v2) # the execute's own write
        run(p, "execute", "[execute]\nexit: 0 (no output)")
        expect(notices.map(&:first)).to eq(["skill release updated (+1 −1): 1. Run `scripts/verify.sh`. · " \
                                                "/skill diff release"])
        expect(history("project", "release").map { |f| File.read(f) }).to eq([v1])

        run(p, "execute", "[execute]\nexit: 1 (no output)")
        fire(p, :after_turn, status: "completed")
        expect(steered).to be_empty
        expect(notices.size).to eq(1)
        expect(skill(p, "diff release")).to include("-1. Run `scripts/check.sh`.", "+1. Run `scripts/verify.sh`.")
      end

      it "is seen at the turn's end too, after the last tool call, with nudge: false" do
        File.write(path, v1)
        p = plugin("nudge" => false)
        fire(p, :before_turn, prompt: "release")
        read_skill(p)
        run(p, "execute", "[execute]\nexit: 0 (no output)")
        File.write(path, v2)
        fire(p, :after_turn, status: "completed")
        expect(notices.map(&:first)).to eq(["skill release updated (+1 −1): 1. Run `scripts/verify.sh`. · " \
                                                "/skill diff release"])
      end

      it "diffs against the content after the last write, so an edit then a sed show one line each" do
        File.write(path, v1)
        p = plugin
        read_skill(p)
        write_call(p, "edit", path, v2)
        File.write(path, "#{v2}2. Tag it.\n")
        run(p, "execute", "[execute]\nexit: 0 (no output)")
        expect(notices.map(&:first)).to eq(
          ["skill release updated (+1 −1): 1. Run `scripts/verify.sh`. · /skill diff release",
           "skill release updated (+1 −0): 2. Tag it. · /skill diff release"]
        )
        expect(history("project", "release").map { |f| File.read(f) }).to eq([v1, v2])
      end

      it "watches the scope a memory_read named, and keeps no version for a plain read" do
        system_path = File.join(system_dir, "skill_release.md")
        File.write(path, v1)
        File.write(system_path, v1)
        p = plugin
        fire(p, :before_tool_call, call: { name: "memory_read", content: "skill_release", scope: "system" },
                                   targets: { paths: [] })
        fire(p, :after_tool_call, tool: "memory_read", output: v1)
        File.write(path, v2) # the project one: not what was read
        run(p, "execute", "[execute]\nexit: 0 (no output)")
        expect(notices).to be_empty
        File.write(system_path, v2)
        run(p, "execute", "[execute]\nexit: 0 (no output)")
        expect(notices.size).to eq(1)
        expect(history("system", "release").size).to eq(1)
        expect(history("project", "release")).to be_empty
      end

      it "sees a skill read before it existed and then created by execute (memory_read's comma list)" do
        p = plugin
        fire(p, :before_turn, prompt: "release")
        read_skill(p, "notes, skill_release")
        File.write(path, v1)
        run(p, "execute", "[execute]\nexit: 1 (no output)")
        fire(p, :after_turn, status: "completed")
        expect(steered).to be_empty
        expect(notices.map(&:first)).to eq(["skill release saved (project, 4 lines)"])
        expect(history("project", "release")).to be_empty
      end

      it "leaves /skill diff alone on a plain read after a memory_write" do
        File.write(path, v1)
        p = plugin
        write_call(p, "memory_write", path, v2)
        fire(p, :before_turn, prompt: "again")
        read_skill(p)
        run(p, "execute", "[execute]\nexit: 0 (no output)")
        fire(p, :after_turn, status: "completed")
        expect(history("project", "release").map { |f| File.read(f) }).to eq([v1])
        expect(skill(p, "diff release")).to include("+1. Run `scripts/verify.sh`.")
      end
    end

    it "is off with nudge: false" do
      p = plugin("nudge" => false)
      read_skill(p)
      run(p, "execute", "[execute]\nexit: 1 (no output)")
      fire(p, :after_turn, status: "completed")
      expect(steered).to be_empty
      expect(notices).to be_empty
    end
  end

  describe "/skill save" do
    it "sends this session a request holding the skill's shape, the name and the project scope" do
      reply = skill(plugin, "save Release")

      expect(reply).to eq("asked chi to save skill release (project scope); a running turn gets it at its next step")
      id, text = sent.first
      expect(id).to eq("sess-1")
      expect(text).to start_with("Save what we just did as skill `skill_release` with memory_write, scope project.")
      expect(text).to include("finish it first", "no frontmatter", "# Skill: release", "## Steps", "## Gotchas",
                              "## Changelog", "- #{Date.today.iso8601} created", "description:", "show the skill briefly")
      expect(text).not_to include("exists already")
    end

    it "lets the model pick the name, takes --system, and says so when the skill exists" do
      skill(plugin, "save --system")
      expect(sent.last.last).to start_with("Save what we just did as a skill named `skill_<name>`")
      expect(sent.last.last).to include("scope system.")

      File.write(File.join(project_dir, "skill_deploy.md"), "# Skill: deploy\n")
      expect(skill(plugin, "save skill_deploy")).to include("skill deploy (project scope)")
      expect(sent.last.last).to include("It exists already: read it, keep what still holds")
    end

    it "refuses a bad name or extra words, sending nothing" do
      expect(skill(plugin, "save ../x")).to eq("/skill save: a name is letters, digits, _ and - (got ../x)")
      expect(skill(plugin, "save a b")).to start_with("usage:")
      expect(skill(plugin, "save --project")).to start_with("usage:")
      expect(sent).to be_empty
    end

    it "shows the request for the user to send when the session takes no messages (a REPL)" do
      @send_error = "session sess-1 is open in a chi REPL, which takes no messages from others"
      reply = skill(plugin, "save release")
      expect(reply).to start_with("/skill save: session sess-1 is open in a chi REPL, which takes no messages from others. " \
                                  "Send this yourself:\n\nSave what we just did as skill `skill_release`")
    end
  end
end
