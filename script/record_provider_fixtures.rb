#!/usr/bin/env ruby
# frozen_string_literal: true

# Records the provider fixtures the provider specs replay
# (spec/fixtures/providers/<api>/). Run it against a live server, e.g. the
# local llama.cpp's OpenAI API:
#
#   ruby script/record_provider_fixtures.rb --api openai --url http://localhost:8080/v1 --model local-model
#
# --api picks the recorder and the default output dir (only openai so far);
# --url is the API base; --model the model sent; --out another output dir.
#
# Streams are saved byte for byte (*.sse), plain responses as *.json with a
# sibling *.status holding the HTTP status. Error fixtures that a local server
# can't produce (401, 429, 500, malformed bodies) are hand-written and carry
# "hand-written" in their file name; this script never touches them.

require "json"
require "net/http"
require "optparse"
require "uri"
require "fileutils"

RECORDERS = %w[openai].freeze

options = { api: "openai", url: nil, model: "local-model", out: nil }
parser = OptionParser.new do |opts|
  opts.banner = "Usage: #{File.basename(__FILE__)} --api API --url URL [--model MODEL] [--out DIR]"
  opts.on("--api API", "the wire to record (#{RECORDERS.join(", ")}); default openai") { |value| options[:api] = value }
  opts.on("--url URL", "the API base, e.g. http://localhost:8080/v1 (required)") { |value| options[:url] = value }
  opts.on("--model MODEL", "the model to ask; default local-model") { |value| options[:model] = value }
  opts.on("--out DIR", "where to write; default spec/fixtures/providers/<api>") { |value| options[:out] = value }
end
begin
  rest = parser.parse(ARGV)
rescue OptionParser::ParseError => e
  abort("#{e.message}\n#{parser.banner}")
end
abort("unexpected arguments: #{rest.join(" ")} (pass the API base as --url)\n#{parser.banner}") unless rest.empty?
abort("--url is required\n#{parser.banner}") if options[:url].to_s.empty?
abort("no recorder for api #{options[:api]} (#{RECORDERS.join(", ")})") unless RECORDERS.include?(options[:api])

base = options[:url].chomp("/")
model = options[:model]
out_dir = options[:out] || File.expand_path("../spec/fixtures/providers/#{options[:api]}", __dir__)
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
