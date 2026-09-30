# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"

RSpec.describe "loading session_manager and terminal_ui" do
  lib = File.expand_path("../lib", __dir__)

  %w[samagotchi/session_manager samagotchi/terminal_ui].each do |file|
    it "loads #{file} on its own with no circular require warning" do
      _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e",
                                         "require '#{file}'; Samagotchi::SessionManager && Samagotchi::TerminalUI")

      expect(status).to be_success, err
      expect(err).not_to include("circular require")
    end
  end

  # bin/chi's subcommands: each loads alone (BundleCommand keeps TerminalUI
  # lazy, so the check above doesn't fit them).
  { "samagotchi/sessions_command" => "Samagotchi::SessionsCommand" }.each do |file, constant|
    it "loads #{file} on its own with no warning from lib" do
      _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", "require '#{file}'; p #{constant}")

      expect(status).to be_success, err
      expect(err).not_to include("circular require")
      expect(err.lines.grep(%r{/lib/samagotchi/.*warning:})).to be_empty
    end
  end
end
