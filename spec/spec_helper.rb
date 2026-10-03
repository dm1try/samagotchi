# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
require "tmpdir"

# No spec reaches the network, localhost included: an unstubbed request
# raises WebMock::NetConnectNotAllowedError. Loaded here, not by the one spec
# that stubs requests, or the run depends on whether that spec's file loaded
# first in a parallel_rspec process (a default Client probing
# localhost:8080/props, SelfReport asking 127.0.0.1:4567/api/info). Specs
# that serve real local HTTP opt out per example
# (FakeProviderServer.without_webmock).
require "webmock/rspec"
WebMock.disable_net_connect!

# The suite-wide helpers (each example group gets them below). Not every
# spec/support file: the rest load parts of lib/ (a fake adapter, a
# surface), and a spec that needs one requires it, so loading one spec file
# alone still finds its missing requires.
require_relative "support/waiting"
require_relative "support/env"
require_relative "support/chi_cli"
# Reads SAMAGOTCHI_INTEGRATION_* now, before the clear below.
require_relative "support/integration_server"

# Start from none of the developer's SAMAGOTCHI_* settings: a shell may point
# the debug log somewhere, and a suite run by chi's own execute tool inherits
# the worker's environment (SAMAGOTCHI_HOSTS_JSON with the real hosts, the
# spawner's CLI flags such as SAMAGOTCHI_GUARDRAILS_ENABLED=false). Specs set
# what they need, :integration examples included. The suite's own switches stay.
SPEC_ENV_SWITCHES = %w[SAMAGOTCHI_INTEGRATION SAMAGOTCHI_MACOS_BUILD].freeze
SPEC_ENV_CLEAR = -> { ENV.keys.each { |key| ENV.delete(key) if key.start_with?("SAMAGOTCHI_") && !SPEC_ENV_SWITCHES.include?(key) } }
SPEC_ENV_CLEAR.call

# Isolate specs from the developer's ~/.config/samagotchi/config.yml (hosts,
# memories, aliases...) with a minimal fixture config. :integration examples
# get their own fixture config, built from SAMAGOTCHI_INTEGRATION_* (host,
# port, model; spec/support/integration_server.rb), never the real one.
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
SPEC_INTEGRATION_XDG_CONFIG_HOME = (IntegrationServer.write_config_home(IntegrationServer.settings) if ENV["SAMAGOTCHI_INTEGRATION"] == "1")
at_exit { FileUtils.remove_entry(SPEC_INTEGRATION_XDG_CONFIG_HOME) if SPEC_INTEGRATION_XDG_CONFIG_HOME && File.directory?(SPEC_INTEGRATION_XDG_CONFIG_HOME) }

# Likewise keep sessions/*.json and history.json out of the developer's
# ~/.local/state/samagotchi. Unlike config, :integration examples stay here too.
SPEC_XDG_STATE_HOME = Dir.mktmpdir("samagotchi-spec-state")
ENV["XDG_STATE_HOME"] = SPEC_XDG_STATE_HOME
at_exit { FileUtils.remove_entry(SPEC_XDG_STATE_HOME) if File.directory?(SPEC_XDG_STATE_HOME) }

# An exit between examples (a thread's `exit` raised again in the main thread
# while the reporter runs, a before(:context) hook's) unwinds the whole run
# with the exit's status, 0 for `exit` or `exit(0)`. RSpec itself exits only
# with a failing status, so a successful SystemExit here is always a stray
# one: fail the run (in rspec's own process, not in a spec's fork).
spec_process = Process.pid
at_exit do
  if Process.pid == spec_process && $!.is_a?(SystemExit) && $!.success?
    warn "\nA stray exit(0) ended the rspec run early (#{$!.backtrace&.first}): failing it."
    exit 1
  end
end

