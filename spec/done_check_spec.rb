# frozen_string_literal: true

require "samagotchi/done_check"

RSpec.describe Samagotchi::DoneCheck do
  def mode_with(value)
    original = ENV.fetch("SAMAGOTCHI_TURN_DONE_CHECK", nil)
    value.nil? ? ENV.delete("SAMAGOTCHI_TURN_DONE_CHECK") : ENV["SAMAGOTCHI_TURN_DONE_CHECK"] = value
    described_class.mode
  ensure
    original.nil? ? ENV.delete("SAMAGOTCHI_TURN_DONE_CHECK") : ENV["SAMAGOTCHI_TURN_DONE_CHECK"] = original
  end

  it "is off by default; edits turns it on; config file and env, no CLI flag" do
    expect(mode_with(nil)).to eq("off")
    expect(mode_with("edits")).to eq("edits")
    entry = Samagotchi::Config.find_by_key("turn.done_check")
    expect(entry.env_key).to eq("SAMAGOTCHI_TURN_DONE_CHECK")
    expect(entry).not_to be_cli_exposed
    expect(Samagotchi::Config.resolve("turn.done_check", file_data: { "turn" => { "done_check" => "edits" } }, env: {}))
      .to eq("edits")
  end

  it "fires once, only under edits, only after a file-changing tool ran in the turn" do
    check = described_class.new(mode: "edits")
    expect(check.fire?).to be(false)
    check.saw_calls(%w[read execute])
    expect(check.fire?).to be(false)
    check.saw_calls(%w[edit])
    expect(check.fire?).to be(true)

    conversation = [{ role: "model", content: "report" }]
    check.ask!(conversation, emit: ->(_) {}, iteration: 3)
    expect(check.fire?).to be(false)
    expect(described_class.new(mode: "off").tap { |c| c.saw_calls(%w[write]) }.fire?).to be(false)
  end

  it "reads DONE, an empty reply and a short DONE line as done; a longer text replaces" do
    expect(described_class.done_reply?("DONE")).to be(true)
    expect(described_class.done_reply?("  **DONE.**\n")).to be(true)
    expect(described_class.done_reply?("")).to be(true)
    expect(described_class.done_reply?("All steps are complete. DONE")).to be(true)
    expect(described_class.done_reply?("## Report\n#{"x" * 400}\nDONE")).to be(false)
    expect(described_class.done_reply?("I still need to commit.")).to be(false)
  end
end
