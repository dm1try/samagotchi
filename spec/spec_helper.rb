# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "fileutils"
require "io/console" # IO.console, stubbed in every example below
require "timeout"
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
require_relative "support/stamps"
require_relative "support/env"
require_relative "support/git_repo"
require_relative "support/chi_cli"
# Reads SAMAGOTCHI_INTEGRATION_* now, before the clear below.
require_relative "support/integration_server"

# Start from none of the developer's SAMAGOTCHI_* settings: a shell may point
# the debug log somewhere, and a suite run by chi's own execute tool inherits
# the worker's environment (the spawner's CLI flags such as SAMAGOTCHI_GUARDRAILS_ENABLED=false). Specs set
# what they need, :integration examples included. The suite's own switches stay.
# That includes a worker's SAMAGOTCHI_WORKER_PROCESS / SAMAGOTCHI_WORKER_DETACH
# (run_session_loop deletes them as it reads them; this is the second guard):
# with them set, an in-process run_session_loop would trap signals and fork.
SPEC_ENV_SWITCHES = %w[SAMAGOTCHI_INTEGRATION SAMAGOTCHI_MACOS_BUILD].freeze
SPEC_ENV_CLEAR = -> { ENV.keys.each { |key| ENV.delete(key) if key.start_with?("SAMAGOTCHI_") && !SPEC_ENV_SWITCHES.include?(key) } }
SPEC_ENV_CLEAR.call

# The per-example time limit (config.around below): its error, and the opt-in
# live tags it leaves alone.
class SpecExampleTimeout < StandardError; end
SPEC_UNTIMED_TAGS = %i[integration macos_build warmup recap].freeze

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
# The turn-end warm-up (cache.warmup) would send a request after every
# turn: off for specs; examples tagged :warmup turn it back on.
ENV["SAMAGOTCHI_CACHE_WARMUP"] = "off"
# Log drops a record with an unknown tag or a bad event name; specs (and the
# workers they spawn) raise instead, so a typo'd tag fails loudly.
ENV["SAMAGOTCHI_LOG_STRICT"] = "1"
ENV["XDG_CONFIG_HOME"] = SPEC_XDG_CONFIG_HOME
# A host key never comes from the developer's login Keychain: off for this
# process and everything it starts (bin/chi, workers); in-process reads go to
# a null keychain too (HostKeys specs inject their own fake).
ENV["SAMAGOTCHI_KEYCHAIN"] = "off"
# Loaded here (not by the specs that need it) so the before hook below always
# swaps in the null keychain: a spec's own env hash doesn't carry the switch.
require "samagotchi/host_keys"
# Loaded here so the before hook below always pins rg (a light file).
require "samagotchi/bundle_needs"
at_exit { FileUtils.remove_entry(SPEC_XDG_CONFIG_HOME) if File.directory?(SPEC_XDG_CONFIG_HOME) }
SPEC_INTEGRATION_XDG_CONFIG_HOME = (IntegrationServer.write_config_home(IntegrationServer.settings) if ENV["SAMAGOTCHI_INTEGRATION"] == "1")
at_exit { FileUtils.remove_entry(SPEC_INTEGRATION_XDG_CONFIG_HOME) if SPEC_INTEGRATION_XDG_CONFIG_HOME && File.directory?(SPEC_INTEGRATION_XDG_CONFIG_HOME) }

# Likewise keep sessions/*.json and history.json out of the developer's
# ~/.local/state/samagotchi. Unlike config, :integration examples stay here too.
SPEC_XDG_STATE_HOME = Dir.mktmpdir("samagotchi-spec-state")
ENV["XDG_STATE_HOME"] = SPEC_XDG_STATE_HOME
at_exit { FileUtils.remove_entry(SPEC_XDG_STATE_HOME) if File.directory?(SPEC_XDG_STATE_HOME) }

