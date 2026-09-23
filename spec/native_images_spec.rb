# frozen_string_literal: true

require "json"
require "tmpdir"
require "samagotchi/prompt"
require "samagotchi/client"
require "samagotchi/kernel_loop"
require_relative "support/fake_provider_server"

RSpec.describe "Native images" do
  let(:dir) { Dir.mktmpdir("chi-session") }
  let(:none) { Samagotchi::ImageResizer.new(nil) }
  let(:limits) { Samagotchi::ImageStore::Limits.new(max_side: 1568, max_bytes: 3_750_000, max_per_request: 20) }
  let(:png) { Samagotchi::ImageStore.ingest(dir, path: fixture("tiny.png"), resizer: none, limits: limits) }
  let(:gif) { Samagotchi::ImageStore.ingest(dir, path: fixture("tiny.gif"), resizer: none, limits: limits, source: "tool") }
  let(:png64) { [File.binread(fixture("tiny.png"))].pack("m0") }
  let(:gif64) { [File.binread(fixture("tiny.gif"))].pack("m0") }
  let(:vision) { Samagotchi::VisionContext.new(session_dir: dir, limits: limits) }
  let(:qwen) { Samagotchi::ModelProfile.qwen36 }
  let(:marker) { Samagotchi::ImagePlan::NATIVE_PLACEHOLDER }
  let(:props) { JSON.parse(File.read(File.expand_path("fixtures/llama_cpp/props_ornith.json", __dir__))) }

  after { FileUtils.rm_rf(dir) }

  def fixture(name) = File.expand_path("fixtures/images/#{name}", __dir__)

  describe "Prompt.format_with_images" do
    it "puts a user message's images after its text, one marker line each" do
      text, images = Samagotchi::Prompt.format_with_images([{ role: "user", content: "look", images: [png] }],
                                                           profile: qwen, vision: vision)
      expect(text).to eq("<|im_start|>user\nlook\n[image 1: tiny.png] <|vision_start|>#{marker}<|vision_end|><|im_end|>\n" \
                         "<|im_start|>assistant\n")
      expect(images).to eq([png64])
    end

    it "puts a joined tool_response's images at the end of the block, in call order" do
      text, images = Samagotchi::Prompt.format_with_images(
        [{ role: "tool_response", content: "[read]\nImage a.\n\n---\n\n[read]\nImage b.", images: [gif, png] }],
        profile: qwen, vision: vision
      )
      expect(text).to include("[read]\nImage b.\n[image 1: tiny.gif] <|vision_start|>#{marker}<|vision_end|>\n" \
                              "[image 2: tiny.png] <|vision_start|>#{marker}<|vision_end|></tool_response>")
      expect(images).to eq([gif64, png64])
    end

    it "writes placeholders for a profile with no image template" do
      text, images = Samagotchi::Prompt.format_with_images([{ role: "user", content: "look", images: [png] }],
                                                           profile: Samagotchi::ModelProfile.gemma4, vision: vision)
      expect(text).to include("look\n[image tiny.png 3×2 not sent: this model can't see images]")
      expect(images).to eq([])
    end

    it "writes placeholders when the model can't see images, and without a vision context" do
      blind = vision.with(capability: Samagotchi::VisionSupport::Answer.new(value: false, reason: "x"))
      [blind, nil].each do |context|
        text, images = Samagotchi::Prompt.format_with_images([{ role: "user", content: "look", images: [png] }],
                                                             profile: qwen, vision: context)
        expect(text).not_to include(marker)
        expect(images).to eq([])
      end
    end

    it "escapes Qwen's vision tokens typed in user text" do
      text = Samagotchi::Prompt.format([{ role: "user", content: "a <|vision_start|>x<|vision_end|>" }], profile: qwen)
      expect(text).not_to include("<|vision_start|>")
      expect(Samagotchi::PromptLiteralGuard.restore(text, profile: qwen)).to include("a <|vision_start|>x<|vision_end|>")
    end
  end

  describe "Client#complete with images" do
    around { |example| FakeProviderServer.without_webmock { example.run } }

    let(:server) { FakeProviderServer.start }
    let(:client) { Samagotchi::Client.new(host: "127.0.0.1", port: server.port, transport: :llama_cpp) }
    let(:prompt) { "<|im_start|>user\nlook\n<|vision_start|>#{marker}<|vision_end|><|im_end|>\n" }

    after { server.stop }

    it "sends prompt_string with the server's media marker and multimodal_data" do
      server.enqueue("/props", json: props)
      server.enqueue("/completion", sse: "data: {\"content\":\"red\"}\n\n")

      expect(client.complete(prompt, stop: ["<|im_end|>"], images: [png64])).to eq("red")
      body = server.requests.last.json
      expect(body["prompt"]).to eq("prompt_string" => prompt.sub(marker, props["media_marker"]), "multimodal_data" => [png64])
    end

    it "reads the marker again and retries once when the prompt fails to tokenize (a restarted server)" do
      server.enqueue("/props", json: props.merge("media_marker" => "<__media_old__>"))
      server.enqueue("/completion", status: 400, json: { error: { code: 400, message: "Failed to tokenize prompt" } })
      server.enqueue("/props", json: props)
      server.enqueue("/completion", sse: "data: {\"content\":\"ok\"}\n\n")

      expect(client.complete(prompt, images: [png64])).to eq("ok")
      expect(server.requests.map(&:path)).to eq(%w[/props /completion /props /completion])
      expect(server.requests.last.json.dig("prompt", "prompt_string")).to include(props["media_marker"])
    end

    it "retries only once" do
      server.default("/props", json: props)
      server.default("/completion", status: 400, json: { error: { code: 400, message: "Failed to tokenize prompt" } })

      expect { client.complete(prompt, images: [png64]) }.to raise_error(Samagotchi::LLM::BadRequest, /tokenize/)
      expect(server.requests.count { |r| r.path == "/completion" }).to eq(2)
    end

    it "refuses to send when /props has no marker" do
      server.default("/props", status: 503, json: { error: { message: "loading" } })

      expect { client.complete(prompt, images: [png64]) }
        .to raise_error(Samagotchi::LLM::VisionUnsupported, /can't reach \/props for the media marker/)
      expect(server.requests.map(&:path)).to eq(%w[/props])
    end
  end

  describe "KernelLoop" do
    let(:client) { instance_double(Samagotchi::Client) }
    let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: qwen) }

    before do
      allow(client).to receive(:transport).and_return(Samagotchi::Client::Transport.new(:llama_cpp))
      allow(client).to receive(:context_window).and_return(nil)
      allow(client).to receive(:server_props).and_return(nil)
    end

    it "passes the prompt's images to the client, and none on a text-only turn" do
      calls = []
      allow(client).to receive(:complete) { |prompt, **kwargs| calls << [prompt, kwargs]; "a red square" }
      kernel.vision = vision

      kernel.run([{ role: "user", content: "look", images: [png] }])
      kernel.run([{ role: "user", content: "no picture" }])

      expect(calls[0][0]).to include(marker)
      expect(calls[0][1][:images]).to eq([png64])
      expect(calls[1][1]).not_to have_key(:images)
    end
  end
end
