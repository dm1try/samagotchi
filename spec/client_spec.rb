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

      allow(Net::HTTP).to receive(:start).with("localhost", 8080).and_yield(http)
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
  end
end
