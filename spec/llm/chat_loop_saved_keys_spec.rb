# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "samagotchi/engine"
require "samagotchi/session"
require_relative "../support/fake_provider_server"

# ChatLoop#plain's rule (its comment): a saved message field the wire needs
# must be listed in its keys. #plain rebuilds every kept message from them,
# so an unlisted field on a turn's user message is gone from every later
# request, and the chat wires' prompt prefix breaks. Two turns of a real
# Engine (its own ChatLoop, nothing injected) over a FakeProviderServer on
# `api: openai` and `api: anthropic`: the first turn's user message, as the
# Engine handed it to the loop, must reach the second turn's loop with
# every field it had. A new field on a turn's user message joins the first
# turn here (as the visitor opener's source does), and fails until #plain
# lists it. Setup as in spec/engine_turn_golden_spec.rb.
RSpec.describe Samagotchi::LLM::ChatLoop, "#plain's saved keys (a turn's user message in a later request)" do
  wires = {
    "openai" => { model: "oai:chat-a", path: "/v1/chat/completions" },
    "anthropic" => { model: "ant:claude-a", path: "/v1/messages" }
  }

  let(:tmp) { File.realpath(Dir.mktmpdir("chat-loop-saved-keys")) }
  let(:project) { File.join(tmp, "project") }
  let(:state_dir) { File.join(tmp, "state", "samagotchi", "sessions") }
  let(:server) { FakeProviderServer.start }
  let(:handed) { [] }

  around do |example|
    FakeProviderServer.without_webmock do
      FileUtils.mkdir_p(project)
      with_config_home(File.join(tmp, "config")) do
        with_env("XDG_STATE_HOME" => File.join(tmp, "state")) do
          Dir.chdir(project) { example.run }
        end
      end
    end
  ensure
    server.stop
    FileUtils.rm_rf(tmp)
  end

  before do
    File.write(File.join(tmp, "config", "samagotchi", "config.yml"), YAML.dump(
      "default" => { "model" => "oai:chat-a" },
      "hosts" => {
        "oai" => { "host" => "127.0.0.1", "port" => server.port, "api" => "openai", "remote" => true },
        "ant" => { "url" => server.root_url, "api" => "anthropic", "remote" => true }
      },
      "models" => { "chat-a" => { "thinking" => "off" }, "claude-a" => { "thinking" => "off" } },
      "guardrails" => { "system_one" => { "mode" => "off" } },
      "toolkit" => { "suggest" => { "mode" => "off" } },
      "context" => { "candidates" => { "mode" => "off" } },
      "objectives" => { "system_one" => "off" },
      "recap" => { "enabled" => false },
      "cache" => { "warmup" => "off" }
    ))
    server.default("/v1/models", json: { data: [] })
    # What each turn handed the loop (its messages, before any request).
    allow_any_instance_of(described_class).to receive(:complete).and_wrap_original do |original, **options|
      handed << options[:messages].map(&:dup)
      original.call(**options)
    end
  end

  def reply_events(wire, text)
    if wire == "openai"
      chunk = lambda do |delta, finish = nil|
        "data: #{JSON.generate(id: "x", object: "chat.completion.chunk", created: 1, model: "m",
                               choices: [{ index: 0, delta: delta, finish_reason: finish }])}\n\n"
      end
      return [chunk.call({ role: "assistant", content: nil }), chunk.call({ content: text }), chunk.call({}, "stop"),
              "data: [DONE]\n\n"]
    end

    [{ type: "message_start", message: { id: "m", type: "message", role: "assistant", model: "m", content: [],
                                         stop_reason: nil, usage: { input_tokens: 100, output_tokens: 1 } } },
     { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
     { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: text } },
     { type: "content_block_stop", index: 0 },
     { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 10 } },
     { type: "message_stop" }].map { |event| "event: #{event[:type]}\ndata: #{JSON.generate(event)}\n\n" }.join
  end

  # The request's messages as JSON (anthropic: without cache_control, which
  # moves to the newest message by design).
  def wire_messages(request)
    messages = JSON.parse(request[:body] || request["body"])["messages"]
    JSON.parse(JSON.generate(messages).gsub(/,?"cache_control":\{[^}]*\}/, ""))
  end

  wires.each do |wire, spec|
    it "keeps every field of a turn's user message in the next turn's request (#{wire})" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: spec[:model], working_directory: project)
      engine = Samagotchi::Engine.new(host_registry: Samagotchi::HostRegistry.new, model_name: spec[:model])
      engine.interface = :worker
      engine.session_state_dir = state_dir
      engine.store_model!(session)
      engine.session = session

      server.enqueue(spec[:path], sse: reply_events(wire, "first answer"))
      engine.run_turn(session, "look at this", opener_source: "agent:codex",
                                               reply_for: { "formatting" => "plain", "room" => "short" })
      server.enqueue(spec[:path], sse: reply_events(wire, "second answer"))
      engine.run_turn(session, "and again")

      expect(handed.size).to eq(2)
      sent = handed.first.find { |message| message[:role].to_s == "user" && message[:turn_id] }
      expect(sent).to include(source: "agent:codex", reply_for: hash_including("formatting" => "plain"),
                              reply_line: start_with("[Reply for this message"))
      kept = handed.last.find { |message| message[:turn_id] == sent[:turn_id] && message[:role].to_s == "user" }
      expect(kept).not_to be_nil, "turn 1's user message (turn_id #{sent[:turn_id]}) is missing from turn 2's messages"
      missing = sent.keys.reject { |key| kept.key?(key) && kept[key] == sent[key] }
      expect(missing).to be_empty,
                         "turn 1's user message lost #{missing.inspect} before turn 2's request: ChatLoop#plain " \
                         "rebuilds saved messages from its key lists, and a saved message field the wire needs " \
                         "must be listed there (lib/samagotchi/llm/chat_loop.rb, #plain)"

      first, second = server.requests.select { |r| (r[:path] || r["path"]).to_s.start_with?(spec[:path]) }
                            .map { |request| wire_messages(request) }
      expect(JSON.generate(first)).to include("[From the agent codex, sent with chi send").and include("[Reply for this message")
      expect(second[0, first.size]).to eq(first), "turn 2's request doesn't extend turn 1's on #{wire}: the prefix broke"
    end
  end
end
