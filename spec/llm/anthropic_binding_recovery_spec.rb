# frozen_string_literal: true

require "spec_helper"
require "samagotchi/llm/anthropic_binding_recovery"
require "samagotchi/llm/errors"
require "samagotchi/llm/refusal_memo"
require "samagotchi/llm/usage"

# The adapter-level paths (the HTTP round trips) are in
# anthropic_messages_binding_spec.rb; this is the class's own surface.
RSpec.describe Samagotchi::LLM::AnthropicBindingRecovery do
  subject(:binding) { described_class.new(refusals: refusals, host_name: "claude", budget_form: budget_form) }

  let(:refusals) { Samagotchi::LLM::RefusalMemo.new }
  let(:budget_form) { ->(_model) { false } }
  let(:recovery) { described_class::Recovery.new(tried: []) }
  let(:body) do
    { model: "m", max_tokens: 100,
      messages: [{ role: "user", content: [{ type: "text", text: "go" }] },
                 { role: "assistant", content: [{ type: "thinking", thinking: "t", signature: "sig1" },
                                                { type: "text", text: "hi" }] }] }
  end
  let(:bound_elsewhere) { "messages.1.content.0: the thinking block is bound to a different conversation prefix." }

  def signature_error(detail)
    Samagotchi::LLM::BadRequest.new(detail, status: 400, thinking_signature: true)
  end

  it "has no step for a 400 that is no signature 400 or a missing body" do
    expect(binding.advance(Samagotchi::LLM::BadRequest.new("nope"), body, recovery, "m")).to be_nil
    expect(binding.advance(signature_error(bound_elsewhere), nil, recovery, "m")).to be_nil
    expect(recovery.step).to be_nil
  end

  it "takes drop_block for a block bound elsewhere, then strip for a second signature 400, then nothing" do
    expect(binding.advance(signature_error(bound_elsewhere), body, recovery, "m")).to eq(:drop_block)
    recovery.tried << :drop_block
    expect(binding.advance(signature_error(bound_elsewhere), body, recovery, "m")).to eq(:strip)
    expect(recovery.strip_from).to eq([1, 0])
    recovery.tried << :strip
    expect(binding.advance(signature_error(bound_elsewhere), body, recovery, "m")).to be_nil
  end

  it "strips directly when the host refused the binding controls" do
    refusals.remember(:binding_controls)
    expect(binding.advance(signature_error(bound_elsewhere), body, recovery, "m")).to eq(:strip)
  end

  it "builds the drop_block body with adaptive thinking and the stripped body with the identities removed" do
    recovery.step = :drop_block
    sent, removed = binding.recovered_body(body, recovery)
    expect(sent[:thinking]).to eq(type: "adaptive", block_binding: described_class::DROP_BLOCK)
    expect(removed).to be_nil

    recovery.step = :strip
    recovery.strip_from = [1, 0]
    sent, removed = binding.recovered_body(body, recovery)
    expect(sent[:messages][1][:content]).to eq([{ type: "text", text: "hi" }])
    expect(removed).to eq(["sig1"])
  end

  it "puts the stripped identities on the response as its ThinkingDrop" do
    recovery.step = :strip
    response = Samagotchi::LLM::ChatResponse.new(text: "ok", reasoning: "", tool_calls: [], usage: Samagotchi::LLM::Usage.none, finish_reason: "stop")
    out = binding.with_thinking_drop(response, recovery, body, ["sig1"].freeze, [], "m")
    expect(out.thinking_drop).to eq(Samagotchi::LLM::ThinkingDrop.new(identities: ["sig1"], how: :strip))
  end
end
