# frozen_string_literal: true

require "yaml"
require "spec_helper"
require "samagotchi/config_text_edit"

RSpec.describe Samagotchi::ConfigTextEdit do
  let(:text) { "# mine\nweb:\n  # a note\n  port: 4567\n" }

  def set(value, key: "markdown", section: "web")
    expected = YAML.safe_load(text)
    expected[section] = (expected[section] || {}).merge(key => value)
    described_class.set(text, section: section, key: key, value: value, expected: expected)
  end

  it "writes true and false bare, so they round-trip and the comments stay" do
    expect(set(true)).to eq("#{text}  markdown: true\n")
    expect(set(false)).to eq("#{text}  markdown: false\n")
    expect(YAML.safe_load(set(true)).dig("web", "markdown")).to be(true)
  end

  it "writes an Integer bare" do
    expect(set(8080, key: "port")).to eq("# mine\nweb:\n  # a note\n  port: 8080\n")
  end

  it "still quotes strings, those that look like booleans or numbers too" do
    expect(set("true")).to eq("#{text}  markdown: \"true\"\n")
    expect(set("box:qwen/7b", key: "model", section: "default")).to eq("#{text}default:\n  model: \"box:qwen/7b\"\n")
    expect(YAML.safe_load(set("true")).dig("web", "markdown")).to eq("true")
  end
end
