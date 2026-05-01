# frozen_string_literal: true

require "spec_helper"
require "samagotchi/client"

RSpec.describe Samagotchi::Client do
  describe "#complete" do
    it "joins streamed completion chunks into a single response" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")
      request = nil

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) do |built_request, &block|
        request = built_request
        block.call(response)
      end
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"Hel")
        .and_yield("lo\"}\n")
        .and_yield("data: {\"content\":\" world\"}\n")

      result = client.complete("prompt", stop: ["done"])

      expect(result).to eq("Hello world")
      expect(request.body).to include('"stream":true')
      expect(request.body).to include('"prompt":"prompt"')
      expect(request.body).to include('"stop":["done"]')
      expect(request["Content-Type"]).to eq("application/json")
    end

    it "uses configured timeout values" do
      client = described_class.new(host: "localhost", port: 8080, open_timeout: 2, read_timeout: 1200)
      http = instance_double(Net::HTTP)
      response = double("response")

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 2, read_timeout: 1200)
        .and_yield(http)
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body)

      client.complete("prompt")
    end

    it "invokes on_chunk for each streamed content fragment" do
      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")
      chunks = []

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 10, read_timeout: 600)
        .and_yield(http)
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body).and_yield("data: {\"content\":\"Hel\"}\n")
        .and_yield("data: {\"content\":\"lo\"}\n")

      result = client.complete("prompt", on_chunk: ->(event) { chunks << event[:content] })

      expect(result).to eq("Hello")
      expect(chunks).to eq(["Hel", "lo"])
    end

    it "reads timeout values from environment" do
      ENV["LLAMA_OPEN_TIMEOUT"] = "3"
      ENV["LLAMA_READ_TIMEOUT"] = "900"

      client = described_class.new(host: "localhost", port: 8080)
      http = instance_double(Net::HTTP)
      response = double("response")

      allow(Net::HTTP).to receive(:start)
        .with("localhost", 8080, open_timeout: 3, read_timeout: 900)
        .and_yield(http)
      allow(http).to receive(:request) { |_request, &block| block.call(response) }
      allow(response).to receive(:read_body)

      client.complete("prompt")
    ensure
      ENV.delete("LLAMA_OPEN_TIMEOUT")
      ENV.delete("LLAMA_READ_TIMEOUT")
    end
  end
end
