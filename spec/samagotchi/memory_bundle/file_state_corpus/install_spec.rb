# frozen_string_literal: true

require "spec_helper"
require_relative "support"

# Every memory case through a plain install (re-install), install --force
# and install --dry-run, from the record's own source at a newer version.
RSpec.describe "Bundle state corpus: install" do
  include BundleStateCorpus::Examples

  goldens = BundleStateCorpus::Goldens.new("install", BundleStateCorpus.memory_cases.map(&:id))
  before(:all) { @sandbox = BundleStateCorpus::Sandbox.new }

  after(:all) do
    @sandbox&.cleanup
    goldens.finish
  end

  BundleStateCorpus.memory_cases.each do |kase|
    it(kase.id) { expect_memory_cells(goldens, kase) }
  end
end
