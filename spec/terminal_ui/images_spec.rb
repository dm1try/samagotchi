# frozen_string_literal: true

require "tmpdir"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require "spec_helper"
require_relative "../support/recording_surface"

# `@path` images in the terminal UIs and the lines that show them.
RSpec.describe "TerminalUI images" do
  let(:png) { File.expand_path("../fixtures/images/tiny.png", __dir__) }
  let(:ref) { { file: "images/0123456789abcdef.png", mime: "image/png", width: 1280, height: 800, name: "shot.png", source: "user" } }

  describe Samagotchi::TerminalUI::ImageInput do
    around { |example| Dir.mktmpdir { |dir| @dir = dir; example.run } }

    def extract(text) = described_class.extract(text, cwd: @dir)

    before do
      FileUtils.cp(png, File.join(@dir, "shot.png"))
      FileUtils.cp(png, File.join(@dir, "my shot.png"))
      File.write(File.join(@dir, "notes.png"), "text")
      File.write(File.join(@dir, "main.rb"), "puts 1")
    end

    it "finds @paths that are images, relative to cwd, absolute, or quoted" do
      expect(extract("look at @shot.png and @#{png}")).to eq([{ path: File.join(@dir, "shot.png") }, { path: png }])
      expect(extract(%(compare @"my shot.png" with @'my shot.png'))).to eq([{ path: File.join(@dir, "my shot.png") }])
    end

    it "takes a bare path with backslash-escaped spaces and parens (a Finder drag)" do
      FileUtils.cp(png, File.join(@dir, "a (1).png"))
      expect(extract("look at @my\\ shot.png please")).to eq([{ path: File.join(@dir, "my shot.png") }])
      expect(extract("@#{@dir}/a\\ \\(1\\).png, ok?")).to eq([{ path: File.join(@dir, "a (1).png") }])
    end

    it "still ends a bare path at an unescaped space" do
      expect(extract("@my shot.png")).to eq([])
    end

    it "strips trailing punctuation" do
      expect(extract("what's in @shot.png?")).to eq([{ path: File.join(@dir, "shot.png") }])
    end

    it "leaves emails, missing files, source files and text named .png alone" do
      expect(extract("mail a@shot.png or me@b.c; @missing.png @main.rb @notes.png")).to eq([])
    end

    it "expands ~" do
      home = ENV["HOME"]
      ENV["HOME"] = @dir
      expect(described_class.extract("@~/shot.png", cwd: "/")).to eq([{ path: File.join(@dir, "shot.png") }])
    ensure
      ENV["HOME"] = home
    end
  end

  describe "lines" do
    def view(color:)
      Class.new do
        include Samagotchi::TerminalUI::Formatting

        def initialize(color) = @color = color
        def color_output? = @color
      end.new(color)
    end

    it "shows an image as one dim line, plain without a terminal" do
      expect(view(color: false).format_image_line(ref)).to eq("[image shot.png 1280×800 · ~1.3k tokens]")
      expect(view(color: true).format_image_line(ref)).to eq("\e[90m[image shot.png 1280×800 · ~1.3k tokens]\e[0m")
      expect(view(color: false).format_image_line(ref.transform_keys(&:to_s))).to include("shot.png 1280×800")
    end

    it "adds → image W×H to a tool line" do
      expect(view(color: false).format_tool_image_suffix([ref])).to eq(" → image 1280×800")
      expect(view(color: false).format_tool_image_suffix(nil)).to eq("")
    end

    it "renders turn_started's images and a read line's image through the EventRenderer" do
      surface = RecordingSurface.new(columns: 50)
      attached_view = Samagotchi::TerminalUI::AttachedView.new(surface)
      allow(attached_view).to receive(:color_output?).and_return(false)
      renderer = Samagotchi::TerminalUI::EventRenderer.new(attached_view)
      renderer.call("type" => "turn_started", "prompt" => "look @shot.png", "images" => [ref.transform_keys(&:to_s)])
      renderer.call(type: :tool_call_started, iteration: 1, call_index: 1, tool: "read")
      renderer.call(type: :tool_call_completed, iteration: 1, call_index: 1, tool: "read", images: [ref],
                    activity: { action: "reading file", tool: "read", params: "path=shot.png", status: "ok" })

      expect(surface.lines).to include("[image shot.png 1280×800 · ~1.3k tokens]",
                                       a_string_matching(/\Atool> reading file \(read path=shot.png\): ok.* → image 1280×800\z/))
    end
  end

  describe Samagotchi::TerminalUI::AttachedLoop do
    let(:screen) { RecordingSurface.new(columns: 100) }
    let(:stream) { double("stream", close: nil) }
    let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-images") }
    let(:ack) { Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e1"}') }

    def snapshot(messages: [], current_turn: nil)
      { "type" => "snapshot", "snapshot" => { "messages" => messages, "current_turn" => current_turn, "queued" => [], "event_seq" => 1 } }
    end

    def run_with(inputs, first: snapshot, loop: described_class.new(client: client, screen: screen, client_id: "tui:1"))
      allow(client).to receive(:follow) do |&block|
        block.call(first)
        stream
      end
      loop.run(input: ->(_prompt, _prefill) { inputs.shift })
    end

    it "stores @path images in the session and sends refs (chi -p too)" do
      allow(client).to receive(:post_turn).and_return(ack)
      first = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "what is @#{png}")

      run_with([], loop: first)

      expect(client).to have_received(:post_turn) do |prompt:, images:, **|
        expect(prompt).to eq("what is @#{png}")
        expect(images).to eq([{ file: images.first[:file], name: "tiny.png" }])
        dir = Samagotchi::Session.session_dir("s-images")
        expect(File.binread(File.join(dir, images.first[:file]))).to eq(File.binread(png))
      end
    end

    # The worker reads the refs under its own state dir: the one this TUI
    # found it in, not the default one.
    it "stores @path images under the worker's state dir" do
      allow(client).to receive(:post_turn).and_return(ack)
      Dir.mktmpdir("attach-state") do |state_dir|
        first = described_class.new(client: client, screen: screen, client_id: "tui:1", first_prompt: "what is @#{png}",
                                    state_dir: state_dir)

        run_with([], loop: first)

        expect(client).to have_received(:post_turn) do |images:, **|
          dir = Samagotchi::Session.session_dir("s-images", state_dir: state_dir)
          expect(File.binread(File.join(dir, images.first[:file]))).to eq(File.binread(png))
        end
      end
    end

    it "says why when an image can't be attached, and sends nothing" do
      allow(client).to receive(:post_turn)
      allow(Samagotchi::ImageStore).to receive(:ingest).and_raise(Samagotchi::ImageStore::Error, "tiny.png is too large")

      run_with(["look @#{png}"])

      expect(client).not_to have_received(:post_turn)
      expect(screen.lines).to include("could not attach the image: tiny.png is too large")
    end

    it "shows the image lines of the last prompt when it joins, and of a turn in progress" do
      allow(described_class).to receive(:new).and_call_original
      messages = [{ "role" => "user", "content" => "look", "images" => [ref.transform_keys(&:to_s)] }, { "role" => "model", "content" => "red" }]
      run_with([], first: snapshot(messages: messages))
      expect(screen.lines).to include(a_string_including("[image shot.png 1280×800 · ~1.3k tokens]"))

      screen.lines.clear
      turn = { "prompt" => "and this?", "origin" => { "client_id" => "web:1" }, "parts" => [], "images" => [ref.transform_keys(&:to_s)] }
      run_with([], first: snapshot(current_turn: turn))
      expect(screen.lines).to include(a_string_including("[image shot.png 1280×800 · ~1.3k tokens]"))
    end
  end
end
