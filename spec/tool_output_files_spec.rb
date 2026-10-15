# frozen_string_literal: true

require "tmpdir"
require "samagotchi/tool_output_files"
require "samagotchi/session"
require "samagotchi/engine"
require "support/test_kernel"

RSpec.describe Samagotchi::ToolOutputFiles do
  around do |example|
    Dir.mktmpdir("chi-tool-output") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:session_dir) { File.join(@dir, "session") }

  it "saves the text in the session's tool_output folder, named by the tool and the content" do
    saved = described_class.save(session_dir, "a\nb\nc", tool: "execute")

    expect(saved.path).to match(%r{\A#{Regexp.escape(session_dir)}/tool_output/execute-\h{12}\.txt\z})
    expect(File.binread(saved.path)).to eq("a\nb\nc")
    expect([saved.bytes, saved.lines]).to eq([5, 3])
  end

  it "gives the same text the same path, one file" do
    first = described_class.save(session_dir, "same\n", tool: "execute")
    second = described_class.save(session_dir, "same\n", tool: "execute")

    expect(second.path).to eq(first.path)
    expect(second.lines).to eq(1)
    expect(Dir.children(File.join(session_dir, "tool_output"))).to eq([File.basename(first.path)])
  end

  it "writes an emptied file again" do
    first = described_class.save(session_dir, "text", tool: "execute")
    File.write(first.path, "")
    described_class.save(session_dir, "text", tool: "execute")

    expect(File.read(first.path)).to eq("text")
  end

  it "makes a plugin's tool name safe for a file name" do
    saved = described_class.save(session_dir, "x", tool: "mcp/Some Tool")
    expect(File.basename(saved.path)).to start_with("mcp_some_tool-")
  end

  it "keeps the newest MAX_FILES, by mtime" do
    stub_const("#{described_class}::MAX_FILES", 2)
    paths = %w[one two three].each_with_index.map do |text, i|
      described_class.save(session_dir, text, tool: "execute").path.tap { |p| File.utime(Time.at(1000 + i), Time.at(1000 + i), p) }
    end
    described_class.save(session_dir, "two", tool: "execute") # touched: newest again

    expect(paths.map { |p| File.exist?(p) }).to eq([false, true, true])
    described_class.save(session_dir, "four", tool: "execute")
    expect(paths.map { |p| File.exist?(p) }).to eq([false, true, false])
  end

  it "raises when it can't write" do
    allow(Samagotchi::AtomicFile).to receive(:write).and_raise(Errno::ENOSPC)
    expect { described_class.save(session_dir, "x", tool: "execute") }.to raise_error(Errno::ENOSPC)
  end

  describe "the Engine's kernel" do
    it "names the session's folder under the state dir (XDG_STATE_HOME)" do
      with_env("XDG_STATE_HOME" => @dir) do
        client = test_client
        engine = Samagotchi::Engine.new(client: client, kernel: test_kernel(client: client), profile: "qwen36")
        kernel = engine.instance_variable_get(:@kernel)
        expect(kernel.session_dir.call).to be_nil

        session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
        engine.session = session
        expect(kernel.session_dir.call).to eq(File.join(@dir, "samagotchi", "sessions", session.id))
      end
    end
  end
end
