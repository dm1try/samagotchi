# frozen_string_literal: true

require "spec_helper"
require_relative "support"

# Every memory case through upgrade, upgrade --force and upgrade --dry-run,
# to a newer version (chi update's plan of it: plan_spec.rb).
RSpec.describe "Bundle state corpus: upgrade" do
  include BundleStateCorpus::Examples

  goldens = BundleStateCorpus::Goldens.new("upgrade", BundleStateCorpus.memory_cases.map(&:id))
  before(:all) { @sandbox = BundleStateCorpus::Sandbox.new }

  after(:all) do
    @sandbox&.cleanup
    goldens.finish
  end

  BundleStateCorpus.memory_cases.each do |kase|
    it(kase.id) { expect_memory_cells(goldens, kase) }
  end
end
