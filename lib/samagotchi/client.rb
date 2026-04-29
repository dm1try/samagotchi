# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module Samagotchi
  # Thin HTTP client for the llama.cpp native /completion endpoint.
  # Configure via environment variables:
  #   LLAMA_HOST  (default: localhost)
  #   LLAMA_PORT  (default: 8080)
  class Client
    def initialize(host: nil, port: nil)
      @host = host || ENV.fetch("LLAMA_HOST", "localhost")
      @port = (port || ENV.fetch("LLAMA_PORT", "8080")).to_i
    end

    # Send a raw prompt and return the model's completion text.
    #
    # @param prompt      [String]        full formatted prompt string
    # @param stop        [Array<String>] stop sequences
    # @param temperature [Float]
    # @param max_tokens  [Integer]       maximum tokens to generate (n_predict)
    # @return [String] the generated text
    def complete(prompt, stop: ["<end_of_turn>", "<|tool_response>"])
      uri  = URI("http://#{@host}:#{@port}/completion")
      body = { prompt: prompt, stop: stop, stream: false }
      resp = Net::HTTP.post(uri, body.to_json, "Content-Type" => "application/json")
      JSON.parse(resp.body).fetch("content")
    rescue => e
      raise "llama.cpp request failed (#{@host}:#{@port}): #{e.message}"
    end
  end
end