# The throwaway repos specs commit in: no detached auto-maintenance or gc
# after a commit, still writing .git/objects/maintenance.lock while the
# example's tmpdir is removed (Errno::ENOENT on the macOS runner).
ENV["GIT_CONFIG_COUNT"] = "2"
ENV["GIT_CONFIG_KEY_0"] = "maintenance.auto"
ENV["GIT_CONFIG_VALUE_0"] = "false"
ENV["GIT_CONFIG_KEY_1"] = "gc.auto"
ENV["GIT_CONFIG_VALUE_1"] = "0"

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
  config.include SpecWaiting
  config.include SpecEnv
  config.include ChiCli
  config.warnings = true
  config.order = :random
  Kernel.srand config.seed

  # A spec's allow_net_connect! ends with its example: back to no net.
  config.after(:each) { WebMock.disable_net_connect! }

  # Never let a spec block on the developer's real terminal. Unstubbed Reline
  # reads behave like EOF (Ctrl-D); specs that need input stub their own values.
  config.before(:each) do
    if defined?(Reline)
      allow(Reline).to receive(:readmultiline).and_return(nil)
      allow(Reline).to receive(:readline).and_return(nil)
    end
    # ContextWindow remembers the last server-reported window process-wide.
    Samagotchi::ContextWindow.reset! if defined?(Samagotchi::ContextWindow)
    # The /props answers and failures are one store per host for the process
    # (Client.props_entry): a spec's fake server must not serve the next
    # example's probe.
    Samagotchi::Client.reset_props_store! if defined?(Samagotchi::Client) && Samagotchi::Client.respond_to?(:reset_props_store!)
    # The log facade is process-wide: unconfigured again, it resolves its
    # file from this example's config (the temp XDG_STATE_HOME by default).
    Samagotchi::Log.reset! if defined?(Samagotchi::Log)
    # Hooks::BundleLoader evals each bundle hook into a Samagotchi::Bundles
    # module that lives for the process: chi builds one Engine, the suite
    # hundreds. Fresh modules, or each load redefines the last one's constants
    # and methods ("already initialized constant" warnings).
    if defined?(Samagotchi::Bundles)
      Samagotchi::Bundles.constants.each { |name| Samagotchi::Bundles.send(:remove_const, name) }
    end
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

  # An exit escaping an example fails it loudly. RSpec rescues everything but
  # SystemExit (and signals), so an `exit` in the example, or one a thread's
  # `exit` raises again in the main thread wherever it is, would otherwise end
  # the whole run quietly: "N examples, 0 failures", exit status 0.
  config.around(:each) do |example|
    example.run
  rescue SystemExit => e
    raise "exit(#{e.status}) escaped the example (its own code, or a thread from it or an earlier example): " \
          "#{e.backtrace&.first(8)&.join("\n  ")}"
  end

  # Every example that was to run ran. A run that stopped early on purpose
  # (--fail-fast, Ctrl-C) or already failed is left alone; filters and focus
  # are fine, the count is of the filtered examples.
  config.after(:suite) do
    world = RSpec.world
    next if world.wants_to_quit || world.rspec_is_quitting || world.non_example_failure

    expected = world.example_count(world.ordered_example_groups)
    ran = config.reporter.examples.size
    raise "only #{ran} of #{expected} examples ran: something ended the run early" if ran < expected
  end

  # Really compile the macOS desktop helper (swiftc, codesign): slow, and
  # needs the Command Line Tools. Own switch, not :integration's.
  config.around(:each, :macos_build) do |example|
    skip "Set SAMAGOTCHI_MACOS_BUILD=1 to compile the desktop helper" unless ENV["SAMAGOTCHI_MACOS_BUILD"] == "1"

    example.run
  end

  # Point :integration examples at the integration fixture config and let
  # them reach the network (the after hook above turns it off again), then
  # restore the unit fixture. Skip here, before the switch: this config-level
  # around wraps the group's own around hooks and lets, so a skipped example
  # runs none of its setup. XDG_STATE_HOME stays the suite's temp dir.
  config.around(:each, :integration) do |example|
    skip "Set SAMAGOTCHI_INTEGRATION=1 to run integration tests" unless ENV["SAMAGOTCHI_INTEGRATION"] == "1"
    unless IntegrationServer.settings.model?
      skip "Set SAMAGOTCHI_INTEGRATION_MODEL to the served model id (see docs/testing.md)"
    end

    ENV["XDG_CONFIG_HOME"] = SPEC_INTEGRATION_XDG_CONFIG_HOME
    ENV.delete("SAMAGOTCHI_RECAP_ENABLED")
    WebMock.allow_net_connect!
    Samagotchi::Log.reset! if defined?(Samagotchi::Log)
    example.run
  ensure
    ENV["XDG_CONFIG_HOME"] = SPEC_XDG_CONFIG_HOME
    SPEC_ENV_CLEAR.call
    ENV["SAMAGOTCHI_RECAP_ENABLED"] = "false"
    Samagotchi::Log.reset! if defined?(Samagotchi::Log)
  end

  # Specs of the idle recap's own settings: recap as configured (on by
  # default), not the suite's SAMAGOTCHI_RECAP_ENABLED=false.
  config.around(:each, :recap) do |example|
    ENV.delete("SAMAGOTCHI_RECAP_ENABLED")
    example.run
  ensure
    ENV["SAMAGOTCHI_RECAP_ENABLED"] = "false"
  end

end
