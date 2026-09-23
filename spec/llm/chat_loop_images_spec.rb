# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/llm/chat_loop"
require "samagotchi/vision_support"
require_relative "../support/fake_chat_adapter"
require_relative "../support/fake_provider_server"

RSpec.describe "ChatLoop images" do
  let(:dir) { Dir.mktmpdir("chi-session") }
  let(:none) { Samagotchi::ImageResizer.new(nil) }
  let(:limits) { Samagotchi::ImageStore::Limits.new(max_side: 1568, max_bytes: 3_750_000, max_per_request: 20) }
  let(:png) { Samagotchi::ImageStore.ingest(dir, path: fixture("tiny.png"), resizer: none, limits: limits) }
  let(:gif) { Samagotchi::ImageStore.ingest(dir, path: fixture("tiny.gif"), resizer: none, limits: limits, source: "tool") }
  let(:png_uri) { "data:image/png;base64,#{[File.binread(fixture("tiny.png"))].pack("m0")}" }
  let(:gif_uri) { "data:image/gif;base64,#{[File.binread(fixture("tiny.gif"))].pack("m0")}" }
  let(:capability) { nil }
  let(:vision) { Samagotchi::VisionContext.new(capability: capability, session_dir: dir, limits: limits) }
  let(:kernel) do
    double("kernel", hooks: nil, vision: vision).tap do |k|
      allow(k).to receive(:strip_model_thought) { |text| text }
      allow(k).to receive(:dispatch_tool_call) { |call| { output: "[#{call[:name]}] ok", activity: nil } }
    end
  end
  let(:loop) { Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: FakeChatAdapter.new(FakeChatAdapter.text("seen"))) }

  after { FileUtils.rm_rf(dir) }

  def fixture(name) = File.expand_path("../fixtures/images/#{name}", __dir__)

  def image(uri) = { type: "image_url", image_url: { url: uri } }

  def tool_turn(images)
    [{ role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: { "path" => "a.gif" } }] },
     { role: "tool_response", content: "[read]\nImage a.gif attached.", tool_call_id: "c1", images: images }]
  end

  it "sends a user message's images after its text" do
    wire = loop.wire_messages([{ role: "user", content: "what's this?", images: [png] }])
    expect(wire).to eq([{ role: "user", content: [{ type: "text", text: "what's this?" }, image(png_uri)] }])
  end

  it "scrubs invalid UTF-8 in the text part" do
    wire = loop.wire_messages([{ role: "user", content: "bad \xE2\x80 byte".dup.force_encoding("UTF-8"), images: [png] }])
    expect(wire.first[:content].first[:text]).to eq("bad ? byte")
  end

  it "keeps tool messages text-only and follows them with one user message holding their images" do
    wire = loop.wire_messages([{ role: "user", content: "check a.gif" }, *tool_turn([gif])])
    expect(wire[2]).to eq({ role: "tool", content: "[read]\nImage a.gif attached.", tool_call_id: "c1" })
    expect(wire[3]).to eq({ role: "user", content: [{ type: "text", text: "[images from tool results]" }, image(gif_uri)] })
    expect(wire.size).to eq(4)
  end

  it "puts several tool results' images in one follow-up message after the last result" do
    turn = [{ role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: {} }, { id: "c2", name: "read", arguments: {} }] },
            { role: "tool_response", content: "a", tool_call_id: "c1", images: [gif] },
            { role: "tool_response", content: "b", tool_call_id: "c2", images: [png] }]
    wire = loop.wire_messages(turn)
    expect(wire.map { |m| m[:role] }).to eq(%w[assistant tool tool user])
    expect(wire.last[:content].drop(1)).to eq([image(gif_uri), image(png_uri)])
  end

  context "when the model can't see images" do
    let(:capability) { Samagotchi::VisionSupport::Answer.new(value: false, reason: "hosts.or sets vision: false") }

    it "sends placeholders and no image_url" do
      wire = loop.wire_messages([{ role: "user", content: "look", images: [png] }, *tool_turn([gif])])
      expect(JSON.generate(wire)).not_to include("image_url")
      expect(wire.first[:content]).to eq([{ type: "text", text: "look\n[image tiny.png 3×2 not sent: this model can't see images]" }])
      expect(wire[2][:content]).to end_with("[image tiny.gif 7×6 not sent: this model can't see images]")
      expect(wire.size).to eq(3)
    end
  end

  it "sends only the newest max_per_request images (D6)" do
    tight = Samagotchi::VisionContext.new(session_dir: dir, limits: limits.with(max_per_request: 1))
    allow(kernel).to receive(:vision).and_return(tight)
    wire = loop.wire_messages([{ role: "user", content: "one", images: [png] }, { role: "model", content: "ok" },
                               { role: "user", content: "two", images: [gif] }])
    expect(wire[0][:content]).to eq([{ type: "text", text: "one\n[image tiny.png 3×2 not sent: only the newest 1 images are sent]" }])
    expect(wire[2][:content]).to eq([{ type: "text", text: "two" }, image(gif_uri)])
  end

  it "sends a placeholder for a ref whose file is gone or isn't valid" do
    wire = loop.wire_messages([{ role: "user", content: "x", images: [png.merge(file: "images/../../etc/passwd")] }])
    expect(wire.first[:content]).to eq([{ type: "text", text: "x\n[image tiny.png 3×2 not sent: the image file is missing]" }])
  end

  it "sends placeholders when the turn has no vision context" do
    allow(kernel).to receive(:vision).and_return(nil)
    wire = loop.wire_messages([{ role: "user", content: "x", images: [png] }])
    expect(JSON.generate(wire)).not_to include("image_url")
  end

  it "passes Array content through and adds the images after it" do
    wire = loop.wire_messages([{ role: "user", content: [{ type: "text", text: "a" }], images: [png] }])
    expect(wire.first[:content]).to eq([{ type: "text", text: "a" }, image(png_uri)])
  end

  it "counts an image's estimate, not its base64, when the server reports no usage" do
    result = loop.complete(messages: [{ role: "user", content: "x", images: [png] }], model_name: "m")
    expect(result.usage.prompt_tokens).to eq(Samagotchi::TokenUsage.estimate("x") + 1)
  end

  it "sends the image parts over HTTP in the OpenAI shape" do
    FakeProviderServer.without_webmock do
      server = FakeProviderServer.start
      begin
        server.enqueue("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
        adapter = Samagotchi::LLM::OpenAIChat.new(base_url: server.base_url, host_name: "box", env: {})
        Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
                                 .complete(messages: [{ role: "user", content: "what's this?", images: [png] }], model_name: "m")
        content = server.requests.last.json["messages"].first["content"]
        expect(content).to eq([{ "type" => "text", "text" => "what's this?" },
                               { "type" => "image_url", "image_url" => { "url" => png_uri } }])
      ensure
        server.stop
      end
    end
  end
end
