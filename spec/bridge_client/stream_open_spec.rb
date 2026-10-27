# frozen_string_literal: true

require "samagotchi/bridge_client"

RSpec.describe "Samagotchi::BridgeClient::StreamOpen" do
  let(:stream_open) { Samagotchi::BridgeClient.const_get(:StreamOpen) }

  def socket_with(reply)
    server = TCPServer.new("127.0.0.1", 0)
    writer = Thread.new do
      peer = server.accept
      peer.write(reply)
      peer.shutdown(Socket::SHUT_WR)
      peer.close
    end
    writer.report_on_exception = false
    socket = TCPSocket.new("127.0.0.1", server.local_address.ip_port)
    [socket, writer, server]
  end

  it "classifies a 200 response as Opened without consuming the stream" do
    socket, writer, server = socket_with("frame")

    outcome = stream_open.classify(socket, 200, "content-type" => "text/event-stream")

    expect(outcome).to be_a(stream_open::Opened)
    expect(outcome.sock).to be(socket)
    expect(outcome.status).to eq(200)
    expect(socket.readpartial(5)).to eq("frame")
  ensure
    socket&.close
    join!(writer, "the stream response") if writer
    server&.close
  end

  it "classifies 404 as an unknown session" do
    socket, writer, server = socket_with("{}")

    expect(stream_open.classify(socket, 404, "content-length" => "2"))
      .to have_attributes(reason: :unknown_session, status: 404)
  ensure
    join!(writer, "the refusal response") if writer
    server&.close
  end

  it "recognizes bridge-secret refusals with and without Content-Length" do
    body = JSON.generate(error: "bridge_secret", detail: "secret refused")
    [
      [body, { "content-length" => body.bytesize.to_s }],
      [body, {}]
    ].each do |reply, headers|
      socket, writer, server = socket_with(reply)
      expect(stream_open.classify(socket, 403, headers))
        .to have_attributes(reason: :bridge_secret, detail: "secret refused", status: 403)
      socket.close
      join!(writer, "the refusal response")
      server.close
    end
  end

  it "distinguishes proxy refusals from other failures and retains their detail" do
    body = JSON.generate(error: "proxied", detail: "local clients only")
    socket, writer, server = socket_with(body)

    expect(stream_open.classify(socket, 403, "content-length" => body.bytesize.to_s))
      .to have_attributes(reason: :proxied, detail: "local clients only", status: 403)
  ensure
    socket&.close
    join!(writer, "the refusal response") if writer
    server&.close
  end

  it "classifies other statuses with the response detail and a missing socket as unreachable" do
    body = JSON.generate(error: "internal_error", detail: "bridge failed")
    socket, writer, server = socket_with(body)

    expect(stream_open.classify(socket, 500, "content-length" => body.bytesize.to_s))
      .to have_attributes(reason: :other, detail: "bridge failed", status: 500)
    expect(stream_open.classify(nil, nil, {})).to be_a(stream_open::Unreachable)
  ensure
    socket&.close
    join!(writer, "the error response") if writer
    server&.close
  end

  describe "BridgeClient#open_stream" do
    let(:client) { Samagotchi::BridgeClient.new(session_id: "s1", port: 4100, secret: nil) }

    it "retries a refused connect three times and reports the attempts" do
      allow(client).to receive(:connect_stream).and_return(nil, nil, nil)

      expect(client.open_stream).to have_attributes(attempts: 3)
      expect(client).to have_received(:connect_stream).exactly(3).times
    end

    it "does not retry a refusal response or a response-header timeout" do
      socket, writer, server = socket_with("{}")
      allow(client).to receive(:connect_stream).and_return([socket, 403, { "content-length" => "2" }])

      expect(client.open_stream).to have_attributes(reason: :other)
      expect(client).to have_received(:connect_stream).once

      allow(client).to receive(:connect_stream).and_raise(Errno::ETIMEDOUT)
      expect(client.open_stream).to have_attributes(attempts: 1)
      expect(client).to have_received(:connect_stream).twice
    ensure
      socket&.close
      join!(writer, "the refusal response") if writer
      server&.close
    end
  end
end
