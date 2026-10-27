# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"

require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/web/grants"

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
      client = Samagotchi::BridgeClient.new(session_id: "s1", port: port, secret: nil)
      opened = client.open_stream
      body = described_class::ProxyStreamBody.new(client: client, opened: opened, query: "", headers: {}, filter: filter)
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

    it "is none for the owner; the participant view's and a participant's filter the frames, nothing theirs for the owner" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: state_dir)
      session.save(state_dir: state_dir)
      grant = Samagotchi::Web::Grants::Grant.new(id: "p_0123abcd", session_id: session.id, digest: "d", kind: "human", name: "Alex",
                                                 role: "reviewer", created_at: nil, expires_at: nil, revoked_at: nil,
                                                 revoked_by: nil, last_used_at: nil)
      request = lambda do |principal, query = ""|
        env = Rack::MockRequest.env_for("/api/sessions/#{session.id}/stream#{query}")
        env[described_class::PRINCIPAL_ENV] = principal
        Rack::Request.new(env)
      end
      owner = Samagotchi::Web::Principal::OWNER
      expect(app.send(:stream_filter, request.call(owner), session.id)).to be_nil

      frame = %(id: 1\r\ndata: {"type":"turn_started","prompt":"hi","author":"p:p_0123abcd","origin":{"client_id":"review:p_0123abcd"}}\r\n\r\n)
      viewed = app.send(:stream_filter, request.call(owner, "?as=participant"), session.id)
      expect(viewed).to be_a(Samagotchi::Web::ParticipantStreamFilter)
      expect(viewed.call(frame)).not_to include("mine")
      theirs = app.send(:stream_filter, request.call(Samagotchi::Web::Principal.new(kind: :participant, grant: grant)), session.id)
      expect(theirs.call(frame)).to include(%("mine":true))
    end

    it "passes a filtered stream only its cursor and join, never client_id or raw" do
      env = Rack::MockRequest.env_for("/x?from_seq=4&client_id=tui:1&raw=1&snapshot=1&as=participant")
      expect(app.send(:participant_stream_query, Rack::Request.new(env))).to eq("?from_seq=4&snapshot=1")
    end
  end
end
