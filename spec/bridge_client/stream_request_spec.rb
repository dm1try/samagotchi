# frozen_string_literal: true

require "samagotchi/bridge_client"

RSpec.describe Samagotchi::BridgeClient::StreamRequest do
  # A server that reads one request head, answers +reply+ and keeps the
  # connection open; the head comes back through the returned lambda.
  def serve(reply)
    server = TCPServer.new("127.0.0.1", 0)
    heads = Queue.new
    thread = Thread.new do
      conn = server.accept
      head = +""
      head << conn.gets.to_s until head.end_with?("\r\n\r\n")
      heads << head
      conn.write(reply)
      sleep
    end
    thread.report_on_exception = false
    @cleanup = -> { thread.kill; server.close }
    [server.local_address.ip_port, -> { heads.pop }]
  end

  after { @cleanup&.call }

  it "writes the bytes BridgeClient#connect_stream wrote before it" do
    expect(described_class.request(host: "127.0.0.1", port: 4100, path: "/session/s1/stream?snapshot=1",
                                   last_event_id: " 7-ab "))
      .to eq("GET /session/s1/stream?snapshot=1 HTTP/1.1\r\nHost: 127.0.0.1:4100\r\nAccept: text/event-stream\r\n" \
             "Last-Event-ID: 7-ab\r\nConnection: keep-alive\r\n\r\n")
    expect(described_class.request(host: "127.0.0.1", port: 4100, path: "/session/s1/stream", last_event_id: ""))
      .to eq("GET /session/s1/stream HTTP/1.1\r\nHost: 127.0.0.1:4100\r\nAccept: text/event-stream\r\n" \
             "Connection: keep-alive\r\n\r\n")
  end

  it "puts extra headers after Last-Event-ID" do
    expect(described_class.request(host: "studio", port: 4567, path: "/api/sessions/s1/stream", last_event_id: "3-x",
                                   headers: { "Authorization" => "Bearer t" }))
      .to eq("GET /api/sessions/s1/stream HTTP/1.1\r\nHost: studio:4567\r\nAccept: text/event-stream\r\n" \
             "Last-Event-ID: 3-x\r\nAuthorization: Bearer t\r\nConnection: keep-alive\r\n\r\n")
  end

  it "is what BridgeClient#connect_stream sends, and leaves the socket at the body with the status" do
    port, head = serve("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: {}\n\n")
    sock, status = Samagotchi::BridgeClient.new(session_id: "s1", port: port)
                                           .connect_stream(query: "?snapshot=1", last_event_id: "9-e", timeout: 2)

    expect(status).to eq(200)
    expect(sock.readpartial(64)).to eq("data: {}\n\n")
    expect(head.call).to eq(described_class.request(host: "127.0.0.1", port: port, path: "/session/s1/stream?snapshot=1",
                                                    last_event_id: "9-e"))
  ensure
    sock&.close
  end

  it "hands back the response headers, names in lower case" do
    port, = serve("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
    sock, status, headers = described_class.open(host: "127.0.0.1", port: port, path: "/x", timeout: 2)

    expect(status).to eq(200)
    expect(headers).to eq("content-type" => "text/event-stream", "transfer-encoding" => "chunked")
  ensure
    sock&.close
  end

  it "gives up on headers that don't all come within the timeout" do
    port, = serve("HTTP/1.1 200 OK\r\nContent-Type: text/eve")

    expect(described_class.open(host: "127.0.0.1", port: port, path: "/x", timeout: 0.2)).to be_nil
  end

  it "answers nil when nothing listens" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.ip_port
    server.close

    expect(described_class.open(host: "127.0.0.1", port: port, path: "/x", timeout: 0.2)).to be_nil
  end
end
