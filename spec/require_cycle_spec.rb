# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"

RSpec.describe "loading session_manager and terminal_ui" do
  lib = File.expand_path("../lib", __dir__)

  { "samagotchi/session_manager" => "Samagotchi::SessionManager",
    "samagotchi/terminal_ui" => "Samagotchi::TerminalUI" }.each do |file, constant|
    it "loads #{file} on its own with no circular require warning" do
      _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e",
                                         "require '#{file}'; #{constant}")

      expect(status).to be_success, err
      expect(err).not_to include("circular require")
    end
  end

  it "does not load TerminalUI or Reline when a worker starts" do
    script = 'require "samagotchi/session_manager"; Samagotchi::Worker.name; ' \
             'require "samagotchi/bridge"; abort "reline" if defined?(Reline); ' \
             'abort "tui" if defined?(Samagotchi::TerminalUI)'

    _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", script)

    expect(status).to be_success, err
  end

  # A file declaring `autoload :SessionManager` that loads while
  # SessionManager autoloads (one a part requires, after the facade's class
  # exists) re-declares it and drops the half-built class: the parts then
  # build another, without the facade's methods.
  %w[samagotchi/terminal_ui samagotchi/child_move].each do |file|
    it "autoloads SessionManager from #{file} whole: the facade's methods and its parts'" do
      script = "require '#{file}'; sm = Samagotchi::SessionManager; " \
               'abort "partial" unless sm.respond_to?(:session_owner) && sm.respond_to?(:delete_session)'
      _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", script)

      expect(status).to be_success, err
    end
  end

  # bin/chi's subcommands: each loads alone (BundleCommand keeps TerminalUI
  # lazy, so the check above doesn't fit them).
  { "samagotchi/sessions_command" => "Samagotchi::SessionsCommand",
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
