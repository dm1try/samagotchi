# frozen_string_literal: true

require "spec_helper"
require "samagotchi/memory_bundle/memory_files"

RSpec.describe Samagotchi::MemoryBundle::MemoryFiles do
  describe ".repo_meta?" do
    it "matches a repo's meta files in any case, with .md, .markdown, .txt or no extension" do
      %w[README README.md readme.markdown LICENSE.txt Licence CHANGELOG.md Contributing.md CODE_OF_CONDUCT.md
         security.md].each { |name| expect(described_class.repo_meta?(name)).to be(true), name }
    end

    it "leaves memories alone, readme-like names included" do
      %w[identity.md readme_notes.md my_license.md security_review.md README.rst.md].each do |name|
        expect(described_class.repo_meta?(name)).to be(false), name
      end
    end
  end
end
