# frozen_string_literal: true

require "samagotchi/tools/execute"
require "samagotchi/tools/builtins"
require "samagotchi/tools/peers"
require "open3"
require "tempfile"
require "tmpdir"
require "fileutils"

RSpec.describe Samagotchi::Tools::Execute do
  around do |example|
    original_env = {
      "SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES" => ENV["SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES"],
      "SAMAGOTCHI_EXECUTE_PREVIEW_BYTES" => ENV["SAMAGOTCHI_EXECUTE_PREVIEW_BYTES"],
      "SAMAGOTCHI_EXECUTE_TIMEOUT_SEC" => ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"],
      "SAMAGOTCHI_CONTEXT_WINDOW_TOKENS" => ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"],
      "SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN" => ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"],
      "SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT" => ENV["SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT"]
    }

    example.run
  ensure
    original_env.each { |key, value| ENV[key] = value }
  end

  # A finer wait slice: the limit and a Stop are seen sooner (it is only
  # how often the wait looks, never what it decides).
  before { stub_const("#{described_class}::WAIT_SLICE_SEC", 0.05) }

  describe ".name" do
    it "is 'execute'" do
      expect(described_class.name).to eq("execute")
    end
  end

  describe ".call" do
    # A limit under a second, for an example about what happens at the limit.
    # 0.5 s where the command must get somewhere first (print, fork, set its
    # trap, leave its group); else the example passes without reaching what
    # it is about. Two examples keep a real whole-second execute.timeout_sec
    # end to end: the kill (its error's text, the output before it) and the
    # default hand-over.
    def short_limit(seconds = 0.2) = allow(described_class).to receive(:timeout_seconds).and_return(seconds)

    # A chi run by the command answers as a parent agent (ParentApprovals).
    it "exports SAMAGOTCHI_PARENT_SESSION, the session's id, from the builtin handler" do
      require "samagotchi/tools/builtins"
      kctx = Struct.new(:peers).new(Struct.new(:cancelled?, :session_id).new(false, "sess-1"))
      result = Samagotchi::Tools::Builtins::HANDLERS.fetch("execute").call({ content: "printenv SAMAGOTCHI_PARENT_SESSION" }, kctx)
      expect(result).to start_with("[stdout]\nsess-1").or include("sess-1")
      bare = Samagotchi::Tools::Builtins::HANDLERS.fetch("execute")
                                                  .call({ content: "printenv SAMAGOTCHI_PARENT_SESSION" }, Struct.new(:peers).new(nil))
      expect(bare).to include("chi")
    end

    # chi self run by the command reports the session's model (live after /model).
    it "exports SAMAGOTCHI_SESSION_THINKING, the session's own level, and unsets an inherited one without it" do
      require "samagotchi/tools/builtins"
      execute = Samagotchi::Tools::Builtins::HANDLERS.fetch("execute")
      own = Struct.new(:peers).new(Samagotchi::Tools::Peers.new(session_id: "sess-1", thinking: :low, cancelled: false))
      expect(execute.call({ content: "printenv SAMAGOTCHI_SESSION_THINKING" }, own)).to include("low")

      with_env("SAMAGOTCHI_SESSION_THINKING" => "high") do
        none = Struct.new(:peers).new(Samagotchi::Tools::Peers.new(session_id: "sess-1", cancelled: false))
        bare = execute.call({ content: "printenv SAMAGOTCHI_SESSION_THINKING; echo done" }, none)
        expect(bare).to include("done")
        expect(bare).not_to include("high")
      end
    end

    it "exports SAMAGOTCHI_SESSION_REASONING_HISTORY, the session's own level, and unsets an inherited one without it" do
      require "samagotchi/tools/builtins"
      execute = Samagotchi::Tools::Builtins::HANDLERS.fetch("execute")
      own = Struct.new(:peers).new(Samagotchi::Tools::Peers.new(session_id: "sess-1", reasoning_history: :all, cancelled: false))
      expect(execute.call({ content: "printenv SAMAGOTCHI_SESSION_REASONING_HISTORY" }, own)).to include("all")

      with_env("SAMAGOTCHI_SESSION_REASONING_HISTORY" => "drop") do
        none = Struct.new(:peers).new(Samagotchi::Tools::Peers.new(session_id: "sess-1", cancelled: false))
        bare = execute.call({ content: "printenv SAMAGOTCHI_SESSION_REASONING_HISTORY; echo done" }, none)
        expect(bare).to include("done")
        expect(bare).not_to include("drop")
      end
    end

    # A chi the command runs in another cwd (chi send) reads the same dirs.
    it "passes a relative XDG_STATE_HOME / XDG_CONFIG_HOME on made absolute, for a command run in another cwd" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          cwd = Dir.pwd
          with_env("XDG_STATE_HOME" => "rel/state", "XDG_CONFIG_HOME" => "rel/config") do
            output = Samagotchi::Tools::Builtins::HANDLERS.fetch("execute")
                                                          .call({ content: 'echo "[$XDG_STATE_HOME|$XDG_CONFIG_HOME]"',
                                                                  cwd: Dir.tmpdir }, Struct.new(:peers).new(nil))
            expect(output).to include("[#{cwd}/rel/state|#{cwd}/rel/config]")
          end
        end
      end
    end

    it "exports SAMAGOTCHI_SESSION_MODEL, the session's model ref, and unsets an inherited one without it" do
      require "samagotchi/tools/builtins"
      peers = Samagotchi::Tools::Peers.new(session_id: "sess-1", model_ref: "splash:qwen", cancelled: false)
      kctx = Struct.new(:peers).new(peers)
      execute = Samagotchi::Tools::Builtins::HANDLERS.fetch("execute")
      expect(execute.call({ content: "printenv SAMAGOTCHI_SESSION_MODEL" }, kctx)).to include("splash:qwen")

      with_env("SAMAGOTCHI_SESSION_MODEL" => "stale:model") do
        bare = execute.call({ content: "printenv SAMAGOTCHI_SESSION_MODEL; echo done" }, Struct.new(:peers).new(nil))
        expect(bare).to include("done")
        expect(bare).not_to include("stale:model")
      end
    end

    it "captures stdout and reports exit 0" do
      result = described_class.call("ruby -e 'puts \"hello world\"'")
      expect(result).to include("hello world")
      expect(result).to include("exit: 0")
    end

    it "captures stderr" do
      result = described_class.call("ruby -e '$stderr.puts \"oops\"'")
      expect(result).to include("oops")
    end

    it "captures non-zero exit codes" do
      result = described_class.call("ruby -e 'exit 42'")
      expect(result).to include("exit: 42")
    end

    it "says when a command printed nothing" do
      expect(described_class.call("true")).to eq("exit: 0 (no output)")
      expect(described_class.call("false")).to eq("exit: 1 (no output)")
    end

    it "keeps a bare exit line when there was output" do
      result = described_class.call("echo hi")
      expect(result).to end_with("\nexit: 0")
      expect(result).not_to include("no output")
    end

    it "captures Ruby syntax errors" do
      result = described_class.call("ruby -e 'def bad('")
      expect(result).not_to include("exit: 0")
    end

    it "can run an rspec spec file" do
      spec_content = <<~SPEC
        RSpec.describe "math" do
          it "adds correctly" do
            expect(1 + 1).to eq(2)
          end
        end
      SPEC

      tmp = Tempfile.new(["samagotchi_test", "_spec.rb"])
      tmp.write(spec_content)
      tmp.close

      result = described_class.call("bundle exec rspec #{tmp.path} --no-color")
      expect(result).to include("1 example, 0 failures")
    ensure
      tmp&.unlink
    end

    it "truncates oversized stdout with preview metadata" do
      ENV["SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES"] = "100"
      ENV["SAMAGOTCHI_EXECUTE_PREVIEW_BYTES"] = "20"

      result = described_class.call("ruby -e 'print " + "\"A\"*200" + "'")

      expect(result).to include("stdout:")
      expect(result).to include("truncated=true")
      expect(result).to include("preview_strategy=head_tail")
      expect(result).to include("stdout_bytes=200")
      expect(result).to include("[TRUNCATED_PREVIEW_HEAD]")
      expect(result).to include("[TRUNCATED_PREVIEW_TAIL]")
      expect(result).to include("exit: 0")
    end

    it "includes output telemetry only when threshold is crossed" do
      ENV["SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES"] = "10"
      ENV["SAMAGOTCHI_EXECUTE_PREVIEW_BYTES"] = "40"
      ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = "10"
      ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"] = "1"
      ENV["SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT"] = "50"

      result = described_class.call("ruby -e 'print " + "\"z\"*100" + "'")

      expect(result).to include("estimated_tokens_for_command_output=")
      expect(result).to include("estimated_window_pct_for_command_output=")
    end

    it "omits output telemetry when threshold is not crossed" do
      ENV["SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES"] = "10"
      ENV["SAMAGOTCHI_EXECUTE_PREVIEW_BYTES"] = "10"
      ENV["SAMAGOTCHI_CONTEXT_WINDOW_TOKENS"] = "100000"
      ENV["SAMAGOTCHI_CONTEXT_CHARS_PER_TOKEN"] = "4"
      ENV["SAMAGOTCHI_EXECUTE_TELEMETRY_THRESHOLD_PCT"] = "99"

      result = described_class.call("ruby -e 'print " + "\"z\"*100" + "'")

      expect(result).not_to include("estimated_tokens_for_command_output=")
      expect(result).not_to include("estimated_window_pct_for_command_output=")
    end

    it "runs in the specified cwd" do
      dir = Dir.mktmpdir("execute_cwd")
      result = described_class.call("ruby -e 'puts Dir.pwd'", cwd: dir)
      expect(result).to include(dir)
      expect(result).to include("exit: 0")
    end

    it "resolves a relative cwd against the project root" do
      subdir = File.join(Dir.pwd, "tmp", "execute_cwd_relative_probe")
      FileUtils.mkdir_p(subdir)
      begin
        result = described_class.call("ruby -e 'puts Dir.pwd'", cwd: "tmp/execute_cwd_relative_probe")
        expect(result).to include(subdir)
        expect(result).to include("exit: 0")
      ensure
        FileUtils.remove_entry(subdir)
      end
    end

    it "returns an error for a nonexistent cwd" do
      result = described_class.call("ruby -e 'puts 1'", cwd: "/definitely/not/here/execute_probe")
      expect(result).to start_with("Error: cwd not found:")
    end

    it "gives a command 120 s by default, the same as the config default" do
      ENV.delete("SAMAGOTCHI_EXECUTE_TIMEOUT_SEC")
      Dir.mktmpdir do |dir|
        with_env("XDG_CONFIG_HOME" => dir) do
          expect(described_class.timeout_seconds).to eq(120)
        end
      end
      expect(Samagotchi::Config::ENTRIES.find { |e| e.key == "execute.timeout_sec" }.default).to eq(described_class::TIMEOUT_SEC)
    end

    it "takes the timeout from config.yml's execute.timeout_sec" do
      ENV.delete("SAMAGOTCHI_EXECUTE_TIMEOUT_SEC")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "samagotchi"))
        File.write(File.join(dir, "samagotchi", "config.yml"),
                   "default:\n  model: m\nexecute:\n  timeout_sec: 1\n  on_timeout: kill\n")
        with_env("XDG_CONFIG_HOME" => dir) do
          expect(Samagotchi::Config.validate_yaml_sections(Samagotchi::ConfigFile.read_yaml)).to eq([])
          expect(described_class.timeout_seconds).to eq(1)
          # on_timeout: kill from the file too: killed, not handed over (at
          # a short limit: the limit's value is the line above's).
          short_limit
          expect(described_class.call("sleep 31.65").lines.first).to eq("Error: command timed out after 0.2s\n")
        end
      end
    end

    # The kill at a real whole-second limit, end to end. A shell's echo, not
    # a ruby child: under a parallel run's load a ruby took over a second to
    # print "before"; a builtin echo is there in milliseconds.
    it "returns a timeout error past execute.timeout_sec, with the output captured before it" do
      ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"] = "1"

      result = described_class.call("echo before; echo oops >&2; sleep 31.66; echo never-printed", on_timeout: :kill)

      expect(result).to eq("Error: command timed out after 1s\n(killed at the limit; for a long command use task_create, then task_wait)\n" \
                           "stdout:\nbefore\n\nstderr:\noops\n")
      expect(result).to start_with(described_class::TIMEOUT_PREFIX)
    end

    # Tagged log lines for each command's life (turn tag): what ran how
    # long and how it ended, never its command line or output.
    describe "logging" do
      def logged
        lines = []
        %i[debug info].each do |level|
          allow(Samagotchi::Log).to receive(level).and_wrap_original do |original, tag, event, **fields|
            lines << [level, tag, event, fields] if event.start_with?("execute_")
            original.call(tag, event, **fields)
          end
        end
        lines
      end

      def secret_free?(lines) = lines.none? { |line| line.inspect.include?("s3cr3t") }

      it "logs a command's start and finish, with no output or command line" do
        lines = logged

        described_class.call("echo s3cr3t; exit 3")

        expect(lines.map { |level, tag, event, _| [level, tag, event] })
          .to eq([[:debug, :turn, "execute_started"], [:debug, :turn, "execute_finished"]])
        expect(lines.last.last).to include(exit: 3, ms: a_kind_of(Integer))
        expect(lines.first.last).to include(timeout_sec: a_kind_of(Integer), on_timeout: :task)
        expect(lines.map { |l| l.last[:id] }.uniq.size).to eq(1)
        expect(secret_free?(lines)).to be(true)
      end

      it "logs a command killed at the limit" do
        short_limit
        lines = logged

        described_class.call("echo s3cr3t; sleep 5", on_timeout: :kill)

        expect(lines.last.first(3)).to eq([:info, :turn, "execute_timed_out"])
        expect(lines.last.last).to include(after_sec: 0.2)
        expect(secret_free?(lines)).to be(true)
      end
    end

    describe "on Stop" do
      around do |example|
        Dir.mktmpdir do |dir|
          @ready = File.join(dir, "ready")
          example.run
        end
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # The Stop comes once the command touched @ready (it printed, it set
      # its trap): never before it got there, however slow the runner, and
      # no margin waited out on a fast one.
      def once_ready = -> { File.exist?(@ready) }

      # A grandchild killed with the group may take a moment to be reaped.
      def running?(pattern)
        deadline = now + 1
        sleep 0.05 while (alive = system("pgrep", "-f", pattern, out: File::NULL)) && now < deadline
        alive
      end

      it "kills the command, keeping its output so far" do
        started = now
        result = described_class.call("echo before; touch #{@ready}; sleep 31.71", cancelled: once_ready)

        expect(now - started).to be < 5
        # The seconds are wall-clock (0 locally, 1 on a slow runner): the shape only.
        expect(result).to match(/\AError: command stopped by the user after \d+s \(killed; rerun it if still needed\)\n/)
        expect(result).to include("stdout:\nbefore")
        expect(result).not_to include("exit:")
        expect(running?("sleep 31.71")).to be(false)
      end

      it "says a signal stopped it when the stop's reason is :signal (the worker got TERM/HUP/INT)" do
        result = described_class.call("echo before; touch #{@ready}; sleep 31.75", cancelled: once_ready, stop_reason: -> { :signal })

        expect(result).to match(/\A#{Regexp.escape(described_class::STOPPED_BY_SIGNAL)} after \d+s \(killed; rerun it if still needed\)\n/)
        expect(result).to include("stdout:\nbefore")
        expect(described_class.call("true", cancelled: -> { true }, stop_reason: -> { :signal })).to eq(described_class::NOT_RUN_ON_SIGNAL)
        expect(described_class.call("true", cancelled: -> { true }, stop_reason: -> { :manual })).to eq(described_class::NOT_RUN_ON_STOP)
        expect(running?("sleep 31.75")).to be(false)
      end

      it "says the session was stopped when the stop's reason is :session_stopped (chi sessions stop)" do
        result = described_class.call("echo before; touch #{@ready}; sleep 31.77", cancelled: once_ready,
                                                                                    stop_reason: -> { :session_stopped })

        expect(result).to match(/\A#{Regexp.escape(described_class::STOPPED_BY_SESSION_STOP)} after \d+s \(killed; rerun it if still needed\)\n/)
        expect(described_class.call("true", cancelled: -> { true }, stop_reason: -> { :session_stopped }))
          .to eq(described_class::NOT_RUN_ON_SESSION_STOP)
        expect(running?("sleep 31.77")).to be(false)
      end

      it "the builtin execute and task_create take the reason from the turn's peers" do
        registry = Samagotchi::Tools::Builtins.registry
        peers = Samagotchi::Tools::Peers.new(session_id: "s1", cancelled: true, cancel_reason: :signal)
        kctx = Struct.new(:peers).new(peers)

        expect(registry["execute"].handler.call({ content: "true" }, kctx)).to eq(described_class::NOT_RUN_ON_SIGNAL)
        expect(registry["task_create"].handler.call({ content: "true" }, kctx)).to eq(described_class::NOT_RUN_ON_SIGNAL)
      end

      it "doesn't start a command once the turn is stopped" do
        Dir.mktmpdir do |dir|
          marker = File.join(dir, "ran")
          result = described_class.call("touch #{marker}", cancelled: -> { true })

          expect(result).to eq("Error: not run, the user stopped the turn")
          expect(File.exist?(marker)).to be(false)
        end
      end

      it "kills the command on an Interrupt mid-wait instead of hanging on its output" do
        started = now
        interrupt = -> { File.exist?(@ready) ? raise(Interrupt) : false }

        expect { described_class.call("touch #{@ready}; sleep 31.72", cancelled: interrupt) }.to raise_error(Interrupt)
        expect(now - started).to be < 5
        expect(running?("sleep 31.72")).to be(false)
      end

      it "kills the whole group at the timeout, a grandchild the shell waits on too" do
        short_limit(0.5)

        result = described_class.call("sleep 31.73 & wait", on_timeout: :kill)

        expect(result).to start_with("Error: command timed out after 0.5s\n")
        expect(running?("sleep 31.73")).to be(false)
      end

      it "KILLs a group that ignores TERM once the grace is over" do
        stub_const("#{described_class}::STOP_GRACE_SEC", 0.2)
        started = now
        result = described_class.call("trap '' TERM; touch #{@ready}; sleep 31.74; echo never", cancelled: once_ready)

        expect(now - started).to be < 3
        expect(result).to start_with("Error: command stopped by the user")
        expect(running?("sleep 31.74")).to be(false)
      end

      # The shell dies on TERM, its child doesn't: it still holds the logs,
      # so the stop goes on to KILL it.
      it "KILLs a child that ignores TERM once its shell died on TERM, under Stop and at the limit (kill mode)" do
        stub_const("#{described_class}::STOP_GRACE_SEC", 0.2)
        stopped = described_class.call("perl -e '$SIG{TERM}=q(IGNORE); open(F, q(>#{@ready})); sleep 31.57'; echo after",
                                       cancelled: once_ready)
        short_limit(0.5)
        killed = described_class.call("perl -e '$SIG{TERM}=q(IGNORE); sleep 31.58'; echo after", on_timeout: :kill)

        expect(stopped).to start_with(described_class::STOPPED_BY_USER)
        expect(killed).to start_with("Error: command timed out after 0.5s")
        expect(running?("sleep 31.57")).to be(false)
        expect(running?("sleep 31.58")).to be(false)
      end
    end

    # `cmd &` forks a child that keeps the tool's stdout/stderr pipes: once
    # the shell exits, the readers wait a short grace, then the command's
    # process group is stopped and the output so far returned.
    describe "with a background process holding the output open" do
      # Short graces: these examples test what happens once a grace is over,
      # not how long it is (an example that needs a long one stubs its own).
      before do
        stub_const("#{described_class}::BACKGROUND_GRACE_SEC", 0.5)
        stub_const("#{described_class}::STOP_GRACE_SEC", 0.2)
        stub_const("Samagotchi::ProcessGroup::KILL_WAIT_SEC", 0.2)
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def pid_from(result)
        Integer(result[/^pid=(\d+)$/, 1])
      end

      # The orphan is reaped by init: give it a moment.
      def alive?(pid)
        deadline = now + 2
        loop do
          Process.kill(0, pid)
          return true if now > deadline

          sleep 0.05
        rescue Errno::ESRCH
          return false
        end
      end

      # Left running: the call has returned, so nothing of it stops the
      # process any more. Signalable and not a zombie (a killed orphan not
      # yet reaped still takes signal 0), checked once instead of #alive?'s
      # 2 s of polling.
      def running?(pid)
        Process.kill(0, pid)
        state, = Open3.capture2("ps", "-o", "stat=", "-p", pid.to_s)
        !state.strip.empty? && !state.strip.start_with?("Z")
      rescue Errno::ESRCH
        false
      end

      it "returns the output within the grace period, with the shell's exit status and a note" do
        started = now
        result = described_class.call("sleep 30.81 & echo pid=$!; echo hi")

        expect(now - started).to be < described_class::BACKGROUND_GRACE_SEC + 3
        expect(result).to include("stdout:\npid=")
        expect(result).to include("hi")
        expect(result).to end_with("exit: 0\n#{described_class::BACKGROUND_HINT}")
        expect(alive?(pid_from(result))).to be(false)
      end

      it "returns promptly when the user stops the turn during the grace period" do
        stub_const("#{described_class}::BACKGROUND_GRACE_SEC", 30)
        started = now
        result = described_class.call("sleep 30.82 & echo pid=$!; echo hi", cancelled: -> { now - started > 0.3 })

        expect(now - started).to be < 5
        expect(result).to match(/\AError: command stopped by the user after \d+s/)
        expect(result).to include("hi")
        expect(alive?(pid_from(result))).to be(false)
      end

      it "stops at execute.timeout_sec during the grace period" do
        stub_const("#{described_class}::BACKGROUND_GRACE_SEC", 30)
        short_limit(0.5)
        started = now
        result = described_class.call("sleep 30.83 & echo pid=$!")

        expect(now - started).to be < 5
        expect(result).to start_with("Error: command timed out after 0.5s\n")
        expect(alive?(pid_from(result))).to be(false)
      end

      it "leaves a fully redirected nohup process running and adds no note" do
        result = described_class.call("nohup sleep 30.84 >/dev/null 2>&1 </dev/null & echo pid=$!; echo hi")
        pid = pid_from(result)
        begin
          expect(result).to end_with("hi\n\nexit: 0")
          expect(running?(pid)).to be(true)
        ensure
          begin
            Process.kill("TERM", pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end

      # Seen live (macOS /bin/sh, bash 3.2): the `cd && nohup …` list is
      # backgrounded as a subshell, and the subshell keeps the pipes although
      # nohup's own output is redirected. dash (Linux /bin/sh) and zsh (macOS,
      # Shell) exec the list's last command instead, so nothing holds the pipes
      # there and the server keeps running.
      it "ends a backgrounded `cd && nohup … > f 2>&1` list too, stopping the server" do
        Dir.mktmpdir do |dir|
          started = now
          result = described_class.call("cd #{dir} && nohup env X=1 sleep 30.86 > out 2>&1 & echo pid=$!; echo hi")
          begin
            expect(now - started).to be < described_class::BACKGROUND_GRACE_SEC + 3
            expect(result).to include("hi")
            if result.end_with?("exit: 0")
              # not held: only bash 3.2 (macOS /bin/sh) holds them
              expect(Samagotchi::Tools::Shell.program).not_to eq(["/bin/sh"]) if RUBY_PLATFORM.include?("darwin")
            else
              expect(result).to end_with("exit: 0\n#{described_class::BACKGROUND_HINT}")
              expect(alive?(pid_from(result))).to be(false)
              expect(system("pgrep", "-f", "sleep 30.86", out: File::NULL)).to be(false)
            end
          ensure
            system("pkill", "-f", "sleep 30.86", out: File::NULL, err: File::NULL)
          end
        end
      end

      it "says a holder that left the process group (setsid) was left running" do
        # The shell exits once perl has left the group (touched "ready"), so
        # the grace starts after it: a short one does. The stop's grace and
        # KILL wait run out in full on a holder out of its reach: short too.
        stub_const("#{described_class}::BACKGROUND_GRACE_SEC", 0.05)
        stub_const("#{described_class}::STOP_GRACE_SEC", 0.05)
        stub_const("Samagotchi::ProcessGroup::KILL_WAIT_SEC", 0.05)
        ready = File.join(Dir.mktmpdir, "ready")
        result = described_class.call("perl -MPOSIX -e 'POSIX::setsid(); open(F, q(>#{ready})); sleep 30.85' & echo pid=$!; " \
                                      "until [ -e #{ready} ]; do sleep 0.02; done; echo hi")
        pid = pid_from(result)
        begin
          expect(result).to include("hi")
          expect(result).to end_with("exit: 0\n#{described_class::BACKGROUND_DETACHED_HINT}")
          expect(running?(pid)).to be(true)
          # Its logs stay for it to write to; the sweep takes them once it is gone.
          held = Dir.glob(File.join(described_class.logs_root, "*")).select { |dir| described_class.held?(Dir.glob(File.join(dir, "*.log"))) }
          expect(held.size).to eq(1)
        ensure
          FileUtils.rm_rf(File.dirname(ready))
          begin
            Process.kill("KILL", pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end

      it "keeps a normal command's output and exit status unchanged" do
        result = described_class.call("echo one; echo two >&2; exit 3")
        expect(result).to eq("stdout:\none\n\nstderr:\ntwo\n\nexit: 3")
      end
    end

    describe "logs" do
      it "keeps no dir under the state dir once a command has finished, and reads a big log by its head and tail" do
        ENV["SAMAGOTCHI_EXECUTE_TRUNCATE_AT_BYTES"] = "1000"
        ENV["SAMAGOTCHI_EXECUTE_PREVIEW_BYTES"] = "100"
        before = Dir.exist?(described_class.logs_root) ? Dir.children(described_class.logs_root) : []
        result = described_class.call("ruby -e 'print \"h\" * 50, \"x\" * 5_000_000, \"t\" * 50'")

        expect(result).to include("stdout:\ntruncated=true", "stdout_bytes=5000100", "#{"h" * 50}\n[... omitted",
                                  "[TRUNCATED_PREVIEW_TAIL]\n#{"t" * 50}")
        expect(Dir.children(described_class.logs_root)).to match_array(before)
      end

      it "keeps a write through /dev/stdout or /dev/stderr after the earlier output" do
        # Known gap (plan §7): Linux reopens /dev/stdout (/proc/self/fd/1) as
        # the log file itself, and `>` opens it with O_TRUNC, so the earlier
        # output is gone. macOS dups the descriptor. The fix is a relay pipe.
        skip "Linux: >/dev/stdout reopens the log file with O_TRUNC (known gap)" if RUBY_PLATFORM.include?("linux")

        expect(described_class.call("echo a; echo b >/dev/stdout")).to eq("stdout:\na\nb\n\nexit: 0")
        expect(described_class.call("echo a >&2; echo b >/dev/stderr")).to eq("stderr:\na\nb\n\nexit: 0")
      end

      it "reports what the command ran, whatever its last line or its exit path" do
        expect(described_class.call("echo a \\")).to eq("stdout:\na\n\nexit: 0")
        expect(described_class.call("echo a |")).to match(/\Astderr:\n.+\n\nexit: [12]\z/m)
        expect(described_class.call("echo x; exit 3")).to eq("stdout:\nx\n\nexit: 3")
        expect(described_class.call("set -e; false; echo no")).to eq("exit: 1 (no output)")
      end

      it "leaves no dir behind when the spawn fails" do
        before = Dir.exist?(described_class.logs_root) ? Dir.children(described_class.logs_root) : []
        allow(Samagotchi::ProcessGroup).to receive(:spawn).and_raise(Errno::EAGAIN)

        expect(described_class.call("true")).to start_with("Error: ")
        expect(Dir.children(described_class.logs_root)).to match_array(before)
      end

      it "gives the command /dev/null for stdin: a read gets EOF at once" do
        expect(described_class.call("read x; echo got=$x")).to eq("stdout:\ngot=\n\nexit: 0")
      end
    end

    describe "at the limit, handed over as a task (on_timeout: task)" do
      around do |example|
        Dir.mktmpdir do |dir|
          Dir.chdir(dir) do
            example.run
          ensure
            # Every task an example handed over, stopped through its record
            # (which checks the pid still is the group chi started).
            Samagotchi::Tools::TaskRuntime.list_records.each do |record|
              Samagotchi::Tools::TaskRuntime.stop_task(record.id, by: "model")
            end
            # Then chi's exit-status recorders (TaskRuntime.record_exit_status),
            # which may still write exit_code or the record into dir.
            Thread.list.select { |t| t.name == Samagotchi::Tools::TaskRuntime::EXIT_STATUS_THREAD }.each { |t| t.join(5) }
          end
        end
      end

      # task_wait looks more often: how often it looks, never what it decides.
      before { stub_const("Samagotchi::Tools::TaskWait::POLL_INTERVAL", 0.05) }

      def task_id(result) = result[/^task_id: (\S+)$/, 1]

      # A command that runs until the example touches +path+: still running
      # at any limit however slow the runner, and done as soon as told.
      def until_touched(path) = "until [ -e #{path} ]; do sleep 0.02; done"

      it "is the default: the command runs on as a task with its logs in the state dir, and finishes there" do
        ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"] = "1"
        command = "echo before; echo oops >&2; #{until_touched("go")}; echo done"

        result = described_class.call(command)
        id = task_id(result)

        expect(result).to eq("#{described_class.handed_over_line(1)}\ntask_id: #{id}\n" \
                             "Wait for it with task_wait (it may take minutes); task_stop stops it.\n" \
                             "stdout (so far, tail):\nbefore\nstderr (so far, tail):\noops")
        expect(Samagotchi::Tools::TaskRuntime.handed_over_id("[execute]\n#{result}")).to eq(id)
        record, = Samagotchi::Tools::TaskRuntime.get_record(id)
        dir = File.join(described_class.logs_root, id)
        expect(record).to have_attributes(status: "running", command: command,
                                          output_path: File.join(dir, "stdout.log"), stderr_path: File.join(dir, "stderr.log"),
                                          exit_code_path: File.join(dir, "exit_code"), handed_over_by: "execute")
        expect(File.read(File.join(dir, "task"))).to eq(File.expand_path(Samagotchi::Tools::TaskRuntime.metadata_path(id)))

        FileUtils.touch("go")
        waited = Samagotchi::Tools::TaskWait.call(id, timeout: 10)
        expect(waited).to include("status: completed", "exit_code: 0")
        expect(File.read(record.output_path)).to eq("before\ndone\n")
      end

      # perl's setpgrp stands in for GNU timeout's setpgid (no coreutils
      # needed), and starts in milliseconds: it has left the group well
      # before the limit or the Stop.
      it "is fully stopped by task_stop, a descendant that left the group (a `timeout N cmd`) too" do
        short_limit(0.5)

        result = described_class.call("cd . && perl -e 'setpgrp(0, 0); sleep 31.61'; echo after")
        stopped = Samagotchi::Tools::TaskStop.call(task_id(result))

        expect(stopped).to include("status: stopped")
        expect(running?("sleep 31.61")).to be(false)
      end

      # A relative XDG_STATE_HOME used to give relative log and exit_code
      # paths: adopt refused them, so the command was killed at the limit.
      it "hands over a command run in another cwd under a relative XDG_STATE_HOME, its paths absolute" do
        short_limit
        FileUtils.mkdir_p("sub")

        go = File.join(Dir.pwd, "go")
        result = with_env("XDG_STATE_HOME" => "rel-state") { described_class.call("echo before; #{until_touched(go)}", cwd: "sub") }

        expect(result).to start_with("#{described_class.handed_over_line(0.2)}\ntask_id: ")
        record, = Samagotchi::Tools::TaskRuntime.get_record(task_id(result))
        expect(record.exit_code_path).to eq(File.join(Dir.pwd, "rel-state", "samagotchi", "execute", record.id, "exit_code"))
        FileUtils.touch(go)
        expect(Samagotchi::Tools::TaskWait.call(record.id, timeout: 10)).to include("status: completed", "exit_code: 0")
      end

      it "logs the hand-over" do
        short_limit
        lines = []
        allow(Samagotchi::Log).to receive(:info).and_wrap_original do |original, tag, event, **fields|
          lines << [tag, event, fields] if event.start_with?("execute_")
          original.call(tag, event, **fields)
        end

        id = task_id(described_class.call("echo s3cr3t; sleep 3"))

        expect(lines).to eq([[:turn, "execute_handed_over", { id: id, after_sec: 0.2 }]])
      end

      it "reads a command that ended between the deadline and the hand-over as finished, not timed out" do
        short_limit
        allow(described_class).to receive(:hand_over).and_wrap_original do |original, task, **args|
          FileUtils.touch("go")
          args[:waiter].join(5)
          original.call(task, **args)
        end

        expect(described_class.call("echo hi; #{until_touched("go")}")).to eq("stdout:\nhi\n\nexit: 0")
        expect(Samagotchi::Tools::TaskRuntime.list_records).to eq([])
      end

      it "ends a handed-over command that replaced the EXIT trap with its own code, from the waiter" do
        short_limit

        result = described_class.call("trap 'echo mine' EXIT; #{until_touched("go")}; exit 4")
        record, = Samagotchi::Tools::TaskRuntime.get_record(task_id(result))
        FileUtils.touch("go")
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        sleep 0.05 until File.exist?(record.exit_code_path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        expect(Samagotchi::Tools::TaskWait.call(task_id(result), timeout: 10)).to include("status: failed", "exit_code: 4")
      end

      it "kills a command it can't hand over, as on_timeout: kill does" do
        short_limit(0.5)
        allow(Samagotchi::Tools::TaskRuntime).to receive(:adopt).and_return([nil, "Error: disk full"])

        result = described_class.call("echo before; sleep 31.62")

        expect(result).to start_with("Error: command timed out after 0.5s\n")
        expect(result).to include("stdout:\nbefore")
        expect(running?("sleep 31.62")).to be(false)
        expect(Samagotchi::Tools::TaskRuntime.list_records).to eq([])
      end

      it "kills at the limit with on_timeout: kill (the kwarg wins over the config)" do
        short_limit
        ENV["SAMAGOTCHI_EXECUTE_ON_TIMEOUT"] = "task"

        expect(described_class.call("sleep 31.63", on_timeout: :kill)).to start_with("Error: command timed out after 0.2s")
        expect(Samagotchi::Tools::TaskRuntime.list_records).to eq([])
      ensure
        ENV.delete("SAMAGOTCHI_EXECUTE_ON_TIMEOUT")
      end

      it "defaults execute.on_timeout to task" do
        expect(Samagotchi::Config::ENTRIES.find { |e| e.key == "execute.on_timeout" }).to have_attributes(default: "task", enum_values: %w[task kill])
      end

      it "kills a command whose user Stop came first, a descendant that left the group too" do
        # The Stop once perl has left the group (touched "ready").
        result = described_class.call("cd . && perl -e 'setpgrp(0, 0); open(F, q(>ready)); sleep 31.64'; echo after",
                                      cancelled: -> { File.exist?("ready") })

        expect(result).to start_with(described_class::STOPPED_BY_USER)
        expect(running?("sleep 31.64")).to be(false)
      end

      def running?(pattern)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        sleep 0.05 while (alive = system("pgrep", "-f", pattern, out: File::NULL)) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        alive
      end
    end

    describe ".sweep_leftovers" do
      let(:root) { Dir.mktmpdir }

      before { allow(described_class).to receive(:logs_root).and_return(root) }
      after { FileUtils.rm_rf(root) }

      def make_dir(name, age:, pointer: nil)
        dir = File.join(root, name)
        FileUtils.mkdir_p(dir)
        %w[stdout.log stderr.log].each { |log| File.write(File.join(dir, log), "x") }
        File.write(File.join(dir, "task"), pointer) if pointer
        time = Time.now - age
        [dir, *Dir.children(dir).map { |c| File.join(dir, c) }].each { |path| File.utime(time, time, path) }
        dir
      end

      it "removes a dir with no back-pointer after a day, one whose record is gone, and one past retention" do
        record = Tempfile.new("task.json")
        day = 24 * 3600
        fresh = make_dir("fresh", age: 60)
        crashed = make_dir("crashed", age: day + 60)
        gone = make_dir("gone", age: 60, pointer: "/nowhere/task.json")
        kept = make_dir("kept", age: 2 * day, pointer: record.path)
        old = make_dir("old", age: 15 * day, pointer: record.path)

        expect(described_class.sweep_leftovers).to contain_exactly(crashed, gone, old)
        expect([fresh, kept].all? { |dir| Dir.exist?(dir) }).to be(true)
      ensure
        record&.close!
      end

      it "keeps a dir whose logs a process still holds open" do
        dir = make_dir("held", age: 30 * 24 * 3600)
        holder = File.open(File.join(dir, "stdout.log"), "a") # rubocop:disable Style/FileOpen -- closed in the ensure
        holder.flock(File::LOCK_SH)

        expect(described_class.sweep_leftovers).to eq([])
        expect(Dir.exist?(dir)).to be(true)
      ensure
        holder&.close
      end
    end
  end
end
