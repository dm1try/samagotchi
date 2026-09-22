# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

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
  end

  config.before(:each, :integration) do
    skip "Set SAMAGOTCHI_INTEGRATION=1 to run integration tests" unless ENV["SAMAGOTCHI_INTEGRATION"] == "1"
  end

end
