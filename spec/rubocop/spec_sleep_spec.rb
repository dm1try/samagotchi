# frozen_string_literal: true

require "rubocop"
# Not rubocop/rspec/support: it includes CopHelper in every example group of
# the run, whose #registry shadows the specs' own let(:registry).
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require "rubocop/rspec/shared_contexts"
require_relative "../../rubocop/samagotchi"

RSpec.describe RuboCop::Cop::Samagotchi::SpecSleep do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  include_context "config"

  let(:ruby_version) { 3.3 } # .rubocop.yml's TargetRubyVersion
  let(:message) { described_class::MSG }

  it "flags a bare sleep" do
    expect_offense(<<~RUBY)
      it "settles" do
        sleep 0.1
        ^^^^^^^^^ #{message}
      end
    RUBY
  end

  it "flags Kernel.sleep and sleep with parentheses" do
    expect_offense(<<~RUBY)
      Kernel.sleep(0.1)
      ^^^^^^^^^^^^^^^^^ #{message}
      sleep(0.2)
      ^^^^^^^^^^ #{message}
    RUBY
  end

  it "allows a sleep tagged sleep-ok on its line or the line above" do
    expect_no_offenses(<<~RUBY)
      sleep 0.2 # sleep-ok: the server is slow on purpose
      # sleep-ok: separates the two mtimes
      sleep 0.01
    RUBY
  end

  it "flags a sleep whose tag gives no reason" do
    expect_offense(<<~RUBY)
      sleep 0.2 # sleep-ok:
      ^^^^^^^^^ #{message}
    RUBY
  end

  it "leaves a sleep in a shell string and another receiver's sleep alone" do
    expect_no_offenses(<<~RUBY)
      run("sleep 30")
      spawn("sh", "-c", "sleep 5; echo done")
      clock.sleep(1)
    RUBY
  end
end
