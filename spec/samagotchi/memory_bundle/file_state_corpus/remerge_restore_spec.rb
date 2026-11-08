# frozen_string_literal: true

require "spec_helper"
require_relative "support"

# Every memory case at the shipped version, as samagotchi-system: Remerge,
# its dry run, and SystemBundle.sync (the restore of a missing file; any
# other case goes through Remerge, its cell marked via: remerge).
RSpec.describe "Bundle state corpus: remerge and restore" do
  include BundleStateCorpus::Examples

  goldens = BundleStateCorpus::Goldens.new("remerge_restore", BundleStateCorpus.memory_cases.map(&:id))
  before(:all) { @sandbox = BundleStateCorpus::Sandbox.new }

  after(:all) do
    @sandbox&.cleanup
    goldens.finish
  end

  BundleStateCorpus.memory_cases.each do |kase|
    it(kase.id) { expect_memory_cells(goldens, kase) }
  end
end
