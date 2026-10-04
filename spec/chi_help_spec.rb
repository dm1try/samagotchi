# frozen_string_literal: true

require "open3"
require "rbconfig"
require "samagotchi/version"
require_relative "support/bounded_capture"

RSpec.describe "chi --help" do
  let(:chi) { File.expand_path("../bin/chi", __dir__) }

  it "says -p runs the prompt and stays in the REPL, and --non-interactive exits" do
    out, _err, status = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")

    expect(status.exitstatus).to eq(0)
    prompt_line = out.lines.find { |l| l.include?("--prompt") }
    expect(prompt_line).to include("then stay in the REPL")
    expect(prompt_line).not_to include("exit")
    expect(out.lines.find { |l| l.include?("--non-interactive ") }).to include("exit")
  end

  it "says plain chi runs attached by default and --no-shared opts out" do
    out, _err, _status = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")

    shared_line = out.lines.find { |l| l.include?("--[no-]shared") }
    expect(shared_line).to include("the default")
    expect(shared_line).to include("--no-shared runs a plain in-process REPL")
  end

  it "lists --mute next to --memory, neither tied to the plain REPL" do
    out, = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")

    memory_line = out.lines.find { |l| l.include?("--memory NAME") }
    expect(memory_line).to include("repeatable")
    expect(memory_line).not_to include("plain REPL")
    expect(out.lines.find { |l| l.include?("--mute NAME") }).to include("Hide a memory from this session")
  end

  it "names the subcommands" do
    out, = Open3.capture3(RbConfig.ruby, chi, "--help", stdin_data: "")

    %w[web sessions note send answer bundle self].each { |sub| expect(out).to include("chi #{sub} ") }
    expect(out).not_to include("bin/chi") # what an installed gem's user types
  end

  it "prints its version with --version" do
    out, err, status = Open3.capture3(RbConfig.ruby, chi, "--version", stdin_data: "")

    expect([out, err, status.exitstatus]).to eq(["chi #{Samagotchi::VERSION}\n", "", 0])
  end

  it "refuses an unknown flag with one line, not a backtrace" do
    _out, err, status = Open3.capture3(RbConfig.ruby, chi, "--bogus", stdin_data: "")

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("Error: invalid option: --bogus (see chi --help)\n")
  end

  it "refuses an unknown command instead of starting a session" do
    _out, err, status = BoundedCapture.capture3({ "SAMAGOTCHI_SESSION_SHARED" => "0" }, RbConfig.ruby, chi,
                                                "bogus", "--non-interactive", stdin_data: "", timeout: 10)

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("Error: unknown command bogus (see chi --help)\n")
  end

  it "refuses a stray argument after web" do
    _out, err, status = BoundedCapture.capture3(RbConfig.ruby, chi, "web", "extra", "--port", "45898",
                                                stdin_data: "", timeout: 10)

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("Error: unexpected argument extra (see chi --help)\n")
  end
end
