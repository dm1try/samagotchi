# frozen_string_literal: true

require "tmpdir"
require "samagotchi/kernel_loop"
require "samagotchi/llm/chat_loop"
require "samagotchi/tools/read"
require "samagotchi/vision_support"
require_relative "support/fake_chat_adapter"

# `read` on an image: the model gets the picture (native and chat), or a
# line saying why it can't.
RSpec.describe "read on images" do
  let(:dir) { Dir.mktmpdir("chi-session") }
  let(:png_path) { File.expand_path("fixtures/images/tiny.png", __dir__) }
  let(:png64) { [File.binread(png_path)].pack("m0") }
  let(:limits) { Samagotchi::ImageStore::Limits.new(max_side: 1568, max_bytes: 3_750_000, max_per_request: 20) }
  let(:vision) { Samagotchi::VisionContext.new(session_dir: dir, limits: limits, resizer: Samagotchi::ImageResizer.new(nil)) }
  let(:blind) { vision.with(capability: Samagotchi::VisionSupport::Answer.new(value: false, reason: "hosts.main sets vision: false")) }

  after { FileUtils.rm_rf(dir) }

  describe Samagotchi::Tools::Read do
    it "answers an image with a line and the file to attach" do
      result = described_class.call(png_path)
      expect(result).to eq("Image tiny.png (3×2 PNG) attached.")
      expect(result.image_path).to eq(png_path)
    end

    it "knows an image by its bytes, not its name" do
      Dir.mktmpdir do |tmp|
        noext = File.join(tmp, "screenshot")
        FileUtils.cp(png_path, noext)
        expect(described_class.call(noext)).to respond_to(:image_path)
        text = described_class.call(File.expand_path("fixtures/images/text.png", __dir__))
        expect(text).to eq("not really a png\n")
        expect(text).not_to respond_to(:image_path)
      end
    end

    it "refuses a line range on an image" do
      expect(described_class.call(png_path, start_line: 1, end_line: 2)).to match(/is an image; read it without start_line/)
    end
  end

  describe "ToolRunner" do
    let(:kernel) { Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client)) }
    let(:events) { [] }

    def run_read
      Samagotchi::ToolRunner.new(kernel).run({ name: "read", content: png_path }, iteration: 1, call_index: 1, call_count: 1,
                                                                                  on_stream_event: ->(e) { events << e }, max_tool_output_chars: nil)
    end

    it "stores the image with the session and returns its ref on the run and the event" do
      kernel.turn_settings = kernel.turn_settings.with(vision: vision)
      run = run_read
      expect(run[:output]).to eq("[read]\nImage tiny.png (3×2 PNG) attached.")
      expect(run[:images].first).to include(name: "tiny.png", source: "tool", width: 3, height: 2)
      expect(File.exist?(File.join(dir, run[:images].first[:file]))).to be(true)
      expect(events.last).to include(type: :tool_call_completed, images: run[:images])
    end

    it "tells the model it can't see images, and attaches nothing" do
      kernel.turn_settings = kernel.turn_settings.with(vision: blind)
      run = run_read
      expect(run[:output]).to eq("[read]\ntiny.png (3×2 PNG) is an image; this model can't see images")
      expect(run).not_to have_key(:images)
      expect(events.last).not_to have_key(:images)
      expect(Dir.exist?(File.join(dir, "images"))).to be(false)
    end

    it "says the image can't be attached without a session" do
      expect(run_read[:output]).to eq("[read]\ntiny.png (3×2 PNG) is an image; images can't be attached here")
    end
  end

  describe "the native loop" do
    let(:client) { instance_double(Samagotchi::Client) }
    let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.qwen36) }
    let(:marker) { Samagotchi::ImagePlan::NATIVE_PLACEHOLDER }

    before do
      allow(client).to receive(:transport).and_return(Samagotchi::Client::Transport.new(:llama_cpp))
      allow(client).to receive(:context_window).and_return(nil)
      allow(client).to receive(:server_props).and_return(nil)
    end

    it "sends the picture after the joined tool results, with the images on the tool_response" do
      calls = []
      allow(client).to receive(:complete) do |prompt, **kwargs|
        calls << [prompt, kwargs]
        if calls.size == 1
          "<tool_call><function=read><parameter=path>#{png_path}</parameter></function></tool_call>"
        else
          "a red square"
        end
      end
      kernel.turn_settings = kernel.turn_settings.with(vision: vision)

      result = kernel.run([{ role: "user", content: "check #{png_path} and describe it" }])

      expect(result.output).to eq("a red square")
      prompt, kwargs = calls.last
      expect(prompt).to include("Image tiny.png (3×2 PNG) attached.\n[image 1: tiny.png] <|vision_start|>#{marker}<|vision_end|></tool_response>")
      expect(kwargs[:images]).to eq([png64])
      expect(result.conversation.find { |m| m[:role] == "tool_response" }[:images].first).to include(source: "tool")
    end
  end

  describe "the chat loop" do
    let(:kernel) { Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client)) }
    let(:adapter) do
      FakeChatAdapter.new(FakeChatAdapter.tools(["c1", "read", { "path" => png_path }]),
                          FakeChatAdapter.text("a red square"))
    end

    it "follows the tool message with a user message holding the picture (tool messages take text only)" do
      kernel.turn_settings = kernel.turn_settings.with(vision: vision)
      result = Samagotchi::LLM::ChatLoop.new(kernel: kernel, adapter: adapter)
                                        .complete(messages: [{ role: "user", content: "check the png" }], model_name: "m")

      expect(result.text).to eq("a red square")
      wire = adapter.requests.last[:messages]
      expect(wire.map { |m| m[:role] }).to eq(%w[user assistant tool user])
      expect(wire[2][:content]).to eq("[read]\nImage tiny.png (3×2 PNG) attached.")
      expect(wire[3][:content]).to eq([{ type: "text", text: "[images from tool results]" },
                                       { type: "image_url", image_url: { url: "data:image/png;base64,#{png64}" } }])
      expect(result.conversation.find { |m| m[:role] == "tool_response" }).to include(:images)
    end
  end
end
