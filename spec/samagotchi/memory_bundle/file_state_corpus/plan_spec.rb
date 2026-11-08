# frozen_string_literal: true

require "spec_helper"
require_relative "support"

# Every memory case through chi update's plan (ShippedUpdate.plan) of an
# upgrade to a newer version: the row's status, and whether it names the
# file as merged, behind or replaced. Its own file for the time budget: the
# plan runs the merges again.
RSpec.describe "Bundle state corpus: chi update's plan" do
  include BundleStateCorpus::Examples

  goldens = BundleStateCorpus::Goldens.new("plan", BundleStateCorpus.memory_cases.map(&:id))
  before(:all) { @sandbox = BundleStateCorpus::Sandbox.new }

  after(:all) do
    @sandbox&.cleanup
    goldens.finish
  end

  BundleStateCorpus.memory_cases.each do |kase|
    it(kase.id) { expect_memory_cells(goldens, kase) }
  end
end
