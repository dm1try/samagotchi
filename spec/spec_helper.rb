# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
require "tmpdir"

# Start from none of the developer's SAMAGOTCHI_* settings: a shell may point
# the debug log somewhere, and a suite run by chi's own execute tool inherits
# the worker's environment (SAMAGOTCHI_HOSTS_JSON with the real hosts, the
# spawner's CLI flags such as SAMAGOTCHI_GUARDRAILS_ENABLED=false). Specs set
# what they need. The suite's own switches stay; :integration examples get
# the rest back, all but the log settings.
SPEC_ENV_SWITCHES = %w[SAMAGOTCHI_INTEGRATION SAMAGOTCHI_MACOS_BUILD].freeze
REAL_SAMAGOTCHI_ENV = ENV.to_h.select { |key, _| key.start_with?("SAMAGOTCHI_") && !SPEC_ENV_SWITCHES.include?(key) }
                         .reject { |key, _| key.start_with?("SAMAGOTCHI_LOG_") }.freeze
SPEC_ENV_CLEAR = -> { ENV.keys.each { |key| ENV.delete(key) if key.start_with?("SAMAGOTCHI_") && !SPEC_ENV_SWITCHES.include?(key) } }
SPEC_ENV_CLEAR.call

# Isolate specs from the developer's ~/.config/samagotchi/config.yml (hosts,
# memories, aliases...) with a minimal fixture config. Only :integration
# examples see the real config, so they can reach the live model server; unit
# specs stay isolated even under SAMAGOTCHI_INTEGRATION=1.
REAL_XDG_CONFIG_HOME = ENV["XDG_CONFIG_HOME"]
SPEC_XDG_CONFIG_HOME = Dir.mktmpdir("samagotchi-spec-config")
FileUtils.mkdir_p(File.join(SPEC_XDG_CONFIG_HOME, "samagotchi"))
File.write(File.join(SPEC_XDG_CONFIG_HOME, "samagotchi", "config.yml"), <<~YAML)
  default:
    model: spec-model
YAML
# The idle recap is on by default and would ask the model server: off for
# specs, whatever config dir a spec points at. Examples tagged :recap and
# :integration examples turn it back on.
ENV["SAMAGOTCHI_RECAP_ENABLED"] = "false"
ENV["XDG_CONFIG_HOME"] = SPEC_XDG_CONFIG_HOME
at_exit { FileUtils.remove_entry(SPEC_XDG_CONFIG_HOME) if File.directory?(SPEC_XDG_CONFIG_HOME) }

# Likewise keep sessions/*.json and history.json out of the developer's
# ~/.local/state/samagotchi. Unlike config, :integration examples stay here too.
SPEC_XDG_STATE_HOME = Dir.mktmpdir("samagotchi-spec-state")
ENV["XDG_STATE_HOME"] = SPEC_XDG_STATE_HOME
at_exit { FileUtils.remove_entry(SPEC_XDG_STATE_HOME) if File.directory?(SPEC_XDG_STATE_HOME) }

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random
  Kernel.srand config.seed

  # Never let a spec block on the developer's real terminal. Unstubbed Reline
  # reads behave like EOF (Ctrl-D); specs that need input stub their own values.
  config.before(:each) do
    if defined?(Reline)
      allow(Reline).to receive(:readmultiline).and_return(nil)
      allow(Reline).to receive(:readline).and_return(nil)
    end
    # ContextWindow remembers the last server-reported window process-wide.
    Samagotchi::ContextWindow.reset! if defined?(Samagotchi::ContextWindow)
    # The log facade is process-wide: unconfigured again, it resolves its
    # file from this example's config (the temp XDG_STATE_HOME by default).
    Samagotchi::Log.reset! if defined?(Samagotchi::Log)
    # ConfigFile prints each config warning once per process.
    Samagotchi::ConfigFile.reset_warnings! if defined?(Samagotchi::ConfigFile)
    # The REPL spinner's ticker thread draws until the spinner finishes, and
    # many specs start one they never finish: it would write into later
    # specs' output. Off by default; specs of the ticker pass an interval.
    stub_const("Samagotchi::TerminalUI::THINKING_TICK_INTERVAL", nil) if defined?(Samagotchi::TerminalUI::THINKING_TICK_INTERVAL)
    # The attached TUI's status ticker likewise (AttachedLoop builds its view
    # with the default interval).
    stub_const("Samagotchi::TerminalUI::AttachedView::TICK_INTERVAL", nil) if defined?(Samagotchi::TerminalUI::AttachedView::TICK_INTERVAL)
  end

  # Really compile the macOS desktop helper (swiftc, codesign): slow, and
  # needs the Command Line Tools. Own switch, not :integration's.
  # Examples that fail on Linux CI but pass on macOS; skipped under CI until
  # someone looks at them (docs/releasing.md, "Known CI gaps").
  config.before(:each, :ci_todo) do
    skip "Linux CI follow-up (:ci_todo)" if ENV["CI"]
  end

  config.around(:each, :macos_build) do |example|
    skip "Set SAMAGOTCHI_MACOS_BUILD=1 to compile the desktop helper" unless ENV["SAMAGOTCHI_MACOS_BUILD"] == "1"

    example.run
  end

  # Point :integration examples at the real config, then restore the fixture.
  # Config.store memoizes a snapshot, so drop it on both sides of the switch.
  # Skip here, before the switch: this config-level around wraps the group's
  # own around hooks and lets, so a skipped example runs none of its setup
  # (e.g. Engine.new installing the bundle into the real memories).
  config.around(:each, :integration) do |example|
    skip "Set SAMAGOTCHI_INTEGRATION=1 to run integration tests" unless ENV["SAMAGOTCHI_INTEGRATION"] == "1"

    ENV["XDG_CONFIG_HOME"] = REAL_XDG_CONFIG_HOME
    ENV.update(REAL_SAMAGOTCHI_ENV)
    ENV.delete("SAMAGOTCHI_RECAP_ENABLED")
    # The real config's log.file must never receive spec lines (workers
    # spawned here inherit it too).
    ENV["SAMAGOTCHI_LOG_DISABLE"] = "true"
    Samagotchi::Config.instance_variable_set(:@store, nil) if defined?(Samagotchi::Config)
    Samagotchi::Log.reset! if defined?(Samagotchi::Log)
    example.run
  ensure
    ENV["XDG_CONFIG_HOME"] = SPEC_XDG_CONFIG_HOME
    SPEC_ENV_CLEAR.call
    ENV["SAMAGOTCHI_RECAP_ENABLED"] = "false"
    Samagotchi::Config.instance_variable_set(:@store, nil) if defined?(Samagotchi::Config)
    Samagotchi::Log.reset! if defined?(Samagotchi::Log)
  end

  # Specs of the idle recap's own settings: recap as configured (on by
  # default), not the suite's SAMAGOTCHI_RECAP_ENABLED=false.
  config.around(:each, :recap) do |example|
    ENV.delete("SAMAGOTCHI_RECAP_ENABLED")
    Samagotchi::Config.instance_variable_set(:@store, nil) if defined?(Samagotchi::Config)
    example.run
  ensure
    ENV["SAMAGOTCHI_RECAP_ENABLED"] = "false"
    Samagotchi::Config.instance_variable_set(:@store, nil) if defined?(Samagotchi::Config)
  end

end
