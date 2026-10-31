# frozen_string_literal: true

require "samagotchi/version"
require "samagotchi/session_access/contract"

# `chi --help` runs a real bin/chi once, for the examples that read it, and
# `chi broadcast --help` another (a subcommand's file loads in a fresh ruby);
# the other commands fork it (ChiCli#fork_chi).
RSpec.describe "chi --help" do
  before(:context) { @help = run_chi("--help") }

  it "says -p runs the prompt and stays in the session (attached by default), and --non-interactive exits" do
    out, _err, status = @help

    expect(status.exitstatus).to eq(0)
    prompt_line = out.lines.find { |l| l.include?("--prompt") }
    expect(prompt_line).to include("then stay in the session (attached; the REPL with --no-shared)")
    expect(prompt_line).not_to include("exit")
    expect(out.lines.find { |l| l.include?("--non-interactive ") }).to include("exit")
  end

  it "says plain chi runs attached by default and --no-shared opts out" do
    out, _err, _status = @help

    shared_line = out.lines.find { |l| l.include?("--[no-]shared") }
    expect(shared_line).to include("the default")
    expect(shared_line).to include("--no-shared runs a plain in-process REPL")
  end

  it "lists --mute next to --memory, neither tied to the plain REPL" do
    out, = @help

    memory_line = out.lines.find { |l| l.include?("--memory NAME") }
    expect(memory_line).to include("repeatable")
    expect(memory_line).not_to include("plain REPL")
    expect(out.lines.find { |l| l.include?("--mute NAME") }).to include("Hide a memory from this session")
  end

  it "names the subcommands" do
    out, = @help

    %w[web sessions note broadcast context send answer bundle self].each { |sub| expect(out).to include("chi #{sub} ") }
    expect(out).not_to include("bin/chi") # what an installed gem's user types
  end

  it "names every bin/chi SUBCOMMANDS key" do
    out, = @help
    # The keys, read from the script as session_access_contract_spec does (it runs on load).
    keys = File.read(File.expand_path("../bin/chi", __dir__))[/^SUBCOMMANDS = \{.*?^\}\.freeze/m]
               .scan(/^\s+"([a-z-]+)" => \[/).flatten

    expect(keys).not_to be_empty
    expect(keys.reject { |sub| out.include?("chi #{sub} ") }).to eq([])
  end

  it "lists every command SessionAccess::Contract runs under --remote, and only those" do
    out, = @help
    contract = Samagotchi::SessionAccess::Contract
    remote = contract::TABLE.select { |words, status| !words.include?(" ") && status == contract::SUPPORTED }.keys

    remote_line = out.lines.find { |l| l.include?("chi --remote NAME <") }
    expect(remote_line[/<([^>]+)>/, 1].split("|")).to match_array(remote)
  end

  it "dispatches chi context with its own help" do
    out, _err, status = fork_chi("context", "--help")

    expect(status.exitstatus).to eq(0)
    expect(out).to start_with("Usage: chi context <add|push|ls|show|refresh|rm|mute|unmute|report>")
  end

  it "dispatches chi broadcast with its own help" do
    out, _err, status = run_chi("broadcast", "--help")

    expect(status.exitstatus).to eq(0)
    expect(out).to start_with("Usage: chi broadcast [-m TEXT] [--all] [--dry-run]")
  end

  it "prints its version with --version" do
    out, err, status = fork_chi("--version")

    expect([out, err, status.exitstatus]).to eq(["chi #{Samagotchi::VERSION}\n", "", 0])
  end

  it "refuses an unknown flag with one line, not a backtrace" do
    _out, err, status = fork_chi("--bogus")

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("Error: invalid option: --bogus (see chi --help)\n")
  end

  it "refuses an unknown command instead of starting a session" do
    _out, err, status = fork_chi("bogus", "--non-interactive", env: { "SAMAGOTCHI_SESSION_SHARED" => "0" }, timeout: 10)

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("Error: unknown command bogus (see chi --help)\n")
  end

  it "refuses a stray argument after web" do
    _out, err, status = fork_chi("web", "extra", "--port", "45898", timeout: 10)

    expect(status.exitstatus).to eq(1)
    expect(err).to eq("Error: unexpected argument extra (see chi --help)\n")
  end
end
