# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tmpdir"
require "fileutils"
require "samagotchi/mcp_command"
require "samagotchi/session"
require "samagotchi/session_inbox"
require_relative "support/remote_backend"
require_relative "support/chi_cli"

# chi mcp serve: its usage, a piped exchange on this machine's sessions,
# a chi_ask round trip on a Remote backend, and the real bin/chi's stdout
# holding JSON lines only.
RSpec.describe Samagotchi::McpCommand do
  include ChiCli

  let(:tmpdir) { Dir.mktmpdir("mcp-command") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after { FileUtils.rm_rf(tmpdir) }

  def request(id, method, params = nil) = JSON.generate({ jsonrpc: "2.0", id: id, method: method, params: params }.compact)

  def serve(lines, access: nil)
    status = described_class.new(["serve"], access: access, stdin: StringIO.new(lines.map { |l| "#{l}\n" }.join),
                                            stdout: out, stderr: err, state_dir: tmpdir).run
    [status, out.string.lines.map { |line| JSON.parse(line) }.to_h { |answer| [answer["id"], answer] }]
  end

  def make
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |s|
      s.save(state_dir: tmpdir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: tmpdir))
    end
  end

  it "prints its usage for --help and refuses anything but serve (exit 2)" do
    expect(described_class.new(["--help"], stdout: out, stderr: err).run).to eq(0)
    expect(out.string).to include("Usage: chi mcp serve")
    expect(described_class.new(["serve", "--help"], stdout: out, stderr: err).run).to eq(0)
    expect(described_class.new([], stdout: out, stderr: err).run).to eq(2)
    expect(described_class.new(["start"], stdout: out, stderr: err).run).to eq(2)
    expect(described_class.new(%w[serve extra], stdout: out, stderr: err).run).to eq(2)
    expect(err.string).to include("chi mcp: unknown subcommand start")
  end

  it "serves this machine's sessions on a pipe and exits 0 at EOF" do
    session = make
    status, answers = serve([request(1, "initialize", { protocolVersion: "2025-06-18" }),
                             request(2, "tools/call", { name: "chi_sessions", arguments: {} })])
    expect(status).to eq(0)
    expect(answers[1]["result"]["serverInfo"]["name"]).to eq("chi")
    expect(answers[2]["result"]["structuredContent"]["sessions"].map { |row| row["id"] }).to eq([session.id])
  end

  it "answers server/discover and initialize without loading SessionManager" do
    script = <<~RUBY
      require "stringio"
      require "samagotchi/mcp_command"
      input = StringIO.new(#{[request(1, "initialize", {}), request(2, "tools/list")].join("\n").dump} + "\\n")
      Samagotchi::McpCommand.new(["serve"], stdin: input, stdout: StringIO.new, stderr: StringIO.new).run
      abort "loaded SessionManager" if $LOADED_FEATURES.grep(%r{/samagotchi/session_manager\\.rb\\z}).any?
    RUBY
    _out, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)
    expect(status).to be_success, error
  end

  it "loads what the tools' calls autoload before the first call's thread starts" do
    script = <<~RUBY
      require "stringio"
      require "samagotchi/mcp_command"
      input = StringIO.new(#{request(1, "tools/call", { name: "chi_wait", arguments: { token: "x" } }).dump} + "\n")
      Samagotchi::McpCommand.new(["serve"], stdin: input, stdout: StringIO.new, stderr: StringIO.new,
                                            state_dir: #{tmpdir.dump}).run
      %w[session_manager session_continue session_inbox_delivery].each do |name|
        abort "\#{name} not loaded" unless $LOADED_FEATURES.grep(%r{/samagotchi/\#{name}\\.rb\\z}).any?
      end
    RUBY
    _out, error, status = Open3.capture3(isolated_chi_env(tmpdir), RbConfig.ruby, "-I", File.expand_path("../lib", __dir__),
                                         "-e", script)
    expect(status).to be_success, error
  end

  it "keeps bin/chi's stdout to JSON lines (diagnostics on stderr)" do
    lines = [request(1, "server/discover", { _meta: { "io.modelcontextprotocol/protocolVersion" => "2026-07-28" } }),
             request(2, "tools/call", { name: "chi_sessions", arguments: {},
                                        _meta: { "io.modelcontextprotocol/protocolVersion" => "2026-07-28" } })]
    stdout, stderr, status = Open3.capture3(isolated_chi_env(tmpdir),
                                            *ChiCli::RUBY, ChiCli::CHI, "mcp", "serve", stdin_data: lines.join("\n") + "\n")
    expect(status).to be_success, stderr
    parsed = stdout.lines.map { |line| JSON.parse(line) }
    expect(parsed.map { |answer| answer["id"] }).to eq([1, 2])
    expect(parsed.last["result"]).to include("isError" => false)
  end

  describe "on a Remote backend" do
    let(:remote) { RemoteBackend.access(state_dir: tmpdir) }

    it "runs a chi_ask round trip through chi web" do
      session = make
      delivered = []
      allow(Samagotchi::SessionManager).to receive(:deliver_turn) do |id, prompt:, client_id:, **|
        delivered << [id, prompt, client_id]
        Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(id, state_dir: tmpdir), "from afar",
                                              enqueued_id: "r1")
        Samagotchi::SessionManager::DeliverResult.new(status: :accepted, via: :bridge, ack: { "enqueued_id" => "r1" })
      end

      _status, answers = serve([request(1, "initialize", {}),
                                request(2, "tools/call", { name: "chi_ask", arguments: { session: session.id, prompt: "hi" } })],
                               access: remote)
      result = answers[2]["result"]
      expect(result["content"].first["text"]).to eq("from afar"), result.inspect
      expect(result["structuredContent"]).to include("status" => "done", "session_id" => session.id)
      expect(delivered).to eq([[session.id, "hi", "cli:send"]])
    end
  end
end
