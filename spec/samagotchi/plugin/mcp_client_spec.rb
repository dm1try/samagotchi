# frozen_string_literal: true

require "spec_helper"
require_relative "../../support/mcp_bundle"

# The mcp bundle's JSON-RPC client, against spec/fixtures/mcp/fake_server.rb.
RSpec.describe "The mcp bundle's client" do
  let(:client_class) do
    mod = Module.new
    mod.module_eval(File.read(File.join(MCP_SHIPPED, "plugin.rb")), "plugin.rb", 1)
    mod::Plugin::Client
  end
  let(:logged) { Queue.new }
  let(:exits) { Queue.new }
  let(:env) { {} }
  let(:client) do
    client_class.new([RbConfig.ruby, MCP_FAKE], env: env, log: ->(event, **fields) { logged << [event, fields] },
                                                on_exit: ->(reason) { exits << reason })
  end

  after { client.close }

  def initialize!
    client.request("initialize", { protocolVersion: "2025-06-18", capabilities: {} }, timeout: 5)
  end

  it "initializes, answers the server's ping on the way, and lists tools; stderr goes to the log" do
    expect(initialize!).to include("serverInfo" => { "name" => "fake", "version" => "1" })
    client.notify("notifications/initialized")
    expect(client.request("tools/list", nil, timeout: 5)["tools"].map { |t| t["name"] }).to eq(%w[echo add fail mixed])
    Timeout.timeout(2) { sleep(0.05) until logged.size.positive? }
    expect(logged.pop).to eq(["stderr", { line: "fake mcp server starting (normal)" }])
  end

  it "raises an error answer" do
    initialize!
    expect { client.request("tools/call", { name: "nope" }, timeout: 5) }
      .to raise_error(client_class::Error, "unknown tool (-32602)")
  end

  context "logging what it received" do
    let(:log_file) { File.join(Dir.mktmpdir("mcp-log-"), "received.jsonl") }
    let(:env) { { "FAKE_MCP_LOG" => log_file } }

    def received = File.readlines(log_file).map { |line| JSON.parse(line) }

    it "sends notifications/cancelled when the wait is cancelled" do
      initialize!
      cancel = false
      Thread.new { sleep(0.3); cancel = true }
      expect { client.request("tools/call", { name: "slow" }, timeout: 10, cancelled: -> { cancel }) }
        .to raise_error(client_class::Cancelled)
      Timeout.timeout(2) { sleep(0.05) until received.any? { |m| m["method"] == "notifications/cancelled" } }
      call = received.find { |m| m["method"] == "tools/call" }
      expect(received.last).to include("method" => "notifications/cancelled",
                                       "params" => { "requestId" => call["id"], "reason" => "cancelled by the user" })
      expect(received.find { |m| m["id"] == "srv-1" }).to include("result" => {})
    end

    it "times out, and says so to the server" do
      initialize!
      expect { client.request("tools/call", { name: "slow" }, timeout: 0.3) }
        .to raise_error(client_class::Timeout, "tools/call timed out after 0.3s")
      Timeout.timeout(2) { sleep(0.05) until received.any? { |m| m["method"] == "notifications/cancelled" } }
    end
  end

  it "fails a waiting call when the server exits, once, and every call after" do
    initialize!
    expect { client.request("tools/call", { name: "crash" }, timeout: 5) }
      .to raise_error(client_class::Dead, "the server exited (status 4)")
    expect(exits.pop(timeout: 2)).to eq("the server exited (status 4)")
    expect { client.request("tools/list", nil, timeout: 5) }.to raise_error(client_class::Dead)
    expect(exits.size).to eq(0)
  end

  it "fails a waiting call with a plain reason when the wait status is nil" do
    initialize!
    allow(client.instance_variable_get(:@wait)).to receive(:value).and_return(nil)
    waiting = Thread.new do
      client.request("tools/call", { name: "slow" }, timeout: 5)
    rescue client_class::Dead => e
      e.message
    end
    sleep 0.1
    client.send(:ended)
    expect(waiting.value).to eq("the server exited")
    expect(exits.pop(timeout: 2)).to eq("the server exited")
  end

  it "ends the process on close, without an exit notice" do
    initialize!
    pid = client.pid
    client.close
    expect(alive?(pid)).to be(false)
    expect(exits.size).to eq(0)
  end

  it "kills a server that ignores stdin EOF" do
    client = client_class.new([RbConfig.ruby, "-e", "trap('TERM') {}; $stdin.read; sleep 30"])
    pid = client.pid
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.close
    expect(alive?(pid)).to be(false)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
  end

  it "raises Dead for a command that doesn't exist" do
    expect { client_class.new(["/nonexistent/mcp-server"]) }.to raise_error(client_class::Dead, /can't start/)
  end
end
