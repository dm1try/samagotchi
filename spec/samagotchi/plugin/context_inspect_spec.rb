# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/context"

# A plugin's ctx shows up in failure output: it names its bundle, never the
# environment it holds.
RSpec.describe "Samagotchi::Plugin::Context#inspect" do
  it "names the bundle and leaves the environment out" do
    env = { "OPENROUTER_API_KEY" => "sk-or-secret-value" }
    ctx = Samagotchi::Plugin::Context.new(bundle: "prs", label: "plugin.rb (bundle prs)", settings: {},
                                          host: Object.new, env: env)

    [ctx.inspect, ctx.pretty_inspect, [ctx].inspect].each do |text|
      expect(text).to include("Samagotchi::Plugin::Context bundle=prs")
      expect(text).not_to include("sk-or-secret-value")
    end
  end
end
