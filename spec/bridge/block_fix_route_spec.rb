# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "socket"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/bridge"
require "support/bridge_parts"

# POST /session/:id/blocks/fix, the feature, and the turn's drawing written
# again when a fix patched the answer's text.
RSpec.describe Samagotchi::Bridge::BlockFixRoute do
  include BridgeParts

  let(:state_dir) { Dir.mktmpdir("bridge-block-fix") }
  let(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:bad) { "graph TD\n  A--B\n" }
  let(:answer) { { role: "model", content: "```mermaid\n#{bad}```\n", at: "2026-11-21T10:00:00Z" } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: state_dir).tap do |session|
      session.messages = [{ role: "system", content: "head" }, { role: "user", content: "draw", turn_id: "t1" }, answer]
    end
  end

  before do
    WebMock.allow_net_connect! if defined?(WebMock)
    side = instance_double(Samagotchi::IdleClient)
    allow(side).to receive(:ask) { Samagotchi::IdleClient::Summary.new(text: "```mermaid\ngraph TD\n  A-->B\n```", model: "m") }
    allow(Samagotchi::IdleClient).to receive(:for).and_return(side)
    engine.session = session
    @bridge = Samagotchi::Bridge.new(engine: engine, **bridge_parts(engine), state_dir: state_dir, session_id: session.id, heartbeat_interval: 0.2)
    @bridge.start
    sidecar = File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), "bridge.json")
    @port, @secret, @features = JSON.parse(File.read(sidecar)).values_at("port", "secret", "features")
  end

  after do
    @bridge.stop
    WebMock.disable_net_connect! if defined?(WebMock)
    FileUtils.remove_entry(state_dir)
  end

  def post(body)
    sock = TCPSocket.new("127.0.0.1", @port)
    payload = body.is_a?(String) ? body : JSON.generate(body)
    sock.write("POST /session/#{session.id}/blocks/fix HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n" \
               "X-Chi-Bridge: #{@secret}\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\n\r\n#{payload}")
    raw = sock.read
    sock.close
    head, rest = raw.split("\r\n\r\n", 2)
    [head.lines.first.split(" ", 3).then { |_, code, reason| [code.to_i, reason.strip] }, JSON.parse(rest)].flatten(1)
  end

  it "names the feature in the sidecar" do
    expect(@features).to include("block_fix")
  end

  it "answers 400 without a turn id, a fence language or a source" do
    expect(post({ lang: "mermaid", source: bad })[0]).to eq(400)
    expect(post({ turn_id: "t1", lang: "Mer maid", source: bad })[2]).to include("error" => "missing_fields")
    expect(post({ turn_id: "t1", lang: "mermaid", source: "" })[0]).to eq(400)
    expect(post("nope")[2]).to eq("error" => "invalid_json")
  end

  it "relays Engine#fix_block: 202 running, 409 for another block, 413 Content Too Large" do
    expect(post({ turn_id: "t1", lang: "mermaid", source: bad, reason: "Parse error" })).to eq([202, "Accepted", { "state" => "running" }])
    expect(post({ turn_id: "t1", lang: "mermaid", source: "graph LR" })[2]).to include("error" => "block_not_found")
    expect(post({ turn_id: "t1", lang: "mermaid", source: "x" * (17 * 1024) })[0..1]).to eq([413, "Content Too Large"])
  end

  describe "the turn's drawing" do
    let(:drawings_path) { File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), "turn_drawings.jsonl") }
    let(:digest) { ->(message) { Samagotchi::Bridge::TurnDrawings.digest(message) } }

    def write_line(to_digest)
      line = { v: 1, turn_id: "t1", kind: "completed", from: 1, to: 3, from_digest: digest.call(session.messages[1]),
               to_digest: to_digest, drawing: { prompt: "draw", turn_id: "t1", parts: [] }, end: { type: "turn_completed" } }
      FileUtils.mkdir_p(File.dirname(drawings_path))
      File.write(drawings_path, "#{JSON.generate(line)}\n")
    end

    def lines = Samagotchi::Bridge::TurnDrawings.parse(File.read(drawings_path))

    it "is written again with the patched answer's digest, so a reload still draws the turn from it" do
      write_line(digest.call(answer))
      post({ turn_id: "t1", lang: "mermaid", source: bad, reason: "Parse error" })
      wait_for("the fix to be ready") { engine.block_fixes_running.empty? }
      expect(engine.apply_block_fixes).to eq(1)

      expect(lines.size).to eq(2)
      expect(lines.last.to_digest).to eq(digest.call(engine.session.messages.last))
      expect(Samagotchi::Bridge::TurnDrawings.valid(lines, engine.session.messages).map(&:turn_id)).to eq(["t1"])
    end

    it "is left as it is when it doesn't end on the answer as it was, or the fix landed in the display" do
      write_line("other")
      engine.synchronize_events do
        engine.event_log.notify(type: :block_fix, turn_id: "t1", landed: "answer",
                                was_digest: digest.call(answer), digest: "new")
        engine.event_log.notify(type: :block_fix, turn_id: "t1", landed: "display",
                                was_digest: "other", digest: "other")
      end
      expect(lines.size).to eq(1)
    end
  end
end
