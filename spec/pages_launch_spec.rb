# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/pages"
require "samagotchi/pages/launch"
require "samagotchi/pages/runner"

# One run of a page: a real runner process, its result through the output
# file, the cut, the lock. Each example starts its own runner and, for the
# cut, kills only the pids its script wrote down.
RSpec.describe Samagotchi::Pages::Launch do
  let(:tmp) { Dir.mktmpdir("pages-launch") }
  let(:pages) { Samagotchi::Pages }
  let(:store) { Samagotchi::Pages::Store }
  let(:fixtures) { File.expand_path("fixtures/pages", __dir__) }
  let(:tracked) { [] }
  # Runner pids (group leaders) a spec saw: killed as a group, only while
  # still that runner's group.
  let(:runners) { [] }

  around do |example|
    with_env("XDG_CONFIG_HOME" => File.join(tmp, "config"), "XDG_STATE_HOME" => File.join(tmp, "state")) { example.run }
  ensure
    runners.each do |pid|
      Process.kill("KILL", -pid) if Samagotchi::ProcessGroup.leader?(pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    tracked.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    FileUtils.rm_rf(tmp)
  end

  def script(name, body)
    FileUtils.mkdir_p(pages.scripts_dir)
    File.write(pages.script_path(name), body)
  end

  def run(name, timeout: 20) = described_class.run(name, timeout: timeout)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  it "requiring the runner runs nothing" do
    expect(pages::Runner).to respond_to(:run)
    expect(File.exist?(pages.scripts_dir)).to be(false)
  end

  it "runs the usage page in its own process and stores the fixture's numbers" do
    FileUtils.mkdir_p(pages.scripts_dir)
    FileUtils.cp(File.join(fixtures, "usage.rb"), pages.script_path("usage"))
    FileUtils.cp(File.join(fixtures, "usage.json"), pages.scripts_dir)

    result = run("usage")
    expect(result).to be_ok
    page = result.page
    expect(page.state).to eq(:ok)
    expect(page.title).to eq("Usage, last 7 days")
    expect(page.blocks[0]).to eq("type" => "text", "text" => "Stored cost per model. 412 turns.")
    expect(page.blocks[1]["rows"]).to include(["claude:sonnet-5-5", 96, 14.221])
    expect(page.blocks[1]["total"]).to eq(["Total", 412, 18.1252])
    expect(page.script_sha).to eq(store.script_sha("usage"))
    expect(page.duration_ms).to be_a(Integer)
  end

  it "keeps a script's puts out of the result" do
    script("noisy", "puts 'hello'\nwarn 'careful'\npage('Noisy') { |ui| ui.text 'x' }\n")
    result = run("noisy")
    expect(result).to be_ok
    expect(result.stdout).to eq("hello\n")
    expect(result.stderr).to eq("careful\n")
  end

  it "records a raise with its line and keeps the last good blocks" do
    script("usage", "page('Usage') { |ui| ui.text 'good' }\n")
    expect(run("usage")).to be_ok
    script("usage", "page('Usage') do |ui|\n  ui.text 'x'\n  raise 'boom'\nend\n")

    result = run("usage")
    expect(result).not_to be_ok
    expect(result.page.state).to eq(:failed)
    expect(result.page.error.line).to eq(3)
    expect(result.page.error.message).to eq("boom")
    expect(result.page.blocks).to eq([{ "type" => "text", "text" => "good" }])
  end

  it "records a builder's refusal at the script's line" do
    script("bad", "page('Bad') do |ui|\n  ui.table [], columns: ['a'], format: { 'a' => :percent }\nend\n")
    page = run("bad").page
    expect(page.error.message).to eq('table 1: column "a" has format :percent (use :money or :count)')
    expect(page.error.line).to eq(2)
  end

  it "records a syntax error with its line" do
    script("broken", "page('Broken') do |ui|\n  ui.text 'x'\n  def (\nend\n")
    result = run("broken")
    expect(result).not_to be_ok
    expect(result.page.error).not_to be_nil
    expect(result.page.error.line).to be_a(Integer)
  end

  it "records an exit in the script as a failure" do
    script("quits", "page('Quits') { |ui| ui.text 'x' }\nexit 3\n")
    result = run("quits")
    expect(result).not_to be_ok
    expect(result.page.error.message).to eq("the script called exit 3")
    expect(result.page.error.line).to eq(2)
  end

  it "fails a script that never calls page, or calls it twice" do
    script("none", "x = 1\n")
    expect(run("none").page.error.message).to eq("the script never called page")

    script("twice", "page('A') { }\npage('B') { }\n")
    expect(run("twice").page.error.message).to eq("a page script calls page once")
  end

  it "defines no top-level method for the script" do
    script("defs", <<~RUBY)
      def helper = 1
      page("Defs") { |ui| ui.text "\#{helper} \#{Object.private_method_defined?(:helper)}" }
    RUBY
    result = run("defs")
    expect(result).to be_ok
    expect(result.page.blocks).to eq([{ "type" => "text", "text" => "1 false" }])
  end

  it "records a runner that ended without a result" do
    script("killed", "Process.kill('KILL', Process.pid)\n")
    result = run("killed")
    expect(result).not_to be_ok
    expect(result.page.error.message).to start_with("the runner ended without a result")
  end

  it "stores a message that isn't valid UTF-8 readable, with its line" do
    script("bytes", "page('Bytes') do |ui|\n  raise \"bad \\xff byte\".b\nend\n")
    error = run("bytes").page.error
    expect(error.message).to eq("bad \uFFFD byte")
    expect(error.line).to eq(2)
  end

  it "takes the last stderr line that isn't a backtrace frame for a runner with no result" do
    script("frames", "warn 'the real reason'\nwarn \"\\tfrom -e:1:in '<main>'\"\nProcess.kill('KILL', Process.pid)\n")
    expect(run("frames").page.error.message).to eq("the runner ended without a result: the real reason")
  end

  it "records endless recursion as the script's failure, with its line" do
    script("deep", "def f(n) = f(n + 1)\npage('Deep') { |ui| f(0) }\n")
    error = run("deep").page.error
    expect(error.message).to include("stack level too deep")
    expect(error.line).to eq(1)
  end

  it "cuts a script at the timeout, with what it started" do
    pid_file = File.join(tmp, "pids.json")
    script("slow", <<~RUBY)
      child = Process.spawn("sleep", "20")
      File.write(#{pid_file.inspect}, JSON.generate([Process.pid, child]))
      sleep 20
      page("Slow") { }
    RUBY

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = run("slow", timeout: 3)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    pids = JSON.parse(File.read(pid_file))
    tracked.concat(pids)

    expect(result).not_to be_ok
    expect(result.page.error.message).to eq("the script was stopped after 3 s")
    expect(elapsed).to be < 15
    pids.each { |pid| wait_for("pid #{pid} to be gone after the cut", timeout: 3) { !alive?(pid) } }
  end

  it "refuses a second run while one holds the lock" do
    script("usage", "page('Usage') { }\n")
    store.locked("usage") do
      expect { run("usage") }.to raise_error(Samagotchi::Pages::Busy, "page usage is already running")
    end
  end

  # The launcher (chi web, a terminal) killed mid-run: the runner holds the
  # lock and stops itself at its own deadline, recording the cut.
  it "leaves at most one bounded run when its launcher is killed mid-run" do
    pid_file = File.join(tmp, "runner.pid")
    script("orphan", <<~RUBY)
      File.write(#{pid_file.inspect}, Process.pid.to_s)
      sleep 30
      page("Orphan") { }
    RUBY
    boot = 'require "samagotchi/pages/launch"; Samagotchi::Pages::Launch.run("orphan", timeout: 3)'
    launcher = Process.spawn(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", boot,
                             in: File::NULL, out: File::NULL, err: File::NULL)
    tracked << launcher
    wait_for("the runner to write its pid", timeout: 10) { File.size?(pid_file) }
    runner = Integer(File.read(pid_file))
    runners << runner
    Process.kill("KILL", launcher)
    Process.wait(launcher)

    # A short timeout: on unchanged code this run starts (no Busy) and is cut.
    expect { run("orphan", timeout: 2) }.to raise_error(Samagotchi::Pages::Busy)
    # timeout 3 s + the grace + the margin, from the runner's start
    wait_for("the runner to stop at its deadline", timeout: 12) { !alive?(runner) }
    expect(store.read("orphan").error.message).to eq("the script was stopped after 3 s")
    script("orphan", "page('Orphan') { }\n")
    expect(run("orphan")).to be_ok
  end

  it "stops a run when cancelled says so, recorded as stopped" do
    script("held", "sleep 20\npage('Held') { }\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    calls = 0
    result = described_class.run("held", timeout: 20, cancelled: -> { (calls += 1) > 5 })
    expect(result).not_to be_ok
    expect(result.page.error.message).to eq("the run was stopped")
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
  end

  # A child the script starts in a group of its own outlives the run (the
  # stated limit), but must not inherit the lock: the page would stay
  # "already running" for as long as the child lives.
  it "leaves the page runnable when the script's child moves to its own group" do
    pid_file = File.join(tmp, "child.pid")
    script("spawner", <<~RUBY)
      child = Process.spawn("sleep", "30", pgroup: true, in: File::NULL, out: File::NULL, err: File::NULL)
      Process.detach(child)
      File.write(#{pid_file.inspect}, child.to_s)
      page("Spawner") { |ui| ui.text "x" }
    RUBY
    first = run("spawner")
    expect(first.page.error).to be_nil
    expect(first).to be_ok
    tracked << Integer(File.read(pid_file))
    expect(alive?(tracked.last)).to be(true)
    expect(run("spawner")).to be_ok
  end

  it "clears the remote, worker and agent markers from the script's environment" do
    out = File.join(tmp, "markers.json")
    keys = %w[CHI_REMOTE SAMAGOTCHI_WORKER_SESSION CLAUDECODE CODEX_THREAD_ID AI_AGENT]
    script("markers", <<~RUBY)
      File.write(#{out.inspect}, JSON.generate(ENV.keys.select { |k| #{keys.inspect}.include?(k) || k.start_with?("SAMAGOTCHI_WORKER_") }))
      page("Markers") { }
    RUBY
    with_env(keys.to_h { |key| [key, "1"] }) { expect(run("markers")).to be_ok }
    expect(JSON.parse(File.read(out))).to eq([])
  end

  it "names the cleared keys from their constants" do
    cleared = described_class.cleared_keys("SAMAGOTCHI_WORKER_X" => "1", "PATH" => "/bin")
    expect(cleared).to include(Samagotchi::SessionAccess::Dispatch::ENV_KEY, "SAMAGOTCHI_WORKER_X",
                               *Samagotchi::AgentCaller::VENDOR_MARKERS.map(&:first))
    expect(cleared).not_to include("PATH")
  end

  it "refuses an unknown page or a bad name before taking a lock" do
    expect { run("nope") }.to raise_error(Samagotchi::Pages::Missing, "no page nope")
    expect { run("Nope") }.to raise_error(Samagotchi::Pages::BadName)
    expect(File.exist?(store.lock_path("nope"))).to be(false)
  end

  it "writes nothing when chi page rm wins the race to the lock" do
    script("ghost", "page('Ghost') { }\n")
    allow(store).to receive(:locked).and_wrap_original do |locked, name, &block|
      FileUtils.rm_f(pages.script_path(name)) # rm ran between the first check and the lock
      locked.call(name, &block)
    end

    expect { run("ghost") }.to raise_error(Samagotchi::Pages::Missing, "no page ghost")
    expect(File.exist?(store.output_dir("ghost"))).to be(false)
    expect(File.exist?(store.lock_path("ghost"))).to be(false)
  end

  it "runs the script in the pages folder, with PWD and the XDG dirs absolute" do
    script("where", <<~RUBY)
      File.write(File.join(#{tmp.inspect}, "where.json"),
                 JSON.generate([Dir.pwd, ENV["PWD"], ENV["XDG_STATE_HOME"]]))
      page("Where") { }
    RUBY
    expect(run("where")).to be_ok
    cwd, pwd, state = JSON.parse(File.read(File.join(tmp, "where.json")))
    expect(File.realpath(cwd)).to eq(File.realpath(pages.scripts_dir))
    expect(pwd).to eq(pages.scripts_dir)
    expect(state).to eq(File.join(tmp, "state"))
  end

  it "loads nothing of the engine, the config, the web, the plugins or the launcher in the runner" do
    out = File.join(tmp, "features.json")
    script("light", <<~RUBY)
      heavy = $LOADED_FEATURES.grep(%r{/lib/samagotchi/(engine|config|web|plugin|child_env|process_group|pages/launch)})
      pages = $LOADED_FEATURES.grep(%r{/lib/samagotchi/pages})
      File.write(#{out.inspect}, JSON.generate("heavy" => heavy, "pages" => pages))
      page("Light") { }
    RUBY
    expect(run("light")).to be_ok
    loaded = JSON.parse(File.read(out))
    expect(loaded["heavy"]).to eq([])
    expect(loaded["pages"]).not_to be_empty
  end
end
