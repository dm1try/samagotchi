# frozen_string_literal: true

require "tmpdir"
require "samagotchi/kernel_loop"
require "samagotchi/tools/builtins"
require "samagotchi/vision_support"

# Any tool's result can carry images (a String that responds to #images):
# ToolRunner stores each one with the session, or adds a line saying why
# not, and keeps the tool's text.
RSpec.describe "tool results with images" do
  let(:dir) { Dir.mktmpdir("chi-session") }
  let(:png_path) { File.expand_path("fixtures/images/tiny.png", __dir__) }
  let(:gif_path) { File.expand_path("fixtures/images/tiny.gif", __dir__) }
  let(:limits) { Samagotchi::ImageStore::Limits.new(max_side: 1568, max_bytes: 3_750_000, max_per_request: 20) }
  let(:vision) { Samagotchi::VisionContext.new(session_dir: dir, limits: limits, resizer: Samagotchi::ImageResizer.new(nil)) }
  let(:blind) { vision.with(capability: Samagotchi::VisionSupport::Answer.new(value: false, reason: "hosts.main sets vision: false")) }
  let(:with_images) do
    Class.new(String) do
      attr_reader :images

      def initialize(text, images)
        @images = images
        super(text)
      end
    end
  end

  after { FileUtils.rm_rf(dir) }

  def registry_with(images, text: "two shots")
    klass = with_images
    Samagotchi::Tools::Builtins.registry.tap do |r|
      r.register("shots", schema: { parameters: { properties: {} } }, source: "sample-plugin",
                          handler: ->(*) { klass.new(text, images) })
    end
  end

  describe "ToolRunner" do
    let(:events) { [] }

    def run(images, vision: self.vision)
      kernel = Samagotchi::KernelLoop.new(client: instance_double(Samagotchi::Client), tools: registry_with(images))
      kernel.vision = vision
      Samagotchi::ToolRunner.new(kernel).run({ name: "shots", args: {} }, iteration: 1, call_index: 1, call_count: 1,
                                                                         on_stream_event: ->(e) { events << e }, max_tool_output_chars: nil)
    end

    it "stores every image, from a path or raw bytes, and keeps the text" do
      result = run([{ path: png_path }, { bytes: File.binread(gif_path), name: "shot.gif" }])
      expect(result[:output]).to eq("[shots]\ntwo shots")
      expect(result[:images].map { |ref| ref[:name] }).to eq(%w[tiny.png shot.gif])
      expect(result[:images].map { |ref| ref[:source] }).to eq(%w[tool tool])
      expect(result[:images]).to all(satisfy { |ref| File.exist?(File.join(dir, ref[:file])) })
      expect(events.last[:images]).to eq(result[:images])
    end

    it "keeps the text and the good images when one entry is bad" do
      result = run([{ path: png_path }, { bytes: "not an image", name: "junk.bin" }, { nope: 1 }, "x"])
      expect(result[:images].size).to eq(1)
      expect(result[:output]).to eq("[shots]\ntwo shots\nError: junk.bin is not an image chi can send (png, jpeg, gif, webp)\n" \
                                    "Error: image 3 is not {path:} or {bytes:, name:}\nError: image 4 is not {path:} or {bytes:, name:}")
    end

    it "attaches at most 4 images and says which were left out" do
      result = run(Array.new(6) { |i| { bytes: File.binread(png_path), name: "shot#{i + 1}.png" } })
      expect(result[:images].size).to eq(4)
      expect(result[:output]).to end_with("shot5.png is not attached: at most 4 images per tool result\n" \
                                          "shot6.png is not attached: at most 4 images per tool result")
    end

    it "tells a model that can't see images so, and keeps the text" do
      result = run([{ path: png_path }, { bytes: File.binread(gif_path), name: "shot.gif" }], vision: blind)
      expect(result[:output]).to eq("[shots]\ntwo shots\ntiny.png is an image; this model can't see images\n" \
                                    "shot.gif is an image; this model can't see images")
      expect(result).not_to have_key(:images)
      expect(Dir.exist?(File.join(dir, "images"))).to be(false)
    end

    it "caps raw bytes like a file (nothing over 50 MB is read)" do
      stub_const("Samagotchi::ImageStore::MAX_SOURCE_BYTES", 10)
      result = run([{ bytes: File.binread(png_path), name: "big.png" }])
      expect(result[:output]).to end_with("Error: big.png is too large (over 50 MB)")
    end
  end

  describe "the native loop" do
    let(:client) { instance_double(Samagotchi::Client) }
    let(:marker) { Samagotchi::ImagePlan::NATIVE_PLACEHOLDER }

    before do
      allow(client).to receive(:transport).and_return(Samagotchi::Client::Transport.new(:llama_cpp))
      allow(client).to receive(:context_window).and_return(nil)
      allow(client).to receive(:server_props).and_return(nil)
    end

    it "saves both images on the tool_response and sends them on the next request and a replay" do
      calls = []
      allow(client).to receive(:complete) do |prompt, **kwargs|
        calls << [prompt, kwargs]
        calls.size == 1 ? "<tool_call><function=shots></function></tool_call>" : "a red square and a gif"
      end
      kernel = Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.qwen36,
                                          tools: registry_with([{ path: png_path }, { path: gif_path }]))
      kernel.vision = vision

      result = kernel.run([{ role: "user", content: "take two shots" }])
      tool_response = result.conversation.find { |m| m[:role] == "tool_response" }
      expect(tool_response[:images].map { |ref| ref[:name] }).to eq(%w[tiny.png tiny.gif])
      expect(calls.last[1][:images].size).to eq(2)

      # A reload: the saved conversation (string keys) sends the same images.
      saved = JSON.parse(JSON.generate(result.conversation)).map { |m| m.transform_keys(&:to_sym) }
      calls.clear
      kernel.run(saved + [{ role: "user", content: "again?" }])
      expect(calls.first[1][:images].size).to eq(2)
      expect(calls.first[0].scan(marker).size).to eq(2)
    end
  end
end
