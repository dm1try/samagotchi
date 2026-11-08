# frozen_string_literal: true

require "spec_helper"
require_relative "support"

# Every memory case through chi bundle uninstall, uninstall --force, and chi
# bundle status (with chi bundle list's behind count).
RSpec.describe "Bundle state corpus: uninstall and status" do
  include BundleStateCorpus::Examples

  goldens = BundleStateCorpus::Goldens.new("uninstall_status", BundleStateCorpus.memory_cases.map(&:id))
  before(:all) { @sandbox = BundleStateCorpus::Sandbox.new }

  after(:all) do
    @sandbox&.cleanup
    goldens.finish
  end

  BundleStateCorpus.memory_cases.each do |kase|
    it(kase.id) { expect_memory_cells(goldens, kase) }
  end
end
