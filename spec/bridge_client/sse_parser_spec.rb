# frozen_string_literal: true

require "samagotchi/bridge_client"

RSpec.describe Samagotchi::BridgeClient::SSEParser do
  def frames_for(*chunks)
    parser = described_class.new
    frames = []
    chunks.each { |chunk| parser.feed(chunk) { |frame| frames << frame } }
    frames
  end

  it "parses CRLF frames with an id, an event type and data" do
    frames = frames_for("id: 3\r\nevent: turn_started\r\ndata: {\"a\":1}\r\n\r\n")

    expect(frames).to eq([{ id: "3", event: "turn_started", data: "{\"a\":1}" }])
  end

  it "reassembles a frame split across chunks, including inside a CRLF" do
    frames = frames_for("id: 4\r", "\ndata: {\"te", "xt\":\"hi\"}\r\n\r", "\n")

    expect(frames).to eq([{ id: "4", event: nil, data: "{\"text\":\"hi\"}" }])
  end

  it "joins multi-line data with newlines and accepts bare LF" do
    frames = frames_for("data: one\ndata: two\n\n")

    expect(frames).to eq([{ id: nil, event: nil, data: "one\ntwo" }])
  end

  it "skips comments (heartbeats) and frames without data" do
    frames = frames_for(": ping\r\n\r\n", "id: 9\r\n\r\n", "data: x\r\n\r\n")

    expect(frames).to eq([{ id: nil, event: nil, data: "x" }])
  end

  it "keeps a partial trailing frame until its blank line arrives" do
    parser = described_class.new
    frames = []
    parser.feed("id: 1\r\ndata: a\r\n") { |f| frames << f }
    expect(frames).to be_empty

    parser.feed("\r\n") { |f| frames << f }
    expect(frames).to eq([{ id: "1", event: nil, data: "a" }])
  end
end
