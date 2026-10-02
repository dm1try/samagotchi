# frozen_string_literal: true

require "samagotchi/plugin/api"

RSpec.describe "Samagotchi::Plugin::Api.result_text" do
  def handler_result(value)
    fields = Samagotchi::Plugin::Api.entry_fields(
      { block: ->(_args, _ctx) { value }, schema: { parameters: {} }, label: "t" }, nil
    )
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
