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
    # llama.cpp can stream completion chunks as newline-delimited `data: {...}`
    # records. We consume that stream and still return a single joined string so
    # the rest of the harness API stays unchanged.
    #
    # @param prompt      [String]        full formatted prompt string
    # @param stop        [Array<String>] stop sequences
    # @return [String] the generated text
    def complete(prompt, stop: ["<end_of_turn>", "<|tool_response>"])
      uri = URI("http://#{@host}:#{@port}/completion")
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = { prompt: prompt, stop: stop, stream: true }.to_json

      result = +""
      buffer = +""

      Net::HTTP.start(uri.host, uri.port) do |http|
        http.request(request) do |response|
          response.read_body do |chunk|
            buffer << chunk

            while (newline_index = buffer.index("\n"))
              line = buffer.slice!(0, newline_index + 1).strip
              next if line.empty? || !line.start_with?("data: ")

              payload = JSON.parse(line.delete_prefix("data: "))
              result << payload.fetch("content", "")
            end
          end
        end
      end

      result
    rescue => e
      raise "llama.cpp request failed (#{@host}:#{@port}): #{e.message}"
    end
  end
end
