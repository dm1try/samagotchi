# frozen_string_literal: true

require "spec_helper"
require "samagotchi/remotes"
require "samagotchi/session_access/http_transport"

RSpec.describe Samagotchi::SessionAccess::HTTPTransport do
  let(:entry) { Samagotchi::Remotes::Entry.new(name: "studio", url: "http://192.168.1.29:4567", token: "tok") }
  let(:transport) { described_class.new(entry) }

  it "sends the token as Bearer, a body as JSON and the query encoded, and reads the answer" do
    stub = stub_request(:post, "http://192.168.1.29:4567/api/sessions/s1/wait?a=b%20c")
           .with(headers: { "Authorization" => "Bearer tok", "Content-Type" => "application/json" }, body: { timeout: 30 }.to_json)
           .to_return(status: 200, body: '{"status":"done"}')

    reply = transport.call(:post, "/api/sessions/s1/wait", query: { a: "b c", none: nil }, body: { timeout: 30 })

    expect(stub).to have_been_requested
    expect(reply).to have_attributes(status: 200, json: { "status" => "done" })
  end

  it "sends raw bytes with their type, and no Authorization without a token" do
    bare = described_class.new(entry.with(token: nil))
    stub = stub_request(:post, "http://192.168.1.29:4567/api/sessions/s1/images?name=a.png")
           .with { |request| request.body == "PNG" && request.headers["Content-Type"] == "image/png" && !request.headers.key?("Authorization") }
           .to_return(status: 201, body: "not json")

    expect(bare.call(:post, "/api/sessions/s1/images", query: { name: "a.png" }, raw: "PNG", content_type: "image/png"))
      .to have_attributes(status: 201, json: nil)
    expect(stub).to have_been_requested
  end

  it "names the remote and why it couldn't be asked" do
    {
      Errno::ECONNREFUSED => "connection refused", Net::OpenTimeout => "no answer within 5 s",
      Net::ReadTimeout => "it took the request but sent no answer within 75 s", Errno::EHOSTUNREACH => "host unreachable",
      SocketError.new("getaddrinfo: nodename nor servname provided") => "can't find host 192.168.1.29",
      Errno::ECONNRESET => "the connection broke (ECONNRESET)",
      Net::HTTPBadResponse.new("wrong status line: \"SSH-2.0-OpenSSH_9.6\"") => "it didn't answer HTTP (is it chi web's port?)",
      Net::HTTPHeaderSyntaxError.new("wrong header line format") => "it didn't answer HTTP (is it chi web's port?)",
      Net::WriteTimeout => "it took no request within 75 s",
      Timeout::Error => "no answer in time"
    }.each do |error, words|
      stub_request(:get, "http://192.168.1.29:4567/api/info").to_raise(error)
      expect { transport.call(:get, "/api/info") }
        .to raise_error(Samagotchi::SessionAccess::RemoteFailed, "remote studio (http://192.168.1.29:4567): #{words}")
    end
  end

  it "takes a request's own read timeout, and names it when it passes" do
    http = instance_double(Net::HTTP, "use_ssl=": nil, "open_timeout=": nil, "max_retries=": nil)
    allow(http).to receive(:read_timeout=)
    allow(http).to receive(:write_timeout=)
    allow(http).to receive(:request).and_raise(Net::ReadTimeout)
    allow(Net::HTTP).to receive(:new).and_return(http)

    expect { transport.call(:post, "/api/sessions/s1/turn", body: {}, read_timeout: 45) }
      .to raise_error(Samagotchi::SessionAccess::RemoteFailed, /sent no answer within 45 s\z/)
    expect(http).to have_received(:read_timeout=).with(45)
  end

  it "never shows the token in inspect" do
    expect(transport.inspect).not_to include("tok\"")
    expect(transport.inspect).to include("remote studio")
  end
end
