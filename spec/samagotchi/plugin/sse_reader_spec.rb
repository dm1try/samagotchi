# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plugin/http"

# The plain SSE reader under ctx.http.stream's Stream#each_event.
RSpec.describe Samagotchi::Plugin::Http::SseReader do
  let(:event_class) { described_class::Event }

  # The events +chunks+ give, fed one by one to one reader.
  def events(*chunks)
    reader = described_class.new
    found = []
    chunks.each { |chunk| reader.feed(chunk) { |event| found << event } }
    found
  end

  def event(data, type: "message", id: nil) = event_class.new(type: type, data: data, id: id)

  it "reads event, data and id; the type is message when none is named" do
    expect(events("event: ping\ndata: a\nid: 7\n\ndata: b\n\n"))
      .to eq([event("a", type: "ping", id: "7"), event("b", id: "7")])
  end

  it "joins several data lines with a newline, and drops only one space after the colon" do
    expect(events("data: one\ndata:two\ndata:  three\n\n")).to eq([event("one\ntwo\n three")])
  end

  it "skips comment lines and unknown fields; a field without a colon has an empty value" do
    expect(events(": keep-alive\nretry: 10\nfoo: bar\ndata\n\n")).to eq([event("")])
  end

  it "takes \\n, \\r\\n and \\r line ends" do
    expect(events("data: a\r\n\r\ndata: b\r\rdata: c\n\n")).to eq([event("a"), event("b"), event("c")])
  end

  it "takes a chunk boundary anywhere: mid-line, between \\r and \\n, inside a UTF-8 character" do
    euro = "€".b
    expect(events("da", "ta: x", "\r", "\n", "\r", "\ndata: #{euro[0, 1]}", "#{euro[1..]}\n", "\n"))
      .to eq([event("x"), event("€")])
  end

  it "yields the event at its blank line, not before" do
    reader = described_class.new
    found = []
    reader.feed("data: a\n") { |e| found << e }
    expect(found).to be_empty
    reader.feed("\n") { |e| found << e }
    expect(found).to eq([event("a")])
  end

  it "drops an event the body's end cuts off, and one without data" do
    expect(events("event: lonely\n\ndata: cut off")).to eq([])
  end

  it "drops a leading byte order mark, even split over chunks" do
    expect(events("\xEF".b, "\xBB\xBF".b + "data: a\n\n")).to eq([event("a")])
  end

  it "decodes each event as UTF-8, a broken sequence replaced" do
    found = events("data: \xFF ok\n\n".b)
    expect(found.first.data).to eq("� ok")
    expect(found.first.data.encoding).to eq(Encoding::UTF_8)
  end
end
