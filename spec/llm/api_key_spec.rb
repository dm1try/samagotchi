# frozen_string_literal: true

require "pp"
require "samagotchi/llm/api_key"

RSpec.describe Samagotchi::LLM::ApiKey do
  let(:env) { { "BOX_KEY" => "sk-box-1", "OTHER_SECRET" => "sk-other-2" } }
  let(:key) { described_class.for("BOX_KEY", host: "box", env: env) }

  it "is nil for a host without api_key_env" do
    expect(described_class.for(nil, host: "box")).to be_nil
    expect(described_class.for("  ", host: "box")).to be_nil
  end

  it "never shows the environment it reads the key from" do
    [key.inspect, key.to_s, key.pretty_inspect].each do |text|
      expect(text).to include("BOX_KEY")
      expect(text).not_to include("sk-box-1")
      expect(text).not_to include("sk-other-2")
    end
  end
end
