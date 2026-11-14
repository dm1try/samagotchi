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

  it "is what SessionCommands reads: the same registry and constants" do
    require "samagotchi/session_commands"
    commands = Samagotchi::SessionCommands

    expect(commands.builtin_registry).to be(described_class.builtin_registry)
    expect(commands::SHELL_BANG_PREFIX).to eq(described_class::SHELL_BANG_PREFIX)
    expect(commands::CONTINUE_COMMAND).to eq(described_class::CONTINUE_COMMAND)
    expect(commands.builtin_name("/model x")).to eq("/model")
    expect(commands.delete_on_exit?("/exit --delete")).to be(true)
    expect(commands.ui_only_entry("/stats")&.name).to eq("/stats")
    expect(commands.ui_only_refusal("/exit", nil, runner: "chi send")).to eq(described_class.ui_only_refusal("/exit", nil, runner: "chi send"))
  end
end
