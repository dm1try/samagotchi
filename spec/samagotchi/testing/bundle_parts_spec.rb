# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"
require "samagotchi/testing"

# The test kit loads a plugin's parts from the source, in the manifest's
# order, before the plugin file (Plugin::Loader.register_file's parts:).
RSpec.describe Samagotchi::Testing::Bundle, "plugin parts" do
  let(:fixture) { File.expand_path("../../fixtures/plugin_parts_bundle", __dir__) }

  it "loads a two-part bundle from its source" do
    bundle = described_class.load(fixture)
    expect(bundle.command("/parts").to_s).to include("HELLO, PARTS")
  ensure
    bundle&.shutdown
  end

  it "says which part the manifest names that isn't there" do
    Dir.mktmpdir("kit-parts-") do |tmp|
      dir = File.join(tmp, "plugin-parts")
      FileUtils.cp_r(fixture, dir)
      FileUtils.rm(File.join(dir, "shout.rb"))
      expect { described_class.load(dir) }
        .to raise_error(ArgumentError, "plugin-parts: the manifest names plugin part shout.rb, which the bundle doesn't have")
    end
  end
end
