# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"

require "samagotchi/web/app"

# The stream proxy's frame-filter seam: the owner's stream is the Bridge's
# bytes unchanged (no filter); a filter, when a principal has one, sees each
# chunk read from the Bridge and sends what it returns.
RSpec.describe Samagotchi::Web::App, "stream filter" do
  let(:frames) { "id: 1\r\nevent: a\r\ndata: {}\r\n\r\nid: 2\r\nevent: b\r\ndata: {}\r\n\r\n" }

  # A Bridge that answers one stream: its headers, +frames+, then EOF.
  def with_bridge
    server = TCPServer.new("127.0.0.1", 0)
    accepter = Thread.new do
      conn = server.accept
      conn.readpartial(16_384)
      conn.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n#{frames}")
      conn.close
    end
    accepter.report_on_exception = false
    yield server.local_address.ip_port
  ensure
    join!(accepter, "the fake Bridge's stream") if accepter
    server&.close
  end

  def streamed(filter:)
    with_bridge do |port|
      body = described_class::ProxyStreamBody.new(host: "127.0.0.1", port: port, session_id: "s1", query: "", headers: {},
                                                  filter: filter)
      out = []
      body.each { |chunk| out << chunk } # rubocop:disable Style/MapIntoArray -- a Rack body: #each only, no #map
      out.join
    end
  end

  it "passes the Bridge's bytes through unchanged without a filter (the owner's stream)" do
    expect(streamed(filter: nil)).to eq(frames)
  end

  it "sends what a filter returns for each chunk, and nothing for nil or an empty string" do
    seen = []
    filter = lambda do |chunk|
      seen << chunk
      chunk.include?("event: a") ? chunk.upcase : nil
    end

    expect(streamed(filter: filter)).to eq(seen.join.upcase)
    expect(seen.join).to eq(frames)
    expect(streamed(filter: ->(_chunk) { "" })).to eq("")
  end

  describe "#stream_filter" do
    let(:state_dir) { Dir.mktmpdir("web-stream-filter") }
    let(:app) { described_class.new(state_dir: state_dir, bridge_wait_timeout: 0) }

    after { FileUtils.remove_entry(state_dir) }

    it "is none for the owner, and refuses a principal it has no filter for" do
      expect(app.send(:stream_filter, Samagotchi::Web::Principal::OWNER)).to be_nil
      other = Samagotchi::Web::Principal.new(kind: :participant, grant: nil)
      expect { app.send(:stream_filter, other) }.to raise_error(ArgumentError, /no stream filter/)
    end
  end
end