# And keep the peer bundles (claude-peer, codex-peer) off the developer's
# Claude Code and Codex config folders: their status card and install-skill
# read (and --yes writes) <dir>/skills/chi-peer/SKILL.md. Empty dirs, as the
# CLIs' own CLAUDE_CONFIG_DIR / CODEX_HOME; a spec that needs the ~ default
# unsets them and points HOME at a temp dir.
SPEC_PEER_HOME = Dir.mktmpdir("samagotchi-spec-peer-home")
ENV["CLAUDE_CONFIG_DIR"] = File.join(SPEC_PEER_HOME, "claude")
ENV["CODEX_HOME"] = File.join(SPEC_PEER_HOME, "codex")
at_exit { FileUtils.remove_entry(SPEC_PEER_HOME) if File.directory?(SPEC_PEER_HOME) }

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
  # The opt-in live examples are filtered out, not skipped: a skip from an
  # around hook prints a "SkipDeclaredInExample" backtrace in the Pending
  # list, one per example, burying the real ones. Their around hooks below
  # still skip them when selected without the switch.
  config.filter_run_excluding integration: true unless ENV["SAMAGOTCHI_INTEGRATION"] == "1"
  config.filter_run_excluding macos_build: true unless ENV["SAMAGOTCHI_MACOS_BUILD"] == "1"
  config.disable_monkey_patching!
  config.include SpecWaiting
  config.include SpecStamps
  config.include SpecEnv
  config.include ChiCli
  config.include SpecGitRepo
  config.warnings = true
  config.order = :random
  Kernel.srand config.seed

  # A spec's allow_net_connect! ends with its example: back to no net.
  config.after { WebMock.disable_net_connect! }
  config.after { remove_git_repo }
  config.after { remove_hosts_config_homes }

  # Never let a spec block on the developer's real terminal. Unstubbed Reline
  # reads behave like EOF (Ctrl-D); specs that need input stub their own values.
  # Nor see it: the suite runs as CI does (no TTY on the standard streams, no
  # console for the width), whether it runs from a terminal or a pipe. A spec
  # of terminal behaviour stubs its own tty? or IO.console over these.
  config.before do
    if defined?(Reline)
      allow(Reline).to receive(:readmultiline).and_return(nil)
      allow(Reline).to receive(:readline).and_return(nil)
    end
    allow(IO).to receive(:console).and_return(nil)
    [STDIN, STDOUT, STDERR].each do |io|
      allow(io).to receive_messages(tty?: false, isatty: false)
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
    Samagotchi::HostKeys.keychain = Samagotchi::HostKeys::NullKeychain
    # Hooks::BundleLoader evals each bundle hook into a Samagotchi::Bundles
    # module that lives for the process: chi builds one Engine, the suite
    # hundreds. Fresh modules, or each load redefines the last one's constants
    # and methods ("already initialized constant" warnings).
    if defined?(Samagotchi::Bundles)
      Samagotchi::Bundles.constants.each { |name| Samagotchi::Bundles.send(:remove_const, name) }
    end
    # ConfigFile prints each config warning once per process.
    Samagotchi::ConfigFile.reset_warnings! if defined?(Samagotchi::ConfigFile)
    # EffectiveModel::Unresolved warns once per process for each failure.
    Samagotchi::EffectiveModel::Unresolved.reset! if defined?(Samagotchi::EffectiveModel::Unresolved)
    # The saved host model lists (ModelListStore) are a file in the state dir
    # this whole suite shares: a spec that lists a fake host's models must
    # not make the next example's model look unknown (nor hide a real one).
    FileUtils.rm_f(Samagotchi::ModelListStore.path) if defined?(Samagotchi::ModelListStore)
    # The attached TUI's status ticker thread draws until the spinner
    # finishes, and many specs start one they never finish: it would write
    # into later specs' output (AttachedLoop builds its view with the default
    # interval). Off by default; specs of the ticker pass an interval.
    stub_const("Samagotchi::TerminalUI::AttachedView::TICK_INTERVAL", nil) if defined?(Samagotchi::TerminalUI::AttachedView::TICK_INTERVAL)
    # Goldens hold no machine state: the prompt's "prefer rg" line follows
    # PATH (SystemPrompt#rg_available?), and CI runners have no rg. Pinned
    # as found in this process (not in a bin/chi or worker a spec starts);
    # examples tagged :real_rg look it up on PATH.
    unless RSpec.current_example.metadata[:real_rg]
      allow(Samagotchi::BundleNeeds).to receive(:found?).and_call_original
      allow(Samagotchi::BundleNeeds).to receive(:found?).with("rg", any_args).and_return(true)
    end
  end

  # An exit escaping an example fails it loudly. RSpec rescues everything but
  # SystemExit (and signals), so an `exit` in the example, or one a thread's
  # `exit` raises again in the main thread wherever it is, would otherwise end
  # the whole run quietly: "N examples, 0 failures", exit status 0.
  config.around do |example|
    example.run
  rescue SystemExit => e
    raise "exit(#{e.status}) escaped the example (its own code, or a thread from it or an earlier example): " \
          "#{e.backtrace&.first(8)&.join("\n  ")}"
  end

  # A hung example fails instead of hanging the run. The slowest examples take
  # ~15 s alone and ~31 s under a loaded parallel run (the peer pair specs),
  # so 120 s only fires on a real hang: an unbounded wait, a Queue#pop or a
  # join nothing ends. It wraps the example's own hooks (an after's join too).
  # The opt-in live tags run real models and builds and keep no limit;
  # SPEC_EXAMPLE_TIMEOUT=0 turns it off (a debugger session), another number
  # sets it.
  example_timeout = Float(ENV.fetch("SPEC_EXAMPLE_TIMEOUT", "120"))
  config.around do |example|
    if example_timeout.zero? || example.metadata.values_at(*SPEC_UNTIMED_TAGS).any?
      example.run
    else
      # timeout-ok: the per-example limit, whose message names the example's hang
      Timeout.timeout(example_timeout, SpecExampleTimeout,
                      "example still running after #{example_timeout.to_i} s (SPEC_EXAMPLE_TIMEOUT): a hang?") do
        example.run
      end
    end
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
    ENV["SAMAGOTCHI_KEYCHAIN"] = "off"
    ENV["SAMAGOTCHI_CACHE_WARMUP"] = "off"
    Samagotchi::Log.reset! if defined?(Samagotchi::Log)
  end

  config.around(:each, :warmup) do |example|
    ENV.delete("SAMAGOTCHI_CACHE_WARMUP")
    example.run
  ensure
    ENV["SAMAGOTCHI_CACHE_WARMUP"] = "off"
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
