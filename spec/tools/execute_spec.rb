# frozen_string_literal: true

require "samagotchi/tools/execute"
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

  describe ".name" do
    it "is 'execute'" do
      expect(described_class.name).to eq("execute")
    end
  end

  describe ".call" do
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

    it "returns a timeout error when command exceeds configured timeout" do
      ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"] = "1"

      result = described_class.call("ruby -e 'sleep 5'")

      expect(result).to eq("Error: command timed out after 1s\n(killed at the limit; for a long command use task_create, then task_wait)")
    end

    it "gives a command 120 s by default, the same as the config default" do
      ENV.delete("SAMAGOTCHI_EXECUTE_TIMEOUT_SEC")
      Dir.mktmpdir do |dir|
        with_env("XDG_CONFIG_HOME" => dir) do
          expect(described_class.send(:timeout_seconds)).to eq(120)
        end
      end
      expect(Samagotchi::Config::ENTRIES.find { |e| e.key == "execute.timeout_sec" }.default).to eq(described_class::TIMEOUT_SEC)
    end

    it "takes the timeout from config.yml's execute.timeout_sec" do
      ENV.delete("SAMAGOTCHI_EXECUTE_TIMEOUT_SEC")
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "samagotchi"))
        File.write(File.join(dir, "samagotchi", "config.yml"), "default:\n  model: m\nexecute:\n  timeout_sec: 1\n")
        with_env("XDG_CONFIG_HOME" => dir) do
          expect(Samagotchi::Config.validate_yaml_sections(Samagotchi::ConfigFile.read_yaml)).to eq([])
          expect(described_class.call("ruby -e 'sleep 5'").lines.first).to eq("Error: command timed out after 1s\n")
        end
      end
    end

    # A shell's echo, not a ruby child, and a few seconds: under a parallel
    # run's load a ruby took over a second to print "before".
    it "returns the output captured before the timeout along with the error" do
      ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"] = "3"

      result = described_class.call("echo before; echo oops >&2; sleep 10; echo never-printed")

      expect(result).to start_with("Error: command timed out after 3s\n(killed at the limit; for a long command use task_create, then task_wait)\n")
      expect(result).to include("stdout:\nbefore")
      expect(result).to include("stderr:\noops")
      expect(result).not_to include("never-printed")
      expect(result).not_to include("exit:")
    end

    describe "on Stop" do
      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # A grandchild killed with the group may take a moment to be reaped.
      def running?(pattern)
        deadline = now + 1
        sleep 0.05 while (alive = system("pgrep", "-f", pattern, out: File::NULL)) && now < deadline
        alive
      end

      it "kills the command, keeping its output so far" do
        started = now
        result = described_class.call("echo before; sleep 31.71", cancelled: -> { now - started > 0.3 })

        expect(now - started).to be < 5
        # The seconds are wall-clock (0 locally, 1 on a slow runner): the shape only.
        expect(result).to match(/\AError: command stopped by the user after \d+s \(killed; rerun it if still needed\)\n/)
        expect(result).to include("stdout:\nbefore")
        expect(result).not_to include("exit:")
        expect(running?("sleep 31.71")).to be(false)
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
        interrupt = -> { now - started > 0.3 ? raise(Interrupt) : false }

        expect { described_class.call("sleep 31.72", cancelled: interrupt) }.to raise_error(Interrupt)
        expect(now - started).to be < 5
        expect(running?("sleep 31.72")).to be(false)
      end
    end

    # `cmd &` forks a child that keeps the tool's stdout/stderr pipes: once
    # the shell exits, the readers wait a short grace, then the command's
    # process group is stopped and the output so far returned.
    describe "with a background process holding the output open" do
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
        ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"] = "1"
        started = now
        result = described_class.call("sleep 30.83 & echo pid=$!")

        expect(now - started).to be < 5
        expect(result).to start_with("Error: command timed out after 1s\n")
        expect(alive?(pid_from(result))).to be(false)
      end

      it "leaves a fully redirected nohup process running and adds no note" do
        result = described_class.call("nohup sleep 30.84 >/dev/null 2>&1 </dev/null & echo pid=$!; echo hi")
        pid = pid_from(result)
        begin
          expect(result).to end_with("hi\n\nexit: 0")
          expect(alive?(pid)).to be(true)
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
        result = described_class.call('ruby -e "Process.setsid; sleep 30.85" & echo pid=$!; echo hi')
        pid = pid_from(result)
        begin
          expect(result).to include("hi")
          expect(result).to end_with("exit: 0\n#{described_class::BACKGROUND_DETACHED_HINT}")
          expect(alive?(pid)).to be(true)
        ensure
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

    it "keeps partial output from a compound command whose last part hangs" do
      ENV["SAMAGOTCHI_EXECUTE_TIMEOUT_SEC"] = "3"

      result = described_class.call("echo first-part; sleep 10")

      expect(result).to start_with("Error: command timed out after 3s")
      expect(result).to include("first-part")
    end
  end
end
