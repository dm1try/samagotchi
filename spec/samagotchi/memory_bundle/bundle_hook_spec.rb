# frozen_string_literal: true

require "spec_helper"
require "samagotchi/memory_bundle/bundle_hook"

RSpec.describe Samagotchi::MemoryBundle::BundleHook do
  describe ".parse" do
    it "reads a manifest's string keys, prefixing a bare sha" do
      hook = described_class.parse("sha256" => "abc", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => "10")
      expect(hook).to eq(described_class.new(sha256: "sha256:abc", event: "before_tool_call", on_error: "fail_closed", priority: 10))
    end

    it "reads a record's symbol keys, keeping a prefixed sha" do
      hook = described_class.parse(sha256: "sha256:abc", event: "after_tool_call", on_error: "log", priority: 5)
      expect(hook.to_h).to eq(sha256: "sha256:abc", events: ["after_tool_call"], on_error: "log", priority: 5)
    end

    it "fills the defaults: no sha, no event, on_error skip, priority 100" do
      expect(described_class.parse("event" => " before_turn ", "on_error" => " ")).to eq(
        described_class.new(sha256: "", event: "before_turn", on_error: "skip", priority: 100)
      )
      expect(described_class.parse(nil)).to eq(described_class.new)
    end

    it "reads events: a list (a record's too), blanks and repeats dropped" do
      hook = described_class.parse("events" => ["after_turn", " question_asked ", "", "after_turn"])
      expect(hook.events).to eq(%w[after_turn question_asked])
      expect(described_class.parse(events: %w[after_turn question_asked]).events).to eq(%w[after_turn question_asked])
      expect(described_class.parse(nil).events).to eq([])
    end

    it "takes a BundleHook as it is" do
      hook = described_class.new(event: "before_turn")
      expect(described_class.parse(hook)).to be(hook)
    end
  end
end
