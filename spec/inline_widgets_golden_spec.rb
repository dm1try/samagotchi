# frozen_string_literal: true

require "json"
require "yaml"
require "spec_helper"
require "samagotchi/inline_widgets"

# What InlineWidgets.parse gives for each of the eval's blocks
# (spec/fixtures/inline_widgets): the type, the data, lenient? and the error,
# byte for byte. inline_widgets_spec.rb checks only each block's outcome; this
# pins what the page draws, so a change to the parser (a data entry beside the
# YAML path) can't move a drawn block. The golden sits beside the fixtures
# folder, never in it: that spec counts the folder's files.
#
# Regenerate only after an intended change to what a block draws:
#   UPDATE_GOLDENS=1 bundle exec rspec spec/inline_widgets_golden_spec.rb
RSpec.describe "InlineWidgets.parse golden (characterization)" do
  fixture_dir = File.expand_path("fixtures/inline_widgets", __dir__)
  golden_path = File.expand_path("fixtures/inline_widgets_golden.json", __dir__)

  def results(dir)
    names = YAML.load_file(File.join(dir, "manifest.yml")).keys.sort
    names.to_h do |name|
      widget = Samagotchi::InlineWidgets.parse(File.read(File.join(dir, name), encoding: "UTF-8"))
      [name, { "type" => widget.type, "data" => widget.data, "lenient" => widget.lenient?, "error" => widget.error }]
    end
  end

  it "gives each fixture the golden's type, data, lenient? and error" do
    text = "#{JSON.pretty_generate(results(fixture_dir))}\n"
    File.write(golden_path, text, encoding: "UTF-8") if ENV["UPDATE_GOLDENS"] == "1"
    expect(text).to eq(File.read(golden_path, encoding: "UTF-8")), "a block parses differently from #{golden_path}"
  end
end
