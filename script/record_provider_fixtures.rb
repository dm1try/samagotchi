#!/usr/bin/env ruby
# frozen_string_literal: true

# Records the OpenAI-compatible fixtures the provider specs replay
# (spec/fixtures/providers/openai/). Run it against a live /v1, e.g. the
# local llama.cpp:
#
#   ruby script/record_provider_fixtures.rb http://localhost:8080/v1 [model]
#
# Streams are saved byte for byte (*.sse), plain responses as *.json with a
# sibling *.status holding the HTTP status. Error fixtures that a local server
# can't produce (401, 429, 500, malformed bodies) are hand-written and carry
# "hand-written" in their file name; this script never touches them.

require "json"
require "net/http"
require "uri"
require "fileutils"

base = (ARGV[0] || "http://localhost:8080/v1").chomp("/")
model = ARGV[1] || "local-model"
out_dir = File.expand_path("../spec/fixtures/providers/openai", __dir__)
FileUtils.mkdir_p(out_dir)

EXECUTE_TOOL = {
  type: "function",
  function: {
    name: "execute",
    description: "Run a shell command and return its output.",
    parameters: {
      type: "object",
      properties: { command: { type: "string", description: "The shell command." } },
      required: ["command"]
    }
  }
}.freeze

def chat_body(model, prompt, stream:, extra: {})
  {
    model: model,
    temperature: 0.0,
    messages: [
      { role: "system", content: "You are a terse assistant. Use tools when asked." },
      { role: "user", content: prompt }
    ],
    tools: [EXECUTE_TOOL],
    tool_choice: "auto"
  }.merge(stream ? { stream: true, stream_options: { include_usage: true } } : {}).merge(extra)
end

def post(base, path, body)
  uri = URI("#{base}#{path}")
  Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 300) do |http|
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
    http.request(request)
  end
end

def save(out_dir, name, response, ext)
  File.write(File.join(out_dir, "#{name}.#{ext}"), response.body.to_s)
  File.write(File.join(out_dir, "#{name}.status"), "#{response.code}\n") unless ext == "sse"
  puts "#{name}.#{ext}: HTTP #{response.code}, #{response.body.to_s.bytesize} bytes"
end

streams = {
  "text_stream" => "Reply with exactly: PONG",
  "tool_call_stream" => "Use the execute tool to run exactly: echo hi",
  "parallel_tool_calls_stream" => "Call the execute tool twice in one reply, in parallel: once with `echo a` and once with `echo b`.",
  "reasoning_tool_stream" => "Think step by step about which command lists files, then call the execute tool with it."
}
streams.each do |name, prompt|
  extra = name.start_with?("parallel") ? { parallel_tool_calls: true } : {}
  save(out_dir, name, post(base, "/chat/completions", chat_body(model, prompt, stream: true, extra: extra)), "sse")
end

save(out_dir, "text_sync", post(base, "/chat/completions", chat_body(model, "Reply with exactly: PONG", stream: false)), "json")
# A prompt over the server's window: llama.cpp answers 400 exceed_context_size_error
# with a JSON body, even for stream: true (sized for its -c 128000 per slot).
overflow = { model: model, stream: true, messages: [{ role: "user", content: "word " * 140_000 }] }
save(out_dir, "error_400", post(base, "/chat/completions", overflow), "json")

models_uri = URI("#{base}/models")
models = Net::HTTP.get_response(models_uri)
save(out_dir, "models", models, "json")
