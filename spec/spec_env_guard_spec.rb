# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

# Samagotchi::Testing's env_not_shown (spec/support/env.rb loads it): a failing
# matcher that meets the process ENV doesn't print its contents, which hold
# real API keys.
RSpec.describe "The process ENV in a failing matcher" do
  let(:secret) { "not-to-be-printed" }

  around { |example| with_env("SPEC_ENV_GUARD_SECRET" => "not-to-be-printed") { example.run } }

  def failure_text
    yield
    raise "the matcher should have failed"
  rescue RSpec::Expectations::ExpectationNotMetError, RSpec::Mocks::MockExpectationError => e
    e.message
  end

  it "shows neither as the actual, with its diff, nor as an argument" do
    [
      failure_text { expect(ENV).to eq("a" => 1) },
      failure_text { expect({ env: ENV }).to eq({ env: {} }) },
      failure_text do
        target = double("target", go: nil)
        target.go(a: 2, env: ENV)
        expect(target).to have_received(:go).with(a: 1, env: ENV)
      end
    ].each do |text|
      expect(text).to include("contents not shown")
      expect(text).not_to include(secret)
    end
  end

  # A bundle's own suite has no spec/support: the kit's require is all it has.
  [["the bundle kit", "samagotchi/testing"], ["the file alone, which needs nothing of chi", "samagotchi/testing/env_not_shown"]].each do |what, file|
    it "is covered with #{what}" do
      out, status = Open3.capture2e(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e",
                                    %(require "#{file}"; puts ENV.inspect; pp ENV))
      expect(status).to be_success, out
      expect(out.lines.last(2).map(&:chomp)).to eq([Samagotchi::Testing::ENV_NOT_SHOWN] * 2)
      expect(out).not_to include(secret)
    end
  end
end
