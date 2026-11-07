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

  describe "the Engine's turn" do
    it "names the session's folder under the state dir (XDG_STATE_HOME) in its TurnContext" do
      with_env("XDG_STATE_HOME" => @dir) do
        client = test_client
        kernel = test_kernel(client: client)
        seen = nil
        allow(kernel).to receive(:run) do |messages, context:, **|
          seen = context
          Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }])
        end
        engine = Samagotchi::Engine.new(client: client, kernel: kernel, profile: "qwen36")
        session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
        engine.run_turn(session, "hi")
        expect(seen.session_dir).to eq(File.join(@dir, "samagotchi", "sessions", session.id))
      end
    end

    it "has no session folder when it can't be named, logged, and the turn still runs" do
      client = test_client
      kernel = test_kernel(client: client)
      seen = nil
      allow(kernel).to receive(:run) do |messages, context:, **|
        seen = context
        Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages + [{ role: "model", content: "ok" }])
      end
      engine = Samagotchi::Engine.new(client: client, kernel: kernel, profile: "qwen36")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
      # The turn's first lookup of its folder is the context's (Engine#begin_turn):
      # that one raises, the later ones (its images' folder) answer.
      raised = false
      allow(Samagotchi::Session).to receive(:session_dir).and_wrap_original do |original, *args, **kwargs|
        next original.call(*args, **kwargs) if raised

        raised = true
        raise Samagotchi::Session::InvalidId, "bad"
      end
      allow(Samagotchi::Log).to receive(:warn).and_call_original

      engine.run_turn(session, "hi")

      expect(seen.session_dir).to be_nil
      expect(Samagotchi::Log).to have_received(:warn).with(:turn, "tool_output_save_failed", error: "Samagotchi::Session::InvalidId")
    end
  end
end
