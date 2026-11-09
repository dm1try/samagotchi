# frozen_string_literal: true

require "spec_helper"
require "samagotchi/memory_bundle/bundle_hook"

RSpec.describe Samagotchi::MemoryBundle::BundleHook do
  describe ".parse" do
    it "keeps only the sha from a legacy record and prefixes a bare value" do
      hook = described_class.parse("sha256" => "abc", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => "10")
      expect(hook).to eq(described_class.new(sha256: "sha256:abc"))
    end

    it "reads symbol keys, keeping a prefixed sha" do
      hook = described_class.parse(sha256: "sha256:abc", event: "after_tool_call", on_error: "log", priority: 5)
      expect(hook.to_h).to eq(sha256: "sha256:abc")
    end

    it "reads records without a sha" do
      expect(described_class.parse("event" => "before_turn", "on_error" => " ")).to eq(described_class.new)
      expect(described_class.parse(nil)).to eq(described_class.new)
    end

    it "takes a BundleHook as it is" do
      hook = described_class.new(sha256: "sha256:abc")
      expect(described_class.parse(hook)).to be(hook)
    end
  end
end
