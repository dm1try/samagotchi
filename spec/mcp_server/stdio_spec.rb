# frozen_string_literal: true

require "spec_helper"
require "samagotchi/mcp_server/protocol"
require "samagotchi/mcp_server/stdio"

# McpServer::Stdio over pipes, a fake tools object behind the protocol.
RSpec.describe Samagotchi::McpServer::Stdio do
  let(:release) { Queue.new }
  let(:tools) do
    double("tools").tap do |fake|
      allow(fake).to receive(:list).and_return([{ name: "echo" }, { name: "hold" }])
      allow(fake).to receive(:call) do |name, arguments|
        release.pop if name == "hold"
        { content: [{ type: "text", text: "#{name}:#{arguments["text"]}" }], structuredContent: {}, isError: false }
      end
    end
  end
  let(:protocol) { Samagotchi::McpServer::Protocol.new(tools: tools) }
  let(:meta) { { "_meta" => { "io.modelcontextprotocol/protocolVersion" => "2026-07-28" } } }

  def line(id, method, params = nil) = "#{JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params }.compact)}\n"

  # Every line of +text+ is one JSON object.
  def answers(text)
    text.lines.map do |out|
      expect(out).to end_with("\n")
      JSON.parse(out)
    end
  end

  def run(input, **)
    output = StringIO.new
    described_class.new(protocol, input: StringIO.new(input), output: output, **).run
    answers(output.string)
  end

  it "serves a legacy exchange: initialize locks the era, a notification is answered with nothing" do
    out = run(line(1, "initialize", { protocolVersion: "2025-06-18" }) +
              %({"jsonrpc":"2.0","method":"notifications/initialized"}\n) +
              line(2, "tools/list") + line(3, "tools/call", { name: "echo", arguments: { text: "hi" } }) +
              line(4, "server/discover", meta))
    expect(out.map { |a| a["id"] }).to contain_exactly(1, 2, 3, 4)
    by_id = out.to_h { |a| [a["id"], a] }
    expect(by_id[1]["result"]["protocolVersion"]).to eq("2025-06-18")
    expect(by_id[3]["result"]["content"].first["text"]).to eq("echo:hi")
    expect(by_id[3]["result"]).not_to include("resultType")
    # Locked legacy: a later server/discover isn't served.
    expect(by_id[4]["error"]["code"]).to eq(-32_601)
  end

  it "serves a modern exchange: server/discover locks it, results carry resultType, initialize is refused" do
    out = run(line(1, "server/discover", meta) + line(2, "tools/call", { name: "echo", arguments: {}, **meta }) +
              line(3, "initialize", { protocolVersion: "2025-06-18" }))
    by_id = out.to_h { |a| [a["id"], a] }
    expect(by_id[1]["result"]["supportedVersions"]).to eq(["2026-07-28"])
    expect(by_id[2]["result"]["resultType"]).to eq("complete")
    expect(by_id[3]["error"]["code"]).to eq(-32_601)
  end

  it "answers a tools/list while a call holds, then the call, then stops at EOF" do
    reader, writer = IO.pipe
    out_reader, out_writer = IO.pipe
    loaded = []
    server = Thread.new do
      described_class.new(protocol, input: reader, output: out_writer, before_call: -> { loaded << :once }).run
    ensure
      out_writer.close
    end
    writer.write(line(1, "initialize", {}) + line(2, "tools/call", { name: "hold" }) + line(3, "tools/call", { name: "echo" }) +
                 line(4, "tools/list"))
    seen = Array.new(3) { JSON.parse(out_reader.gets)["id"] }
    expect(seen).to contain_exactly(1, 3, 4)
    writer.close
    release << :go
    expect(JSON.parse(out_reader.gets)["id"]).to eq(2)
    expect(server.value).to eq(0)
    expect(loaded).to eq([:once])
  end

  it "lets go of finished call threads as it goes, still joining a running one at EOF" do
    reader, writer = IO.pipe
    out_reader, out_writer = IO.pipe
    stdio = described_class.new(protocol, input: reader, output: out_writer)
    server = Thread.new { stdio.run.tap { out_writer.close } }
    6.times do |i|
      writer.write(line(i, "tools/call", { name: "echo" }))
      expect(JSON.parse(out_reader.gets)["id"]).to eq(i)
    end
    writer.write(line(9, "tools/call", { name: "hold" }))
    Thread.pass until stdio.instance_variable_get(:@calls).last&.status == "sleep"
    expect(stdio.instance_variable_get(:@calls).size).to be <= 2
    writer.close
    release << :go
    expect(JSON.parse(out_reader.gets)["id"]).to eq(9)
    expect(server.value).to eq(0)
  end

  it "answers unparseable text with -32700 and goes on" do
    out = run("{nope\n#{line(2, "ping")}")
    expect(out.map { |a| a.dig("error", "code") || a["result"] }).to eq([-32_700, {}])
  end

  it "answers a line that isn't valid UTF-8 with -32700 (its id when it can be read) and goes on" do
    out = run("\xff\n" + %({"jsonrpc":"2.0","id":4,"method":"ping","params":{"x":"\xff"}}\n) + line(2, "ping"))
    expect(out.map { |a| [a["id"], a.dig("error", "code") || a["result"]] }).to eq([[nil, -32_700], [4, -32_700], [2, {}]])
  end

  it "answers a line that isn't an object (a batch, null, a number) with -32600 and goes on" do
    out = run(%([{"jsonrpc":"2.0","id":1,"method":"ping"}]\nnull\n3\n#{line(2, "ping")}))
    expect(out.map { |a| a.dig("error", "code") || a["result"] }).to eq([-32_600, -32_600, -32_600, {}])
  end

  it "answers a call whose result isn't valid UTF-8 (scrubbed), and one that can't be written at all (-32603)" do
    allow(tools).to receive(:call) do |name, _arguments|
      text = name == "echo" ? "bad \xff byte" : Float::NAN
      { content: [{ type: "text", text: text }], isError: false }
    end
    out = run(line(1, "tools/call", { name: "echo" }) + line(2, "tools/call", { name: "hold" }))
    by_id = out.to_h { |a| [a["id"], a] }
    expect(by_id[1]["result"]["content"].first["text"]).to eq("bad \uFFFD byte")
    expect(by_id[2]["error"]).to include("code" => -32_603)
  end

  it "drops answers once the host closed its end (EPIPE), and still returns" do
    output = instance_double(IO)
    allow(output).to receive(:write).and_raise(Errno::EPIPE)
    logged = []
    status = described_class.new(protocol, input: StringIO.new(line(1, "ping") + line(2, "ping")), output: output,
                                           log: ->(text) { logged << text }).run
    expect(status).to eq(0)
    expect(output).to have_received(:write).once
    expect(logged).to include("mcp: the host closed its end; answers dropped")
  end
end
