# frozen_string_literal: true

require "spec_helper"
require_relative "support"
require_relative "assets"

# Every asset case (a rule, the plugin, a script, a hook) through a plain
# install, upgrade, upgrade --dry-run, uninstall, chi update's plan and chi
# bundle status.
RSpec.describe "Bundle state corpus: assets" do
  include BundleStateCorpus::Examples

  goldens = BundleStateCorpus::Goldens.new("assets", BundleStateCorpus.asset_cases.map(&:id))
  before(:all) { @sandbox = BundleStateCorpus::AssetSandbox.new }

  after(:all) do
    @sandbox&.cleanup
    goldens.finish
  end

  BundleStateCorpus.asset_cases.each do |kase|
    it(kase.id) { expect_asset_cells(goldens, kase) }
  end
end
