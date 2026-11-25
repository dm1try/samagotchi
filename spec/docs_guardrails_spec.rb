# frozen_string_literal: true

require "samagotchi/guardrails/verdict"

# docs/guardrails.md's intro list of the rules only the user may allow is
# hand-written and drifts from Verdict::PROTECTED_RULES (the constant the
# gate reads), so the spec pins the intro list to the constant as a set.
RSpec.describe "docs/guardrails.md user-only rules list" do
  let(:doc) { File.read(File.expand_path("../docs/guardrails.md", __dir__)) }

  it "lists exactly Verdict::PROTECTED_RULES in the intro" do
    phrase = doc.index(/only the\s+user may allow/)
    expect(phrase).not_to be_nil
    match = doc[phrase..].match(/\(([^)]*)\)/)
    expect(match).not_to be_nil
    ids = match[1].scan(/`([^`]+)`/).flatten
    expect(ids).to match_array(Samagotchi::Guardrails::Verdict::PROTECTED_RULES)
  end
end
