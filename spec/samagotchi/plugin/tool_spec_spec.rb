# frozen_string_literal: true

require "samagotchi/plugin/api"

RSpec.describe Samagotchi::Plugin::ToolSpec do
  describe ".result_text" do
    def handler_result(value)
      fields = described_class.build("t", "t", label: "t") { value }.entry_fields(nil)
      fields[:handler].call({ name: "t", args: {} }, nil)
    end

    # Was Hash#inspect: {"a"=>1} on Ruby 3.3, {"a" => 1} on 3.4.
    it "gives a Hash or Array result as JSON, the same on every Ruby" do
      expect(handler_result({ "a" => 1, b: [nil, "x"] })).to eq('{"a":1,"b":[null,"x"]}')
      expect(handler_result([{ "a" => 1 }])).to eq('[{"a":1}]')
    end

    it "keeps a String (a ToolResult too) as it is and #to_s the rest" do
      tool_result = Samagotchi::Plugin::ToolResult.new("text")
      expect(handler_result(tool_result)).to equal(tool_result)
      expect(handler_result("plain")).to eq("plain")
      expect(handler_result(42)).to eq("42")
      expect(handler_result(nil)).to eq("")
    end
  end

  describe "refs:" do
    let(:call) { { name: "t", args: { "q" => "x" } } }

    it "gives a two-arg lambda the call's typed args and the run's tool_id, a one-arg one the args alone" do
      seen = []
      two = described_class.build("t", "t", refs: ->(args, tool_id) { seen << [args, tool_id] and [] }) { "ok" }
      one = described_class.build("t", "t", refs: ->(args) { seen << args and [] }) { "ok" }

      two.entry_fields(nil)[:refs].call(call, "t3")
      two.entry_fields(nil)[:refs].call(call)
      one.entry_fields(nil)[:refs].call(call, "t4")
      expect(seen).to eq([[{ "q" => "x" }, "t3"], [{ "q" => "x" }, nil], { "q" => "x" }])
    end
  end

  # Bundles call Api.tool_spec and read the spec as a Hash (the mcp
  # bundle's token estimate: spec[:schema]).
  it "is what Api.tool_spec gives, its fields read as a Hash's too" do
    spec = Samagotchi::Plugin::Api.tool_spec("t", "does t", params: { q: { type: "string", required: true } }) { "ok" }
    expect(spec).to be_a(described_class)
    expect(spec[:schema]).to equal(spec.schema)
    expect(spec[:name]).to eq("t")
    expect(spec[:nope]).to be_nil
    expect(spec.schema).to eq({ name: "t", description: "does t",
                                parameters: { type: "object", properties: { q: { type: "string", description: "" } },
                                              required: ["q"] } })
  end
end
