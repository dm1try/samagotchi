# frozen_string_literal: true

require "samagotchi/bridge_client"

# EventStream tells a new worker from the one it follows by
# BridgeClient#worker_key (a Bridge's port), not by the client object.
RSpec.describe Samagotchi::BridgeClient::EventStream, "worker identity" do
  let(:sse_head) { "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" }
  let(:events) { Queue.new }
  # A client whose key says another worker, on the same port.
  let(:keyed_client) do
    Class.new(Samagotchi::BridgeClient) do
      def worker_key = "other"
    end
  end

  # One connection that sends a frame and closes; the server goes with it,
  # so every reconnect fails and rediscovery runs.
  def one_shot_bridge
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      conn = server.accept
      conn.gets.to_s until conn.gets.to_s == "\r\n"
      conn.write("#{sse_head}id: 1-a\ndata: #{JSON.generate(type: "turn_completed")}\n\n")
      conn.close
      server.close
    end
    thread.report_on_exception = false
    [server.local_address.ip_port, thread]
  end

  def collect(count)
    Array.new(count) { |index| pop!(events, "event #{index + 1} of #{count}") }
  end

  it "is the port" do
    expect(Samagotchi::BridgeClient.new(session_id: "s1", port: 4100).worker_key).to eq(4100)
  end

  it "does not take a rediscovered client with the same key for a move" do
    port, = one_shot_bridge
    client = Samagotchi::BridgeClient.new(session_id: "s1", port: port)
    looks = 0
    rediscover = lambda do
      looks += 1
      Samagotchi::BridgeClient.new(session_id: "s1", port: port)
    end
    stream = client.follow(rediscover: rediscover, reconnect_delays: [0.01, 0.01]) { |event| events << event }

    expect(collect(2).map { |e| e["type"] }).to eq(%w[turn_completed stream_closed])
    expect(looks).to eq(3)
  ensure
    stream&.close
  end

  it "moves to a rediscovered client whose key differs, even on the same port" do
    port, = one_shot_bridge
    client = Samagotchi::BridgeClient.new(session_id: "s1", port: port)
    found = keyed_client.new(session_id: "s1", port: port)
    stream = client.follow(rediscover: -> { found }, reconnect_delays: [0.01]) { |event| events << event }

    expect(collect(2)).to eq([{ "type" => "turn_completed" }, { "type" => "worker_changed", "port" => port }])
  ensure
    stream&.close
  end
end
