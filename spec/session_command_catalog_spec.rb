# frozen_string_literal: true

require "open3"
require "rbconfig"
require "samagotchi/session_command_catalog"

RSpec.describe Samagotchi::SessionCommandCatalog do
  it "loads without the runner and its tools (what the attached TUI and chi web require)" do
    script = 'require "samagotchi/session_command_catalog"; ' \
             "Samagotchi::SessionCommandCatalog.builtin_registry; " \
             'abort "runner" if defined?(Samagotchi::SessionCommands); ' \
             'loaded = $LOADED_FEATURES.grep(%r{/samagotchi/tools/(execute|builtins|task_runtime)\.rb\z}); ' \
             'abort loaded.join(", ") unless loaded.empty?'
    _out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)

    expect(status).to be_success, err
  end

  it "is what SessionCommands reads: its constants, and no class methods of its own" do
    require "samagotchi/session_commands"
    commands = Samagotchi::SessionCommands

    expect(commands::SHELL_BANG_PREFIX).to eq(described_class::SHELL_BANG_PREFIX)
    expect(commands::CONTINUE_COMMAND).to eq(described_class::CONTINUE_COMMAND)
    # The class methods live in the catalogue alone: a caller names it.
    expect(commands).not_to respond_to(:builtin_registry)
  end
end
