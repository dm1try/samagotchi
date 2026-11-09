# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

  describe ".spawn_session" do
    describe "the worker's debug log" do
      def spawned_env
        env = nil
        allow(Process).to receive(:spawn) do |*args, **_opts|
          env = args.first if args.first.is_a?(Hash)
          12_345
        end
        described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", working_directory: tmpdir, state_dir: tmpdir)
        env
      end

      after { Samagotchi::Config.reload!(cli_overrides: {}) }

      it "is the spawner's log.file, made absolute against the spawner's directory" do
        Samagotchi::Config.reload!(cli_overrides: { "log.file" => "logs/chi.log" })

        # In tmpdir: the spawn itself is logged there.
        Dir.chdir(tmpdir) do
          expect(spawned_env).to include("SAMAGOTCHI_LOG_FILE" => File.join(Dir.pwd, "logs", "chi.log"))
        end
      end

      it "is disabled when the spawner's log is" do
        Samagotchi::Config.reload!(cli_overrides: { "log.disable" => true })

        expect(spawned_env).to include("SAMAGOTCHI_LOG_DISABLE" => "true")
        expect(spawned_env).not_to have_key("SAMAGOTCHI_LOG_FILE")
      end

      it "passes on a --log-level flag" do
        Samagotchi::Config.reload!(cli_overrides: { "log.level" => "debug" })

        expect(spawned_env).to include("SAMAGOTCHI_LOG_LEVEL" => "debug")
      end

      # The worker reads config.yml itself when it starts: an edit made
      # after this process loaded the file reaches it, with origin :file.
      it "leaves config.yml's settings out of the worker's env" do
        Dir.mktmpdir("chi-config") do |dir|
          FileUtils.mkdir_p(File.join(dir, "samagotchi"))
          File.write(File.join(dir, "samagotchi", "config.yml"),
                     "default:\n  model: gemma4\nlog:\n  level: warn\nsession:\n  idle_exit_minutes: 3\nthinking:\n  level: low\n")
          stub_const("ENV", ENV.to_h.merge("XDG_CONFIG_HOME" => dir))

          env = spawned_env
          expect(env.keys).not_to include("SAMAGOTCHI_LOG_LEVEL", "SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES",
                                          "SAMAGOTCHI_DEFAULT_MODEL", "SAMAGOTCHI_THINKING_LEVEL")
        end
      end
    end

    # The worker starts in the session's directory: a relative XDG dir
    # would be read from there, not from the spawner's directory.
    it "hands the worker the spawner's XDG_STATE_HOME and XDG_CONFIG_HOME, made absolute" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |*args, **_opts|
        spawned_env = args.first if args.first.is_a?(Hash)
        12_345
      end

      Dir.chdir(tmpdir) do
        FileUtils.mkdir_p(File.join("rel-config", "samagotchi"))
        FileUtils.cp(File.join(SPEC_XDG_CONFIG_HOME, "samagotchi", "config.yml"), File.join("rel-config", "samagotchi"))
        stub_const("ENV", ENV.to_h.merge("XDG_STATE_HOME" => "rel-state", "XDG_CONFIG_HOME" => "rel-config"))

        described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

        expect(spawned_env).to include("XDG_STATE_HOME" => File.join(Dir.pwd, "rel-state"),
                                       "XDG_CONFIG_HOME" => File.join(Dir.pwd, "rel-config"))
      end
    end

    # The spawner's environment must not switch the worker's guardrails off
    # (a parent agent starting or waking a session).
    it "unsets every SAMAGOTCHI_GUARDRAILS_* variable for the worker" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |*args, **_opts|
        spawned_env = args.first if args.first.is_a?(Hash)
        12_345
      end
      stub_const("ENV", ENV.to_h.merge("SAMAGOTCHI_GUARDRAILS_ENABLED" => "false",
                                       "SAMAGOTCHI_GUARDRAILS_SMALL_MODELS" => "", "SAMAGOTCHI_GUARDRAILS_X" => "1"))

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("SAMAGOTCHI_GUARDRAILS_ENABLED" => nil, "SAMAGOTCHI_GUARDRAILS_SMALL_MODELS" => nil,
                                     "SAMAGOTCHI_GUARDRAILS_X" => nil)
    end

    # A chi send run by session A's execute starts session B: A's markers
    # are A's. B's execute and tasks set B's own; anything else B runs (a
    # user's !cmd, an MCP server, a context source's command) gets none,
    # so `!chi context add` there doesn't attach to A.
    it "unsets the session markers execute exports (SAMAGOTCHI_PARENT_SESSION, SAMAGOTCHI_SESSION_MODEL) for the worker" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |*args, **_opts|
        spawned_env = args.first if args.first.is_a?(Hash)
        12_345
      end
      stub_const("ENV", ENV.to_h.merge("SAMAGOTCHI_PARENT_SESSION" => "aaaaaaaa-0000-0000-0000-000000000000",
                                       "SAMAGOTCHI_SESSION_MODEL" => "main:outer", "SAMAGOTCHI_SESSION_THINKING" => "low",
                                       "SAMAGOTCHI_SESSION_REASONING_HISTORY" => "all"))

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("SAMAGOTCHI_PARENT_SESSION" => nil, "SAMAGOTCHI_SESSION_MODEL" => nil,
                                     "SAMAGOTCHI_SESSION_THINKING" => nil, "SAMAGOTCHI_SESSION_REASONING_HISTORY" => nil)
    end

    it "reaps the worker when it exits, so a long-lived spawner (chi web) keeps no zombies" do
      allow(Process).to receive(:spawn).and_return(12_345)
      # Still running (a starter that already exited is reaped at once).
      allow(Process).to receive(:waitpid).and_return(nil)
      allow(Process).to receive(:detach)

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(Process).to have_received(:detach).with(12_345)
    end

    it "keeps the spawner's SAMAGOTCHI_INSTALLED_VERSION seam from the worker" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |env, *_args, **_opts|
        spawned_env = env
        12_345
      end

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("SAMAGOTCHI_INSTALLED_VERSION" => nil)
    end

    it "undoes Bundler's env for a gem-mode worker, which activates the newest chi itself" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |env, *_args, **_opts|
        spawned_env = env
        12_345
      end
      allow(Samagotchi::InstalledGem).to receive(:spec)
        .and_return(Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "9.9.9" })
      stub_const("ENV", ENV.to_h.merge("RUBYOPT" => "-W0 -rbundler/setup", "BUNDLE_GEMFILE" => "/p/Gemfile"))
      allow(Bundler).to receive(:unbundled_env).and_return(ENV.to_h.merge("RUBYOPT" => "-W0").except("BUNDLE_GEMFILE"))

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("RUBYOPT" => "-W0", "BUNDLE_GEMFILE" => nil)
    end

    it "leaves Bundler's env to a source checkout's worker (bundle exec bin/chi)" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |env, *_args, **_opts|
        spawned_env = env
        12_345
      end
      stub_const("ENV", ENV.to_h.merge("BUNDLE_GEMFILE" => "/p/Gemfile"))

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).not_to have_key("BUNDLE_GEMFILE")
    end

    it "spawns worker with explicit require for session manager" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      allow(Samagotchi::Session).to receive(:new_session).and_return(session)
      spawned_args = nil
      allow(Process).to receive(:spawn) do |*args|
        spawned_args = args
        12_345
      end

      described_class.spawn_session(prompt: "hello", mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
      args_str = spawned_args.map(&:to_s).join(" ")
      expect(args_str).to include("require 'samagotchi/worker_boot'; Samagotchi::WorkerBoot.run_session_loop")
      expect(spawned_args).to include(RbConfig.ruby)
      expect(spawned_args).to include("-I")

      lib_path_index = spawned_args.index("-I") + 1
      expect(spawned_args[lib_path_index]).to end_with("/lib")
      expect(File.directory?(spawned_args[lib_path_index])).to be true
    end

    describe "the worker command" do
      let(:boot) { "require 'samagotchi/worker_boot'; Samagotchi::WorkerBoot.run_session_loop('abc', state_dir: \"/s\")" }

      it "is a plain -I lib from a source checkout (this suite runs from one, under Bundler's gemspec)" do
        expect(Samagotchi::InstalledGem.spec).to be_nil
        expect(described_class.worker_command("abc", state_dir: "/s"))
          .to eq([RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", boot])
      end

      it "activates the newest installed gem, falling back to the spawner's own version, without -I" do
        spec = Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "9.9.9" }
        command = described_class.worker_command("abc", state_dir: "/s", gem_spec: spec)
        expect(command).to eq([RbConfig.ruby, "-e",
                               "begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                               "ENV['SAMAGOTCHI_BOOT_FALLBACK'] = e.message; gem 'samagotchi', '= 9.9.9'; end; #{boot}"])
      end

      describe "with a chi home" do
        let(:home_dir) { Dir.mktmpdir("worker-home") }
        let(:home) do
          FileUtils.mkdir_p(File.join(home_dir, "specifications"))
          %w[9.9.9 10.0.0].each { |v| File.write(File.join(home_dir, "specifications", "samagotchi-#{v}.gemspec"), "") }
          Samagotchi::ChiHome::Record.new(ruby: "/home/bin/ruby", gem_home: home_dir, gem_path: home_dir, mise: nil,
                                          set_at: "t", set_by_version: "9.9.9")
        end
        let(:spec) { Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "9.9.9" } }

        after { FileUtils.remove_entry(home_dir) }

        it "boots the home's ruby with its Gem.paths, the newest chi there, the spawner's version as the fallback" do
          command = described_class.worker_command("abc", state_dir: "/s", gem_spec: spec, home: home)
          expect(command[0, 2]).to eq(["/home/bin/ruby", "-e"])
          expect(command.size).to eq(3)
          expect(command[2]).to start_with("#{home.prelude}; begin; begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                                           "ENV['SAMAGOTCHI_BOOT_FALLBACK'] = e.message; gem 'samagotchi', '= 9.9.9'; end; " \
                                           "require 'samagotchi/worker_boot'; rescue ScriptError, StandardError => e; ")
          expect(command[2]).to include("sid=abc boot_failed")
          expect(command[2]).to end_with("exit 1; end; Samagotchi::WorkerBoot.run_session_loop('abc', state_dir: \"/s\")")
          expect(RubyVM::InstructionSequence.compile(command[2])).to be_a(RubyVM::InstructionSequence)
        end

        it "warns once when the home's newest chi is older than the spawner's, and still boots the home" do
          Samagotchi::ChiHome.reset_warnings!
          allow(Samagotchi::Log).to receive(:warn)
          newer = Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "11.0.0" }
          2.times { expect(described_class.worker_command("abc", state_dir: "/s", gem_spec: newer, home: home).first).to eq("/home/bin/ruby") }
          expect(Samagotchi::Log).to have_received(:warn)
            .with(:config, "home_older_than_spawner", home: "10.0.0", spawner: "11.0.0").once
          described_class.worker_command("abc", state_dir: "/s", gem_spec: spec, home: home)
          expect(Samagotchi::Log).to have_received(:warn).once
        end

        it "falls back to the home's newest when the spawner's version isn't in the home" do
          other = Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "8.0.0" }
          command = described_class.worker_command("abc", state_dir: "/s", gem_spec: other, home: home)
          expect(command[2]).to include("gem 'samagotchi', '= 10.0.0'")
        end

        it "keeps the -I lib boot in a checkout" do
          expect(described_class.worker_command("abc", state_dir: "/s", gem_spec: nil, home: home))
            .to eq([RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", boot])
        end

        it "reads home.json at spawn time (none in the suite's config: today's boot)" do
          expect(described_class.worker_command("abc", state_dir: "/s", gem_spec: spec).first).to eq(RbConfig.ruby)
          Dir.mktmpdir do |config|
            with_config_home(config) do
              Samagotchi::ChiHome.write!(home.with(ruby: RbConfig.ruby))
              expect(described_class.worker_command("abc", state_dir: "/s", gem_spec: spec)[2]).to start_with("Gem.paths = ")
            end
          end
        end

        # A home whose chi can't load (a broken install): one line in the spawner's log, not a silent timeout.
        it "logs one line to SAMAGOTCHI_LOG_FILE and exits 1 when chi doesn't load in the home" do
          broken = home.with(ruby: RbConfig.ruby)
          FileUtils.rm_rf(File.join(home_dir, "specifications"))
          FileUtils.mkdir_p(File.join(home_dir, "specifications"))
          command = described_class.worker_command("abc", state_dir: "/s", gem_spec: spec,
                                                   home: broken)
          log = File.join(home_dir, "chi.log")
          # Outside this suite's bundle (RUBYOPT=-rbundler/setup would hand it this checkout), as a gem-mode spawn is.
          _out, status = Bundler.with_unbundled_env { Open3.capture2e({ "SAMAGOTCHI_LOG_FILE" => log }, *command) }
          expect(status.exitstatus).to eq(1)
          line = File.read(log)
          expect(line.lines.size).to eq(1)
          expect(line.chomp).to match(Samagotchi::LogLine::HEADER)
          expect(line).to include("ERROR worker", "sid=abc boot_failed", "Could not find 'samagotchi'")
        end
      end
    end

    it "starts the worker in its own process group, so a Ctrl-C on `chi web` does not reach it" do
      spawned_opts = nil
      spawned_env = nil
      allow(Process).to receive(:spawn) do |*args, **opts|
        spawned_env = args.first if args.first.is_a?(Hash)
        spawned_opts = opts
        12_345
      end

      described_class.spawn_session(prompt: "hello", mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_opts).to include(pgroup: true)
      # A worker process: it traps signals (WorkerBoot.run_session_loop).
      expect(spawned_env).to include(described_class::WORKER_PROCESS_ENV => "1", described_class::WORKER_DETACH_ENV => "1")
    end
  end

  describe "the worker's directory" do
    def spawned_opts
      opts = nil
      allow(Process).to receive(:spawn) do |*_args, **o|
        opts = o
        12_345
      end
      yield
      opts
    end

    it "writes the spawn to the log, with the session's sid and the worker's pid" do
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Config.reload!(cli_overrides: { "log.file" => log })
      session = nil
      spawned_opts { session = described_class.spawn_session(prompt: nil, model_name: "gemma4", working_directory: tmpdir, state_dir: tmpdir) }

      record = File.open(log) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.event == "spawn" } }
      expect(record.to_h).to include(level: "INFO", tag: "worker", sid: session.id[0, 8], fields: { "child_pid" => "12345" })
    ensure
      Samagotchi::Config.reload!(cli_overrides: {})
    end

    it "starts the worker in the session's directory, so its tools run there" do
      dir = Dir.mktmpdir("session-dir", tmpdir)

      opts = spawned_opts { described_class.spawn_session(prompt: nil, model_name: "gemma4", working_directory: dir, state_dir: tmpdir) }

      expect(opts).to include(chdir: dir)
    end

    it "falls back to the spawner's directory, with a log line, when the session's is gone" do
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Config.reload!(cli_overrides: { "log.file" => log })
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: File.join(tmpdir, "gone"))
      session.save(state_dir: tmpdir)

      opts = spawned_opts { described_class.resume_session(session.id, state_dir: tmpdir) }

      expect(opts).not_to have_key(:chdir)
      record = File.open(log) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.event == "cwd_gone" } }
      expect(record.to_h).to include(level: "WARN", tag: "worker", sid: session.id[0, 8])
      expect(record.fields).to eq("dir" => File.join(tmpdir, "gone"), "cwd" => Dir.pwd)
    ensure
      Samagotchi::Config.reload!(cli_overrides: {})
    end
  end
end
