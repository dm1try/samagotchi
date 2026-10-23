# frozen_string_literal: true

require "rubocop"
# Not rubocop/rspec/support: it includes CopHelper in every example group of
# the run, whose #registry shadows the specs' own let(:registry).
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require "rubocop/rspec/shared_contexts"
require_relative "../../rubocop/samagotchi"

RSpec.describe RuboCop::Cop::Samagotchi::SilentWait do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  include_context "config"

  let(:ruby_version) { 3.3 } # .rubocop.yml's TargetRubyVersion
  let(:message) { described_class::MSG }

  it "allows a wait_until whose value the code uses" do
    expect_no_offenses(<<~RUBY)
      found = wait_until { lookup }
      expect(wait_until { lookup }).to eq(:found)
      wait_until { ready? } || raise("not ready")
    RUBY
  end

  it "flags a wait_until whose value is dropped" do
    expect_offense(<<~RUBY)
      it "waits" do
        wait_until { ready? }
        ^^^^^^^^^^ #{message}
        expect(thing).to be_done
      end
    RUBY
  end

  it "flags a bare wait_until as an example's or a hook's last line, which RSpec drops" do
    expect_offense(<<~RUBY)
      it "waits" do
        start
        wait_until(timeout: 2) { ready? }
        ^^^^^^^^^^^^^^^^^^^^^^ #{message}
      end
      before { wait_until { _1 } }
               ^^^^^^^^^^ #{message}
    RUBY
  end

  it "flags a last-line wait_until in an if, a modifier if, or an example with an ensure" do
    expect_offense(<<~RUBY)
      it "waits" do
        if slow?
          wait_until { ready? }
          ^^^^^^^^^^ #{message}
        end
      end
      it "waits" do
        wait_until { ready? } if slow?
        ^^^^^^^^^^ #{message}
      end
      it "waits" do
        start
        wait_until { ready? }
        ^^^^^^^^^^ #{message}
      ensure
        stop
      end
    RUBY
  end

  it "allows a wait_until as a helper method's last line: its caller has the value" do
    expect_no_offenses(<<~RUBY)
      def ready = wait_until { File.exist?(path) }
      let(:found) { wait_until { lookup } }
    RUBY
  end

  it "allows a bounded best-effort wait tagged wait-ok" do
    expect_no_offenses(<<~RUBY)
      wait_until(timeout: 0.5) { idle? } # wait-ok: at most, fine to cut short
      # wait-ok: at most, fine to cut short
      SpecWaiting.wait_until(timeout: 0.5) { idle? }
    RUBY
  end

  it "flags expect(wait_until { … }).to be(true), eq(true) and be_truthy" do
    expect_offense(<<~RUBY)
      expect(wait_until { done? }).to be(true)
             ^^^^^^^^^^ #{message}
      expect(wait_until { done? }).to be true
             ^^^^^^^^^^ #{message}
      expect(wait_until { done? }).to eq(true)
             ^^^^^^^^^^ #{message}
      expect(SpecWaiting.wait_until { done? }).to be_truthy
             ^^^^^^^^^^^^^^^^^^^^^^ #{message}
    RUBY
  end
end
