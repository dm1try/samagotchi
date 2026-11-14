# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"
require "spec_helper"

RSpec.describe "loading session_manager and terminal_ui" do
  lib = File.expand_path("../lib", __dir__)

  { "samagotchi/session_manager" => "Samagotchi::SessionManager",
    "samagotchi/worker_boot" => "Samagotchi::WorkerBoot",
    "samagotchi/terminal_ui" => "Samagotchi::TerminalUI" }.each do |file, constant|
    it "loads #{file} on its own with no circular require warning" do
      _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e",
                                         "require '#{file}'; #{constant}")

      expect(status).to be_success, err
      expect(err).not_to include("circular require")
    end
  end

  # A part reads, in its class body, only what it requires itself.
  Dir[File.join(lib, "samagotchi", "session_manager", "*.rb")].sort.each do |path|
    file = path.delete_prefix("#{lib}/").delete_suffix(".rb")
    it "loads the part #{file} alone, with no warning from lib" do
      _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", "require '#{file}'")

      expect(status).to be_success, err
      expect(err).not_to include("circular require")
      expect(err.lines.grep(%r{/lib/samagotchi/.*warning:})).to be_empty
    end
  end

  it "has no load path from samagotchi/session_manager into the worker" do
    script = 'require "samagotchi/session_manager"; abort "worker" if defined?(Samagotchi::Worker); ' \
             'loaded = $LOADED_FEATURES.grep(%r{/samagotchi/(worker|bridge)\.rb\z}); ' \
             "abort loaded.inspect unless loaded.empty?"
    _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", script)

    expect(status).to be_success, err
  end

  it "does not load TerminalUI or Reline when a worker starts" do
    script = 'require "samagotchi/worker_boot"; Samagotchi::WorkerBoot.name; ' \
             'require "samagotchi/worker"; Samagotchi::Worker.name; ' \
             'require "samagotchi/bridge"; abort "reline" if defined?(Reline); ' \
             'abort "tui" if defined?(Samagotchi::TerminalUI)'

    _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", script)

    expect(status).to be_success, err
  end

  # bin/chi requires what each branch uses, not the umbrella samagotchi.rb:
  # a command that runs no turn loads no engine and no Reline. The prelude
  # writes $LOADED_FEATURES as bin/chi exits.
  describe "bin/chi's commands that run no turn" do
    around do |example|
      Dir.mktmpdir("chi-loads-") do |dir|
        @dir = dir
        example.run
      end
    end

    def loaded_by(*args)
      prelude = File.join(@dir, "loaded_prelude.rb")
      list = File.join(@dir, "loaded.txt")
      File.write(prelude, "at_exit { File.write(#{list.inspect}, $LOADED_FEATURES.join(\"\\n\")) }\n")
      env = isolated_chi_env(@dir, "RUBYOPT" => [ENV.fetch("RUBYOPT", nil), "-r#{prelude}"].compact.join(" "))
      _out, err, status = ChiCli.capture(*args, env: env)
      expect(status).to be_success, err
      File.read(list).lines(chomp: true)
    end

    [%w[--version], %w[home], %w[sessions list], %w[schedule list]].each do |args|
      it "loads no engine and no Reline for chi #{args.join(" ")}" do
        loaded = loaded_by(*args)

        expect(loaded.grep(%r{/lib/samagotchi\.rb\z})).to be_empty
        expect(loaded.grep(%r{/samagotchi/engine\.rb\z})).to be_empty
        expect(loaded.grep(/reline/)).to be_empty
      end
    end
  end

  # A file declaring `autoload :SessionManager` that loads while
  # SessionManager autoloads, after the facade's class exists (one a part
  # required), re-declares it and drops the half-built class: the parts then
  # build another, without the facade's methods. Each such file, as an entry
  # point, autoloads SessionManager whole.
  autoloaders = Dir[File.join(lib, "samagotchi", "**", "*.rb")].sort.select do |path|
    File.read(path).match?(/^\s*autoload :SessionManager\b/)
  end

  it "finds the files that autoload SessionManager" do
    expect(autoloaders.size).to be > 10
  end

  autoloaders.each do |path|
    file = path.delete_prefix("#{lib}/").delete_suffix(".rb")
    it "autoloads SessionManager from #{file} whole: the facade's methods and its parts'" do
      script = "require '#{file}'; sm = Samagotchi::SessionManager; " \
               'abort "partial" unless %i[session_owner refuse_tui! worker_command].all? { |m| sm.respond_to?(m) }'
      _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", script)

      expect(status).to be_success, err
      expect(err).not_to include("circular require")
      expect(err.lines.grep(%r{/lib/samagotchi/.*warning:})).to be_empty
    end
  end

  it "has no part require, at its top level, a file that autoloads SessionManager" do
    offenders = Dir[File.join(lib, "samagotchi", "session_manager", "*.rb")].flat_map do |part|
      File.readlines(part).filter_map do |line|
        name = line[/\Arequire_relative ["']([^"']+)["']/, 1]
        target = name && "#{File.expand_path(name, File.dirname(part))}.rb"
        name ||= line[%r{\Arequire ["'](samagotchi/[^"']+)["']}, 1]
        target ||= name && File.join(lib, "#{name}.rb")
        "#{File.basename(part)} -> #{name}" if target && autoloaders.include?(target)
      end
    end
    expect(offenders).to be_empty
  end

  # bin/chi's subcommands: each loads alone (BundleCommand keeps TerminalUI
  # lazy, so the check above doesn't fit them).
  { "samagotchi/sessions_command" => "Samagotchi::SessionsCommand",
    # A leaf: the row every listing builds, never session_manager or web.
    "samagotchi/session_row" => "Samagotchi::SessionRow",
    # A leaf: a session's paths and id rule (Paths only), never Session.
    "samagotchi/session_paths" => "Samagotchi::SessionPaths",
    # A leaf: one session file key's row (Session::FIELDS), never Session.
    "samagotchi/session_field" => "Samagotchi::SessionField",
    "samagotchi/bundle_command" => "Samagotchi::BundleCommand" }.each do |file, constant|
    it "loads #{file} on its own with no warning from lib" do
      _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", "require '#{file}'; p #{constant}")

      expect(status).to be_success, err
      expect(err).not_to include("circular require")
      expect(err.lines.grep(%r{/lib/samagotchi/.*warning:})).to be_empty
    end
  end

  # A file that names a helper module requires it: loaded alone, its
  # methods run (not just its constant resolves).
  it "loads samagotchi/session_participants on its own: name_for reaches Steer" do
    script = 'require "samagotchi/session_participants"; ' \
             'abort "named" unless Samagotchi::SessionParticipants.new(state_dir: -> { "/nonexistent" }).name_for("owner").nil?'
    _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", script)

    expect(status).to be_success, err
  end
end
