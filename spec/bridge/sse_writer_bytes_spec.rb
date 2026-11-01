# frozen_string_literal: true

require "stringio"
require "samagotchi/bridge"

# An event JSON can't take must not end the streams that reach it.
RSpec.describe Samagotchi::Bridge::SSEWriter do
  subject(:writer) { described_class.new(engine: double("engine"), ring: double("ring"), session_id: "s", raw: true) }

  let(:io) { StringIO.new }

  it "sends an event with invalid bytes scrubbed, at any depth" do
    event = { type: :card, event_seq: 7, lines: [{ text: "a\xFFb" }] }

    expect { writer.send(:write_event, io, event) }.not_to raise_error

    data = io.string[/^data: (.*)$/, 1]
    expect(JSON.parse(data).dig("lines", 0, "text")).to eq("a?b")
    expect(io.string).to include("id: 7")
  end

  it "sends a binary string's text the same way" do
    writer.send(:write_event, io, { type: :card, event_seq: 9, text: "a\xFFb".b })

    expect(JSON.parse(io.string[/^data: (.*)$/, 1])).to include("text" => "a?b")
  end

  it "sends a clean event as it is" do
    writer.send(:write_event, io, { type: :card, event_seq: 8, text: "héllo" })

    expect(JSON.parse(io.string[/^data: (.*)$/, 1])).to include("text" => "héllo")
  end
end
