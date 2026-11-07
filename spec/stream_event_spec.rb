# frozen_string_literal: true

require "samagotchi/stream_event"

RSpec.describe Samagotchi::StreamEvent do
  it "hands the event to the callback and returns its value; no callback is fine" do
    seen = []
    expect(described_class.emit(->(e) { seen << e; :ok }, { type: :x }, failure: "stream_event_callback_failed")).to eq(:ok)
    expect(seen).to eq([{ type: :x }])
    expect(described_class.emit(nil, { type: :x }, failure: "stream_event_callback_failed")).to be_nil
  end

  it "logs a failing callback under :turn with the caller's slug and the event's type, and returns nil" do
    allow(Samagotchi::Log).to receive(:warn)
    result = described_class.emit(->(_e) { raise IOError, "client gone" }, { type: :tool_call_started },
                                  failure: "tool_event_callback_failed")

    expect(result).to be_nil
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:turn, "tool_event_callback_failed", hash_including(type: :tool_call_started, msg: "client gone"))
  end
end
