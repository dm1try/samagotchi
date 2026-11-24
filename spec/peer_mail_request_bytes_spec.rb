# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "yaml"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/session_observer"
require "samagotchi/turn_state"
require "samagotchi/worker_inbound"
require "samagotchi/worker_wakes"
require "samagotchi/context_absorber"
require "samagotchi/peer_mailbox"
require "samagotchi/peer_receipts"
require "samagotchi/peer_registry"
require_relative "support/fake_provider_server"

# A mail wake turn in the prompt cache's terms (docs/internals/prompt-caching.md):
# a peer's messages go in as tail notes between turns, so the wake turn's
# request is the previous request's bytes extended (append-only), and the
# turn after it extends the wake's, on the native, openai and anthropic
# wires. Setup as in spec/reply_for_history_spec.rb.
RSpec.describe "a mail wake turn's request (prompt-cache bytes)" do
  wires = {
    "native" => { model: "box:Qwen3.6", path: "/completion" },
    "openai" => { model: "oai:chat-a", path: "/v1/chat/completions" },
    "anthropic" => { model: "ant:claude-a", path: "/v1/messages" }
  }

  let(:tmp) { File.realpath(Dir.mktmpdir("peer-mail-bytes")) }
  let(:project) { File.join(tmp, "project") }
  let(:state_dir) { File.join(tmp, "state", "samagotchi", "sessions") }
  let(:server) { FakeProviderServer.start }

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
      "default" => { "model" => "box:Qwen3.6" },
      "hosts" => {
        "box" => { "host" => "127.0.0.1", "port" => server.port },
        "oai" => { "host" => "127.0.0.1", "port" => server.port, "api" => "openai", "remote" => true },
        "ant" => { "url" => server.root_url, "api" => "anthropic", "remote" => true }
      },
      "models" => {
        "Qwen3.6" => { "thinking" => "off" }, "chat-a" => { "thinking" => "off" }, "claude-a" => { "thinking" => "off" }
      },
      "guardrails" => { "system_one" => { "mode" => "off" } },
      "toolkit" => { "suggest" => { "mode" => "off" } },
      "context" => { "candidates" => { "mode" => "off" } },
      "objectives" => { "system_one" => "off" },
      "recap" => { "enabled" => false },
      "cache" => { "warmup" => "off" }
    ))
    server.default("/props", json: { "chat_template" => "<|im_start|> <function=",
                                     "default_generation_settings" => { "n_ctx" => 32_768 } })
    server.default("/v1/models", json: { data: [] })
  end

  def reply_events(wire, text)
    case wire
    when "native"
      ["data: #{JSON.generate(content: text, stop: false)}\n\n",
       "data: #{JSON.generate(content: "", stop: true, tokens_evaluated: 100, tokens_predicted: 10)}\n\n"]
    when "openai"
      chunk = lambda do |delta, finish = nil|
        "data: #{JSON.generate(id: "x", object: "chat.completion.chunk", created: 1, model: "m",
                               choices: [{ index: 0, delta: delta, finish_reason: finish }])}\n\n"
      end
      [chunk.call({ role: "assistant", content: nil }), chunk.call({ content: text }), chunk.call({}, "stop"), "data: [DONE]\n\n"]
    else
      [{ type: "message_start", message: { id: "m", type: "message", role: "assistant", model: "m", content: [],
                                           stop_reason: nil, usage: { input_tokens: 100, output_tokens: 1 } } },
       { type: "content_block_start", index: 0, content_block: { type: "text", text: "" } },
       { type: "content_block_delta", index: 0, delta: { type: "text_delta", text: text } },
       { type: "content_block_stop", index: 0 },
       { type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 10 } },
       { type: "message_stop" }].map { |event| "event: #{event[:type]}\ndata: #{JSON.generate(event)}\n\n" }.join
    end
  end

  def history(wire, request)
    body = JSON.parse(request[:body] || request["body"])
    case wire
    when "native" then body["prompt"]
    when "anthropic" then JSON.parse(JSON.generate([body["system"], body["messages"]]).gsub(/,?"cache_control":\{[^}]*\}/, ""))
    else body["messages"]
    end
  end

  def extends?(wire, before, after)
    case wire
    when "native" then after.start_with?(before.sub(%r{<\|im_start\|>assistant\n(<think>\n\n</think>\n\n)?\z}, ""))
    when "anthropic" then before[0] == after[0] && after[1][0, before[1].size] == before[1]
    else after[0, before.size] == before
    end
  end

  def histories(wire, path) = server.requests.select { |r| (r[:path] || r["path"]).to_s.start_with?(path) }
                                     .map { |request| history(wire, request) }

  wires.each do |wire, spec|
    it "extends the previous request with the peer's notes and the wake turn, then the next turn extends it (#{wire})" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: spec[:model], working_directory: project)
      engine = Samagotchi::Engine.new(host_registry: Samagotchi::HostRegistry.new, model_name: spec[:model])
      engine.interface = :worker
      engine.session_state_dir = state_dir
      engine.store_model!(session)
      engine.session = session
      registry = Samagotchi::PeerRegistry.new.tap { |r| r.declare("codex", bundle: "codex-peer") }
      inbound = Samagotchi::WorkerInbound.new(
        session: session, state_dir: state_dir, session_dir: Samagotchi::Session.session_dir(session.id, state_dir: state_dir),
        engine: engine, event_log: Samagotchi::SessionObserver.new, turn_state: Samagotchi::TurnState.new(clock: -> { 0.0 }),
        context_absorber: instance_double(Samagotchi::ContextAbsorber, pending: nil, commit: nil),
        wakes: Samagotchi::WorkerWakes.new(grace: 0, max: -> { 10 }, peer_max: -> { 3 }),
        awaiting_continue: -> { false }, stopped: -> { false }, queue_command: ->(*) {},
        peer_registry: registry, peer_receipts: Samagotchi::PeerReceipts.new(session_id: session.id, state_dir: state_dir),
        mail_cap: -> { 10_000 }
      )

      server.enqueue(spec[:path], sse: reply_events(wire, "sent it to codex"))
      engine.run_turn(session, "ask codex")
      %w[first second].each do |text|
        Samagotchi::PeerMailbox.post(session.id, "codex", text: text, summary: "#{text}: VERDICT CHANGES", wake: true,
                                                          re: "s-1", state_dir: state_dir)
      end
      wake = inbound.absorb_mail
      server.enqueue(spec[:path], sse: reply_events(wire, "fixed"))
      engine.run_turn(session, nil, continue: true, origin: wake.origin, id: wake.turn_id)
      server.enqueue(spec[:path], sse: reply_events(wire, "ok"))
      engine.run_turn(session, "thanks")

      sent = histories(wire, spec[:path])
      expect(sent.size).to eq(3)
      sent.each_cons(2).with_index do |(before, after), index|
        expect(extends?(wire, before, after)).to be(true), "request #{index + 1} → #{index + 2} broke the prefix on #{wire}"
      end
      wake_request = JSON.generate(sent[1])
      expect(wake_request).to include("Message #1 from your peer agent Codex", "Message #2 from your peer agent Codex")
      expect(wake_request.index("Message #1")).to be < wake_request.index("Message #2")
      expect(JSON.generate(sent[2]).scan("Message #2 from your peer agent Codex").size).to eq(1)
    end
  end
end
