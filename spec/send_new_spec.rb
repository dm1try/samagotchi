# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/send_command"

# chi send --new: a worker session started headlessly, the way the web start
# page does, so it shows in the web at once.
RSpec.describe Samagotchi::SendCommand, "--new" do
  let(:tmpdir) { Dir.mktmpdir("send-new") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:spawned) { [] }

  before do
    allow(Samagotchi::SessionManager).to receive(:spawn_session) do |**kwargs|
      spawned << kwargs
      Samagotchi::Session.new_session(mode: "assist", model_name: kwargs[:model_name] || "m",
                                      working_directory: kwargs[:working_directory] || Dir.pwd)
    end
  end

  after { FileUtils.rm_rf(tmpdir) }

  def run(*argv, stdin: StringIO.new(""))
    described_class.new(argv, stdin: stdin, stdout: out, stderr: err, state_dir: tmpdir).run
  end

  it "starts a session with the composed message and prints its full id" do
    expect(run("--new", "-m", "review this", stdin: StringIO.new("diff --git a b\n"))).to eq(0), err.string

    expect(spawned).to eq([{ prompt: "> diff --git a b\n\nreview this", working_directory: nil, model_name: nil,
                             state_dir: tmpdir }])
    expect(out.string).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}  started\n\z/)
    expect(err.string).to be_empty
  end

  it "passes --dir (expanded) and --model" do
    Dir.mktmpdir("proj") do |dir|
      expect(run("--new", "--dir", dir, "--model=Qwen-27B", "-m", "hi")).to eq(0), err.string
      expect(spawned.first).to include(working_directory: File.expand_path(dir), model_name: "Qwen-27B")

      expect(run("--new", "--dir=#{dir}/.", "--model", "M", "-m", "hi")).to eq(0), err.string
      expect(spawned.last).to include(working_directory: File.expand_path(dir), model_name: "M")
    end
  end

  it "takes no ids: one new session per call" do
    expect(run("--new", "-m", "hi", "3fa2")).to eq(2)
    expect(err.string).to include("--new takes no session ids", "Usage: chi send")
    expect(spawned).to be_empty
  end

  it "refuses a --dir that is not a folder" do
    expect(run("--new", "--dir", "/nope/not/here", "-m", "hi")).to eq(2)
    expect(err.string).to include("chi send: no folder /nope/not/here")
    expect(spawned).to be_empty
  end

  it "keeps --dir and --model to --new" do
    expect(run("--dir", "/tmp", "-m", "hi", "3fa2")).to eq(2)
    expect(run("--model", "M", "-m", "hi", "3fa2")).to eq(2)
    expect(err.string).to include("--dir needs --new", "--model needs --new")
  end

  it "is a usage error with no message" do
    expect(run("--new", "-m", " ")).to eq(2)
    expect(err.string).to include("no message")
    expect(spawned).to be_empty
  end

  it "reports a failed start in one line" do
    allow(Samagotchi::SessionManager).to receive(:spawn_session).and_raise(RuntimeError, "no default model")
    expect(run("--new", "-m", "hi")).to eq(1)
    expect(err.string).to eq("chi send: could not start a session: no default model\n")
  end
end
