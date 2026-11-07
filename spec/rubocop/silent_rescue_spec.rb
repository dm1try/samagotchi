# frozen_string_literal: true

require "rubocop"
# Not rubocop/rspec/support: it includes CopHelper in every example group of
# the run, whose #registry shadows the specs' own let(:registry).
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require "rubocop/rspec/shared_contexts"
require_relative "../../rubocop/samagotchi"

RSpec.describe RuboCop::Cop::Samagotchi::SilentRescue do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  include_context "config"

  let(:ruby_version) { 3.3 } # .rubocop.yml's TargetRubyVersion
  let(:message) { described_class::MSG }

  it "flags a rescue StandardError, a bare rescue and a modifier rescue whose body is a lone literal" do
    expect_offense(<<~RUBY)
      def a
        load
      rescue StandardError
      ^^^^^^ #{message}
        nil
      end
      def b
        load
      rescue
      ^^^^^^ #{message}
        []
      end
      def c = load rescue {}
                   ^^^^^^ #{message}
      x = begin; load; rescue ::StandardError => e; nil; end
                       ^^^^^^ #{message}
    RUBY
  end

  it "flags each silent literal, and an empty body" do
    expect_offense(<<~RUBY)
      a rescue false
        ^^^^^^ #{message}
      a rescue true
        ^^^^^^ #{message}
      a rescue ""
        ^^^^^^ #{message}
      a rescue 0
        ^^^^^^ #{message}
      begin
        a
      rescue StandardError, IOError
      ^^^^^^ #{message}
      end
    RUBY
  end

  it "allows a body that does something, a non-empty literal and a narrower class" do
    expect_no_offenses(<<~RUBY)
      a rescue log_it
      a rescue "unknown"
      a rescue 1
      a rescue [:x]
      begin
        a
      rescue StandardError => e
        Log.warn(:web, "a_failed", error: e.class.name)
        nil
      end
      begin
        a
      rescue StandardError
        raise
      end
      begin
        a
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end
    RUBY
  end

  it "allows a silence tagged degrade-ok on the rescue's line, the line above or the body's line, but not an empty tag" do
    expect_no_offenses(<<~RUBY)
      peer.close rescue nil # degrade-ok: the client is gone
      begin
        a
      # degrade-ok: a routine probe
      rescue StandardError
        nil
      end
      begin
        a
      rescue StandardError
        nil # degrade-ok: a routine probe
      end
    RUBY
    expect_offense(<<~RUBY)
      peer.close rescue nil # degrade-ok:
                 ^^^^^^ #{message}
    RUBY
  end
end
