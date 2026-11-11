# frozen_string_literal: true

require "spec_helper"
require "prism"
require "samagotchi/bridge"

module BridgeEngineCallReach
  ROOT = File.expand_path("../..", __dir__)
  BRIDGE_SOURCE = File.join(ROOT, "lib/samagotchi/bridge.rb")
  BRIDGE_PARTS = File.join(ROOT, "lib/samagotchi/bridge")

  class Calls < Prism::Visitor
    attr_reader :found

    def initialize
      super
      @found = []
    end

    def visit_call_node(node)
      receiver = node.receiver
      if (receiver.is_a?(Prism::InstanceVariableReadNode) && receiver.name == :@engine) ||
         (receiver.is_a?(Prism::LocalVariableReadNode) && receiver.name == :engine)
        @found << node.name
      end
      super
    end
  end

  def self.calls_by_file
    [BRIDGE_SOURCE, *Dir.glob(File.join(BRIDGE_PARTS, "*.rb"))].sort.to_h do |path|
      visitor = Calls.new
      Prism.parse_file(path).value.accept(visitor)
      [path.delete_prefix("#{ROOT}/"), visitor.found.uniq]
    end
  end
end

RSpec.describe "Bridge calls on Engine" do
  let(:calls_by_file) { BridgeEngineCallReach.calls_by_file }

  it "lists every Engine method called by Bridge files" do
    missing = calls_by_file.flat_map do |path, methods|
      methods.reject { |method| Samagotchi::Bridge::ENGINE_CALLS.key?(method) }
             .map { |method| "#{path}: #{method}" }
    end

    expect(missing).to be_empty, "Engine calls missing from Bridge::ENGINE_CALLS:\n#{missing.join("\n")}"
  end

  it "does not keep methods the Bridge no longer calls" do
    called = calls_by_file.values.flatten.uniq
    stale = Samagotchi::Bridge::ENGINE_CALLS.keys - called

    expect(stale).to be_empty, "Stale entries in Bridge::ENGINE_CALLS: #{stale.join(", ")}"
  end
end
