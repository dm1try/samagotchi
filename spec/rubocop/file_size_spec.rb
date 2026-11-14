# frozen_string_literal: true

require "rubocop"
require "rubocop/rspec/cop_helper"
require "rubocop/rspec/expect_offense"
require "rubocop/rspec/shared_contexts"
require_relative "../../rubocop/samagotchi"

RSpec.describe RuboCop::Cop::Samagotchi::FileSize do
  include CopHelper
  include RuboCop::RSpec::ExpectOffense

  include_context "config"

  let(:ruby_version) { 3.3 } # .rubocop.yml's TargetRubyVersion
  let(:cop_config) { { "Max" => 1000, "Caps" => {} } }

  def file_size_message(count, cap)
    "File has #{count} lines, over its cap of #{cap}: split it " \
      "(docs/testing.md, File size); never raise a cap."
  end

  it "allows a file at or below Max" do
    expect_no_offenses("# a comment\n\n" * 500, "lib/sample.rb")
  end

  it "flags an over-Max file on its first line and counts comments and blank lines" do
    source = "# a comment\n^^^^^^^^^^^ #{file_size_message(1001, 1000)}\n" + ("\n" * 1000)

    expect_offense(source, "lib/sample.rb")
  end

  context "with a per-file cap" do
    let(:cop_config) { { "Max" => 1000, "Caps" => { "lib/sample.rb" => 3 } } }

    it "flags a file over the cap" do
      source = "# a comment\n^^^^^^^^^^^ #{file_size_message(4, 3)}\n" + ("\n" * 3)

      expect_offense(source, "lib/sample.rb")
    end

    it "allows a file at the cap" do
      expect_no_offenses("one\ntwo\nthree\n", "lib/sample.rb")
    end
  end
end
