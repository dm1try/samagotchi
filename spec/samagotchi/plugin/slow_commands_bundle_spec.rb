# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "samagotchi/guardrails"
require "samagotchi/engine"
require "samagotchi/tool_runner"
require "samagotchi/memory_bundle/installer"
require "samagotchi/testing/rspec"

# The slow-commands bundle (lib/samagotchi/bundles/slow-commands): the
# plugin's hooks driven through the bundle test kit with chosen events (no
# real sleeping), and the shipped bundle installed and loaded by an Engine,
# voting through the real Gate.
RSpec.describe "The slow-commands bundle", :bundle do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/slow-commands", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("slow-commands-") }
  let(:project) { File.join(tmpdir, "repo").tap { |dir| FileUtils.mkdir_p(dir) } }
  # The plugin's ctx.data_dir in the example's sandbox.
  let(:data_dir) { File.join(sandbox.state_dir, "plugins", "slow-commands").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:mod) { shipped_bundle("slow-commands").namespace }
  let(:timed_out) { "Error: command timed out after 120s\n(killed at the limit; for a long command use task_create, then task_wait)" }

  after { FileUtils.rm_rf(tmpdir) }

  # The plugin as chi loads it, its session in +project+. Each call is a
  # new load (another session's or a restarted worker's plugin): the same
  # sandbox, so the same data dir.
  def plugin(settings = {}) = shipped_bundle("slow-commands", settings: settings, host: { cwd: project })

  def notices(p) = p.notices.map { |notice| [notice.text, notice.level] }

  def normalize(text, cwd: nil) = mod::Plugin.normalize(text, cwd: cwd, project: project, base: project)

  def execute(command, cwd: nil) = { name: "execute", content: command, cwd: cwd }.compact

  # One call through the hooks: before (the Gate's Verdict, or +verdict+),
  # then, unless denied, after with +result+ and +elapsed_s+.
  def call(p, command, result: "exit: 0", elapsed_s: 1, cwd: nil, verdict: nil)
    c = execute(command, cwd: cwd)
    verdict = p.tool_call(c, verdict: verdict)
    elapsed = verdict.deny? ? nil : (elapsed_s * 1000).round
    p.fire(:after_tool_call, tool: "execute", call: c, elapsed_ms: elapsed,
                             result: verdict.deny? ? "Error: #{verdict.deny_text}" : result)
    verdict
  end

  def turn(p) = p.fire(:before_turn, prompt: "go")

  def store = JSON.parse(File.read(File.join(data_dir, "commands.json")))

  describe "the key" do
    it "keeps operators: a && b is not a b" do
      expect(normalize("a && b")).to eq("a && b")
      expect(normalize("a b")).to eq("a b")
    end

    it "drops a trailing 2>&1 and tail/head/grep filters, keeps the arguments" do
      expect(normalize("bundle exec rspec 2>&1 | tail -20")).to eq("bundle exec rspec")
      expect(normalize("bundle exec rspec | grep -E 'fail' | head -5")).to eq("bundle exec rspec")
      expect(normalize("bundle exec rspec spec/foo_spec.rb 2>&1")).to eq("bundle exec rspec spec/foo_spec.rb")
      expect(normalize("rspec | sort")).to eq("rspec | sort")
    end

    it "folds the call's cwd in, relative to the project" do
      expect(normalize("npm test", cwd: "web")).to eq("cd web && npm test")
      expect(normalize("npm test", cwd: File.join(project, "web"))).to eq("cd web && npm test")
      expect(normalize("npm test", cwd: ".")).to eq("npm test")
    end

    it "is nil for unterminated input" do
      expect(normalize("echo 'oops")).to be_nil
      expect(normalize("cat <<EOF\nx")).to be_nil
    end

    # ShellLex makes each one placeholder: different commands would share
    # one key, and one slow script would deny every other.
    it "is nil for a $(…), backticks or a heredoc read as data" do
      ["echo $(date) && sleep 1", "rspec `git diff --name-only`", "cat <<EOF\nhi\nEOF",
       "git commit -m \"$(cat <<'EOF'\nmsg\nEOF\n)\""].each do |text|
        expect(normalize(text)).to be_nil, text
      end
    end

    it "keeps a heredoc script's body, so two scripts are two keys" do
      a = normalize("python3 - <<'EOF'\nprint(1)\nEOF")
      b = normalize("python3 - <<'EOF'\nprint(2)\nEOF")
      expect([a, b].compact.uniq.size).to eq(2)
    end

    describe "wrappers a model adds" do
      it "drops time [-p] and timeout/gtimeout [opts] DUR at the start of each simple command" do
        expect(normalize("timeout 240 bundle exec rspec")).to eq("bundle exec rspec")
        expect(normalize("time -p rspec && gtimeout -s KILL -k 5 --preserve-status 1.5h make")).to eq("rspec && make")
        expect(normalize("cd web && timeout --signal=TERM --foreground 5m npm test 2>&1 | tail -5")).to eq("cd web && npm test")
        expect(normalize("echo a; time timeout 30s rspec\nmake || timeout 2d make")).to eq("echo a ; rspec ; make || make")
        expect(normalize("rspec | timeout 5 tail")).to eq("rspec | timeout 5 tail")
        expect(normalize("echo timeout 5 x")).to eq("echo timeout 5 x")
      end

      it "keeps a timeout it can't read: an unknown option or duration" do
        expect(normalize("timeout --frobnicate 5 rspec")).to eq("timeout --frobnicate 5 rspec")
        expect(normalize("timeout 5x rspec")).to eq("timeout 5x rspec")
        expect(normalize("timeout 5")).to eq("timeout 5")
      end

      it "keeps assignments, sorted, without NO_COLOR, FORCE_COLOR and TERM; a plain env is dropped" do
        expect(normalize("B=2 A=1 rspec")).to eq(normalize("A=1 B=2 rspec"))
        expect(normalize("B=2 A=1 rspec")).to eq("A=1 B=2 rspec")
        expect(normalize("env RAILS_ENV=test NO_COLOR=1 rspec")).to eq("RAILS_ENV=test rspec")
        # jest/vitest watch without CI: CI=true npm test is another run.
        expect(normalize("CI=true npm test")).to eq("CI=true npm test")
        expect(normalize("FORCE_COLOR=0 TERM=dumb timeout 60 env SPEC=spec/a_spec.rb rake spec"))
          .to eq("SPEC=spec/a_spec.rb rake spec")
        expect(normalize("SPEC=spec/a_spec.rb rake spec")).not_to eq(normalize("rake spec"))
      end

      it "drops a simple command left with no words together with its operator" do
        expect(normalize("NO_COLOR=1 && rspec")).to eq("rspec")
        expect(normalize("TERM=dumb; rspec")).to eq("rspec")
        expect(normalize("time\nrspec")).to eq("rspec")
        expect(normalize("rspec && NO_COLOR=1")).to eq("rspec")
        expect(normalize("make; time; rspec")).to eq("make ; rspec")
        expect(normalize("CI=1 && rspec")).to eq("CI=1 && rspec")
      end

      it "keeps time with an option other than -p (GNU time -v is another program)" do
        expect(normalize("time -v rspec")).to eq("time -v rspec")
        expect(normalize("time -p rspec")).to eq("rspec")
      end

      it "never drops an env with -C, -i, -u (or another option)" do
        expect(normalize("env -C web npm test")).to eq("env -C web npm test")
        expect(normalize("env -i PATH=/bin make")).to eq("env -i PATH=/bin make")
        expect(normalize("env -u HOME make")).to eq("env -u HOME make")
      end

      it "still can't key a $(…) in an assignment" do
        expect(normalize("env FOO=$(pwd) rspec")).to be_nil
      end

      it "reads timeout's duration in seconds" do
        expect(mod::Plugin.timeout_seconds("timeout 5m rspec")).to eq(300)
        expect(mod::Plugin.timeout_seconds("cd x && timeout 1.5h a; timeout .5 b")).to eq(5400)
        expect(mod::Plugin.timeout_seconds("rspec")).to be_nil
      end

      it "records the run as typed in shown, keyed without the wrapper; the list shows it" do
        p = plugin
        call(p, "timeout 300 bundle exec rspec 2>&1 | tail -3", result: timed_out, elapsed_s: 120)
        expect(store).to contain_exactly(include("command" => "bundle exec rspec",
                                                 "shown" => "timeout 300 bundle exec rspec 2>&1 | tail -3"))
        expect(call(p, "bundle exec rspec")).to be_deny
        expect(p.command("/slow-commands")).to include("1. timeout 300 bundle exec rspec 2>&1 | tail -3: ran past")
      end

      it "gives a fast exit 124 (timeout fired) no meaning: nothing recorded, nothing dropped" do
        p = plugin
        call(p, "rspec", result: timed_out, elapsed_s: 120)
        turn(p)
        call(p, "timeout 5 rspec", result: "exit: 124", elapsed_s: 5) # denied (same key), so nothing ran
        call(p, "timeout 5 rspec", result: "exit: 124", elapsed_s: 5)
        expect(store.map { |e| e["command"] }).to eq(["rspec"])
        call(p, "timeout 5 make", result: "exit: 124", elapsed_s: 5)
        expect(store.map { |e| e["command"] }).to eq(["rspec"])
      end

      describe "a timeout past the execute limit" do
        def with_on_timeout(mode, &)
          with_env("SAMAGOTCHI_EXECUTE_ON_TIMEOUT" => mode, &)
        end

        it "is denied up front once a turn when execute kills at the limit, never suggesting timeout" do
          with_on_timeout("kill") do
            p = plugin
            verdict = call(p, "cd web && timeout 300 npm test")
            expect(verdict).to be_deny
            expect(verdict.deny_text).to include("execute stops a command at 120 s, so its timeout (5m00s) never takes effect.",
                                                 "Start it with task_create, then task_wait (timeout 600).")
            # No `timeout N` to run (stock macOS has none): only task_wait's own timeout.
            expect(verdict.deny_text.gsub("task_wait (timeout", "")).not_to match(/timeout \d/)
            expect(notices(p).last).to eq(["execute cd web && timeout 300 npm test: timeout 5m00s is past the 120 s limit, denied", :warn])
            expect(call(p, "cd web && timeout 300 npm test")).not_to be_deny
            expect(call(p, "timeout 60 npm test")).not_to be_deny
          end
        end

        it "runs on under on_timeout: task (it becomes a task), and only warns in notify mode" do
          with_on_timeout("task") do
            p = plugin
            expect(call(p, "timeout 300 npm test")).not_to be_deny
            expect(notices(p)).to eq([])
          end
          with_on_timeout("kill") do
            p = plugin("mode" => "notify")
            expect(call(p, "timeout 300 npm test")).not_to be_deny
            expect(notices(p).last.first).to end_with("is past the 120 s limit")
          end
        end
      end
    end

    it "neither records nor denies a slow $(…) or heredoc command" do
      p = plugin
      ["rspec $(git diff --name-only)", "cat <<EOF\nhi\nEOF"].each do |text|
        call(p, text, result: timed_out, elapsed_s: 120)
        expect(call(p, text)).not_to be_deny
      end
      expect(File.exist?(File.join(data_dir, "commands.json"))).to be false
    end
  end

  describe "recording" do
    it "records a timed-out command as slow, with the project and command apart" do
      p = plugin
      call(p, "bundle exec rspec", result: timed_out, elapsed_s: 120)
      expect(store).to contain_exactly(include("project" => project, "command" => "bundle exec rspec", "limit_s" => 120,
                                               "timed_out" => true))
    end

    it "records a command handed over as a task at the limit as timed out, whatever its elapsed time" do
      p = plugin
      handed = "#{Samagotchi::Tools::Execute.handed_over_line(90)}\ntask_id: 20261011120000-1a2b3c4d\n" \
               "Wait for it with task_wait (it may take minutes); task_stop stops it."
      call(p, "bundle exec rspec", result: handed, elapsed_s: 0)
      expect(store).to contain_exactly(include("command" => "bundle exec rspec", "limit_s" => 90, "elapsed_s" => 90,
                                               "timed_out" => true))
    end

    it "records a run of warn_ratio of the limit or more" do
      p = plugin
      call(p, "npm test", result: "exit: 0", elapsed_s: 100)
      expect(store).to contain_exactly(include("command" => "npm test", "elapsed_s" => 100, "timed_out" => false))
    end

    it "drops an entry on a fast exit 0, keeps it on a fast failure" do
      p = plugin
      call(p, "rspec", result: timed_out, elapsed_s: 120)
      turn(p)
      call(p, "rspec") # denied
      call(p, "rspec", result: "stdout:\nboom\nexit: 1", elapsed_s: 2)
      expect(store.size).to eq(1)
      call(p, "rspec", result: "exit: 0", elapsed_s: 2)
      expect(store).to eq([])
    end

    it "keeps an entry on a fast exit 0 through a stripped filter: the exit code is the filter's" do
      p = plugin
      call(p, "rspec", result: timed_out, elapsed_s: 120)
      call(p, "rspec") # denied
      ["rspec 2>&1 | tail -30", "rspec | head -5", "rspec 2>&1"].each do |text|
        call(p, text, result: "stdout:\nLoadError\nexit: 0", elapsed_s: 2)
      end
      expect(store.map { |e| e["command"] }).to eq(["rspec"])
      call(p, "rspec;", result: "exit: 0", elapsed_s: 2)
      expect(store).to eq([])
    end

    it "records nothing for a stopped or denied call" do
      p = plugin
      call(p, "rspec", result: "Error: command stopped by the user after 130s (killed; rerun it if still needed)", elapsed_s: 130)
      call(p, "rspec", result: "Error: command stopped by a signal to chi after 130s (killed; rerun it if still needed)",
                       elapsed_s: 130)
      call(p, "rspec", result: "Error: command stopped as the session was stopped after 130s (killed; rerun it if still needed)",
                           elapsed_s: 130)
      c = execute("rspec")
      p.fire(:after_tool_call, tool: "execute", call: c, elapsed_ms: nil, result: timed_out)
      expect(File.exist?(File.join(data_dir, "commands.json"))).to be false
    end

    it "prunes entries older than ttl_days on write" do
      File.write(File.join(data_dir, "commands.json"),
                 JSON.generate([{ "project" => project, "command" => "old", "slow_at" => (Time.now - (15 * 86_400)).utc.iso8601,
                                  "limit_s" => 120, "elapsed_s" => 120, "timed_out" => true }]))
      p = plugin
      expect(call(p, "old")).not_to be_deny
      call(p, "new", result: timed_out, elapsed_s: 120)
      expect(store.map { |e| e["command"] }).to eq(["new"])
    end
  end

  describe "denying" do
    it "denies a slow command once a turn, with advice and a notice; a new turn denies again" do
      p = plugin
      call(p, "bundle exec rspec 2>&1 | tail -5", result: timed_out, elapsed_s: 120)
      turn(p)

      verdict = call(p, "bundle exec rspec")
      expect(verdict).to be_deny
      expect(verdict.deny_text).to include("(bundle slow-commands)", "slow command",
                                           "ran past the execute limit (120 s) here on #{Time.now.utc.strftime("%F")}",
                                           "Start it with task_create, then task_wait (timeout 600).")
      expect(notices(p)).to eq([["execute bundle exec rspec: ran past 120 s before, denied", :warn]])
      expect(call(p, "bundle exec rspec", result: timed_out, elapsed_s: 120)).not_to be_deny

      turn(p)
      expect(call(p, "bundle exec rspec")).to be_deny
    end

    it "only warns in notify mode" do
      p = plugin("mode" => "notify")
      call(p, "rspec", result: timed_out, elapsed_s: 120)
      expect(call(p, "rspec")).not_to be_deny
      expect(notices(p)).to eq([["execute rspec: ran past 120 s before", :warn]])
    end

    it "leaves another voter's deny alone" do
      p = plugin
      call(p, "rspec", result: timed_out, elapsed_s: 120)
      c = execute("rspec")
      verdict = p.tool_call(c, verdict: Samagotchi::Testing::Verdict.new(call: c).deny!("other", source: "x"))
      expect(verdict.deny_text).to include("(x): other")
      expect(notices(p)).to be_empty
      expect(call(p, "rspec")).to be_deny # still its first deny this turn
    end

    it "sees another session's record at once" do
      p = plugin
      other = plugin
      call(other, "rspec", result: timed_out, elapsed_s: 120)
      expect(call(p, "rspec")).to be_deny
    end

    describe "the advice's duration, from a finished task" do
      def task(id, command, cwd:, started:, ended:, exit_code: "0")
        dir = File.join(project, "tmp", "tasks", id)
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "task.json"),
                   JSON.generate("id" => id, "command" => command, "cwd" => cwd, "status" => "running",
                                 "started_at" => started.utc.iso8601, "finished_at" => nil))
        path = File.join(dir, "exit_code")
        File.write(path, exit_code)
        File.utime(ended, ended, path)
      end

      it "is the exit_code file's mtime minus started_at, newest task first, a cwd mismatch skipped" do
        now = Time.at(Time.now.to_i)
        task("a", "bundle exec rspec", cwd: project, started: now - 3600, ended: now - 3600 + 250)
        task("b", "bundle exec rspec", cwd: File.join(project, "web"), started: now - 600, ended: now - 590)
        task("c", "bundle exec rspec", cwd: project, started: now - 1800, ended: now - 1800 + 500, exit_code: "1")
        p = plugin
        call(p, "bundle exec rspec", result: timed_out, elapsed_s: 120)

        text = call(p, "bundle exec rspec").deny_text
        expect(text).to include("A finished task of this command took 4m10s.", "task_wait (timeout 600)")
      end

      it "reads a handed-over execute's exit_code where its record says (the state dir)" do
        now = Time.at(Time.now.to_i)
        dir = File.join(project, "tmp", "tasks", "h")
        FileUtils.mkdir_p(dir)
        state = File.join(tmpdir, "state", "execute", "h").tap { |d| FileUtils.mkdir_p(d) }
        code = File.join(state, "exit_code")
        File.write(File.join(dir, "task.json"),
                   JSON.generate("id" => "h", "command" => "make", "cwd" => project, "status" => "running",
                                 "started_at" => (now - 3600).utc.iso8601, "exit_code_path" => code))
        File.write(code, "0")
        File.utime(now - 3600 + 300, now - 3600 + 300, code)
        p = plugin
        call(p, "make", result: timed_out, elapsed_s: 120)
        expect(call(p, "make").deny_text).to include("A finished task of this command took 5m00s.")
      end

      it "raises the task_wait timeout for a longer task" do
        now = Time.at(Time.now.to_i)
        task("a", "make", cwd: project, started: now - 3600, ended: now - 3600 + 900)
        p = plugin
        call(p, "make", result: timed_out, elapsed_s: 120)
        expect(call(p, "make").deny_text).to include("task_wait (timeout 1380)", "took 15m00s.")
      end
    end
  end

  describe "/slow-commands" do
    it "lists this project's entries and forgets one or all" do
      p = plugin
      cmd = ->(args) { p.command("/slow-commands #{args}") }
      expect(cmd.call("")).to eq("slow-commands: none recorded for #{project}")
      call(p, "rspec", result: timed_out, elapsed_s: 120)
      call(p, "npm test", result: "exit: 0", elapsed_s: 110)
      File.write(File.join(data_dir, "commands.json"),
                 JSON.generate(store + [store.first.merge("project" => File.join(tmpdir, "other"), "command" => "make")]))
      date = Time.now.utc.strftime("%F")

      listing = cmd.call("")
      expect(listing).to eq("slow-commands in #{project}:\n1. rspec: ran past 120 s (#{date})\n" \
                            "2. npm test: took 1m50s of 120 s (#{date})\n/slow-commands forget <n|all> drops an entry")

      expect(cmd.call("forget 2")).to eq("slow-commands: forgot npm test")
      expect(store.map { |e| e["command"] }).to eq(%w[rspec make])
      expect(cmd.call("forget 9")).to eq("slow-commands: no entry 9 (/slow-commands lists them)")
      expect(cmd.call("forget all")).to eq("slow-commands: forgot rspec")
      expect(store.map { |e| e["command"] }).to eq(%w[make])
      expect(cmd.call("nope")).to start_with("usage: /slow-commands")
    end
  end

  # Installed as a user would, loaded by an Engine: its hooks vote through
  # the real Gate in ToolRunner, with after_tool_call's call:, elapsed_ms:
  # and result: from ToolRunner itself.
  # Off the kit's sandbox: an Engine under the suite's own environment.
  describe "the shipped bundle", bundle: false do
    let(:system_dir) { Samagotchi::MemoryPaths.system_dir }
    let(:client) { instance_double(Samagotchi::Client, complete: nil) }
    let(:engine) { Samagotchi::Engine.new(client: client) }
    let(:hooks) { engine.instance_variable_get(:@hooks) }
    let(:output) { ["[execute]\n#{timed_out}"] }
    let(:runner) do
      out = output
      kernel = Struct.new(:hooks, :tools, :guardrail_gate) do
        define_method(:dispatch_tool_call) { |c| { output: out.first, activity: { tool: c[:name], status: "error" } } }
      end
      Samagotchi::ToolRunner.new(kernel.new(hooks))
    end

    around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

    around do |example|
      saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
      Dir.chdir(project) { example.run }
    ensure
      %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
    end

    before do
      # requires_chi names the release that carries after_tool_call's new keys.
      stub_const("Samagotchi::VERSION", "0.59.0")
      FileUtils.mkdir_p(system_dir)
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      @installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "slow-commands", scope: "system", strict: true)
      @installer.run
    end

    def run(c) = runner.run(c, iteration: 1, call_index: 1, call_count: 1, on_stream_event: ->(_) {}, max_tool_output_chars: nil)

    it "installs cleanly and loads" do
      expect(@installer.warnings).to be_empty
      expect(engine.guardrail_failures.any?).to be false
    end

    it "records a timed-out execute, denies the next identical one once, and lets the second through" do
      hooks.fire(:before_turn, { type: :before_turn, prompt: "test" })
      expect(run(execute("bundle exec rspec")).output).to start_with("[execute]\nError: command timed out")
      hooks.fire(:before_turn, { type: :before_turn, prompt: "again" })
      expect(run(execute("bundle exec rspec")).output)
        .to start_with("[execute] Error: denied by guardrail (bundle slow-commands): slow command. ")
      expect(run(execute("bundle exec rspec")).output).to start_with("[execute]\nError: command timed out")
    end
  end
end
