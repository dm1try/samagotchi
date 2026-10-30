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

  it "flags a Timeout.timeout block, which names nothing when it fires" do
    expect_offense(<<~RUBY)
      Timeout.timeout(2) { queue.pop }
      ^^^^^^^^^^^^^^^^^^ #{described_class::MSG_TIMEOUT}
      ::Timeout.timeout(2) do
      ^^^^^^^^^^^^^^^^^^^^ #{described_class::MSG_TIMEOUT}
        nil until done?
      end
    RUBY
  end

  it "allows a Timeout.timeout hang guard tagged timeout-ok, on its line or the line above, but not an empty tag" do
    expect_no_offenses(<<~RUBY)
      status = Timeout.timeout(10) { Process.wait2(pid) } # timeout-ok: the child exits by itself
      # timeout-ok: a hang guard: the read ends at EOF
      lines = Timeout.timeout(5) { reader.read }
    RUBY
    expect_offense(<<~RUBY)
      Timeout.timeout(5) { reader.read } # timeout-ok:
      ^^^^^^^^^^^^^^^^^^ #{described_class::MSG_TIMEOUT}
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

  describe "a statement join(N)" do
    let(:join_message) { described_class::MSG_JOIN }

    it "flags a join with a number whose value is dropped, an example's last line, or an each block's" do
      expect_offense(<<~RUBY)
        it "joins" do
          thread.join(2)
          ^^^^^^^^^^^^^^ #{join_message}
          expect(box[:answer]).to be_done
          @thread&.join(0.5)
          ^^^^^^^^^^^^^^^^^^ #{join_message}
        end
        after { @turn.join(1) }
                ^^^^^^^^^^^^^ #{join_message}
        threads.each { |t| t.join(5) }
                           ^^^^^^^^^ #{join_message}
      RUBY
    end

    it "allows a join whose value is used, a join without a deadline, Array#join and join!" do
      expect_no_offenses(<<~RUBY)
        expect(thread.join(0.1)).to be_nil
        thread.join(2) || raise("stuck")
        done = thread.join(1)
        def finish = thread.join(2)
        thread.join
        lines.join(",")
        parts.join(separator)
        join!(thread, "the question")
        threads.map { |t| t.join(5) }
      RUBY
    end

    it "allows a best-effort join tagged wait-ok" do
      expect_no_offenses(<<~RUBY)
        reader.join(0.5) # wait-ok: killed below if still alive
      RUBY
    end
  end
end
