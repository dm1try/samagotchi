# frozen_string_literal: true

require "spec_helper"
require "samagotchi/system_one/judgment_settings"

RSpec.describe Samagotchi::SystemOne::JudgmentSettings do
  def of(name, entries) = described_class.of(name, section: { "judgments" => entries })

  it "is off with nothing set: a bundle's judgment asks only once the user says so" do
    expect(described_class.of("b.x", section: nil)).to have_attributes(mode: "off", host: nil, model: nil, off?: true)
    expect(of("b.x", {})).to be_off
    expect(of("b.x", { "b.x" => { "host" => "h" } })).to be_off
    expect(of("b.x", { "b.x" => "on" })).to be_off
  end

  it "reads an unquoted on and off (booleans in YAML 1.1) as the words" do
    expect(of("b.x", { "b.x" => { "mode" => true } }).mode).to eq("on")
    expect(of("b.x", { "b.x" => { "mode" => false } }).mode).to eq("off")
    expect(of("b.x", { "b.x" => { "mode" => " Audit " } }).mode).to eq("audit")
    expect(of("b.x", { "b.x" => { "mode" => "sometimes" } }).mode).to eq("off")
  end

  it "takes a host and a model for that judgment, blank being none" do
    expect(of("b.x", { "b.x" => { "mode" => "on", "host" => " h ", "model" => "" } })).to have_attributes(host: "h", model: nil)
  end

  # D2: Record and Similar are model-blind, so a model swapped for approvals
  # alone would inherit a clean record and could auto-allow.
  it "gives core's judgments no settings, whatever the file says" do
    %w[approvals.allow toolkit.suggest context.candidate guardrails.x].each do |name|
      entry = { name => { "mode" => "on", "host" => "other", "model" => "swapped" } }
      expect(of(name, entry)).to have_attributes(mode: "off", host: nil, model: nil)
    end
  end

  it "lists the names the file sets" do
    expect(described_class.names(section: { "judgments" => { "b.x" => {}, :"c.y" => {} } })).to eq(%w[b.x c.y])
    expect(described_class.names(section: nil)).to eq([])
  end
end
