# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "digest"
require "samagotchi/memory_bundle/bundle_hook"

RSpec.describe Samagotchi::MemoryBundle::BundleHook do
  describe ".parse" do
    it "reads a manifest's string keys, prefixing a bare sha" do
      hook = described_class.parse("sha256" => "abc", "event" => "before_tool_call", "on_error" => "fail_closed", "priority" => "10")
      expect(hook).to eq(described_class.new(sha256: "sha256:abc", event: "before_tool_call", on_error: "fail_closed", priority: 10))
    end

    it "reads a record's symbol keys, keeping a prefixed sha" do
      hook = described_class.parse(sha256: "sha256:abc", event: "after_tool_call", on_error: "log", priority: 5)
      expect(hook.to_h).to eq(sha256: "sha256:abc", event: "after_tool_call", on_error: "log", priority: 5)
    end

    it "fills the defaults: no sha, no event, on_error skip, priority 100" do
      expect(described_class.parse("event" => " before_turn ", "on_error" => " ")).to eq(
        described_class.new(sha256: "", event: "before_turn", on_error: "skip", priority: 100)
      )
      expect(described_class.parse(nil)).to eq(described_class.new)
    end

    it "takes a BundleHook as it is" do
      hook = described_class.new(event: "before_turn")
      expect(described_class.parse(hook)).to be(hook)
    end
  end

  it ".of_file records the file's sha with the defaults" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "h.rb")
      File.write(path, "x = 1\n")
      expect(described_class.of_file(path)).to eq(
        described_class.new(sha256: "sha256:#{Digest::SHA256.hexdigest("x = 1\n")}")
      )
    end
  end

  it "#to_record is the string-keyed form manifest.yml and manifest.json hold" do
    expect(described_class.new(sha256: "sha256:abc", event: "before_turn").to_record).to eq(
      "sha256" => "sha256:abc", "event" => "before_turn", "on_error" => "skip", "priority" => 100
    )
  end

  it "#hex is the sha without its prefix" do
    expect(described_class.new(sha256: "sha256:abc").hex).to eq("abc")
    expect(described_class.new.hex).to eq("")
  end
end
