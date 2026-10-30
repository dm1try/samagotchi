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
    client_class.new(MCP_FAKE_COMMAND, env: env, log: ->(event, **fields) { logged << [event, fields] },
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
    expect(pop!(logged, "the server's stderr line")).to eq(["stderr", { line: "fake mcp server starting (normal)" }])
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

    # Whether the server logged a +method+ message (false while a line is
    # still being written).
    def received?(method)
      File.exist?(log_file) && received.any? { |m| m["method"] == method }
    rescue JSON::ParserError
      false
    end

    it "sends notifications/cancelled when the wait is cancelled" do
      initialize!
      # Cancelled once the server has the call, so the wait is under way.
      expect { client.request("tools/call", { name: "slow" }, timeout: 10, cancelled: -> { received?("tools/call") }) }
        .to raise_error(client_class::Cancelled)
      wait_for("the server to get notifications/cancelled") { received?("notifications/cancelled") }
      call = received.find { |m| m["method"] == "tools/call" }
      expect(received.last).to include("method" => "notifications/cancelled",
                                       "params" => { "requestId" => call["id"], "reason" => "cancelled by the user" })
      expect(received.find { |m| m["id"] == "srv-1" }).to include("result" => {})
    end

    it "times out, and says so to the server" do
      initialize!
      expect { client.request("tools/call", { name: "slow" }, timeout: 0.3) }
        .to raise_error(client_class::Timeout, "tools/call timed out after 0.3s")
      wait_for("the server to get notifications/cancelled") { received?("notifications/cancelled") }
    end
  end

  it "fails a waiting call when the server exits, once, and every call after" do
    initialize!
    expect { client.request("tools/call", { name: "crash" }, timeout: 5) }
      .to raise_error(client_class::Dead, "the server exited (status 4)")
    expect(pop!(exits, "the exit notice")).to eq("the server exited (status 4)")
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
    wait_for("the call to be waiting") { client.instance_variable_get(:@pending).any? }
    client.send(:ended)
    expect(join!(waiting, "the waiting call").value).to eq("the server exited")
    expect(pop!(exits, "the exit notice")).to eq("the server exited")
  end

  it "ends the process on close, without an exit notice" do
    initialize!
    pid = client.pid
    client.close
    expect(alive?(pid)).to be(false)
    expect(exits.size).to eq(0)
  end

  # A short grace: the outcome matters here, not its length. The watchdog
  # example below keeps the real one (its sleeps, then TERM and KILL).
  it "kills a server that ignores stdin EOF" do
    client_class.send(:remove_const, :STOP_GRACE_SECONDS)
    client_class.const_set(:STOP_GRACE_SECONDS, 0.1)
    client = client_class.new([RbConfig.ruby, "-e", "trap('TERM') {}; $stdin.read; sleep 30"])
    pid = client.pid
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    client.close
    expect(alive?(pid)).to be(false)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(5, below: 30)
  end

  it "leaves nothing in the server's process group after close (its watchdog goes too)" do
    initialize!
    pid = client.pid
    client.close
    group_alive = lambda do
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    end
    wait_for("the server's process group to be gone") { !group_alive.call }
    expect { Process.kill(0, -pid) }.to raise_error(Errno::ESRCH)
  end

  # kill -9 of chi runs no close: the server's stdin hits EOF, which a server
  # that ignores it (TERM too) outlives, reparented to init. The watchdog in
  # its process group stops the group then.
  it "stops a server that ignores stdin EOF and TERM when chi is killed without closing it" do
    lib = File.expand_path("../../../lib", __dir__)
    holder = <<~RUBY
      mod = Module.new
      mod.module_eval(File.read(#{File.join(MCP_SHIPPED, "plugin.rb").dump}), "plugin.rb", 1)
      client = mod::Plugin::Client.new([#{RbConfig.ruby.dump}, "--disable-gems", "-e", "trap('TERM') {}; $stdin.read; sleep 10"])
      puts client.pid
      $stdout.flush
      sleep
    RUBY
    out, writer = IO.pipe
    holder_pid = Process.spawn(RbConfig.ruby, "-I", lib, "-e", holder, out: writer)
    writer.close
    server = Timeout.timeout(10) { Integer(out.gets) } # timeout-ok: a hang guard: the holder prints its server's pid first
    expect(alive?(server)).to be(true)
    Process.kill("KILL", holder_pid)
    Process.wait(holder_pid)
    wait_for("the watchdog to stop the server", timeout: 6) { !alive?(server) }
  ensure
    out&.close
    if holder_pid
      begin
        Process.kill("KILL", holder_pid)
        Process.wait(holder_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
  end

  it "raises Dead for a command that doesn't exist" do
    expect { client_class.new(["/nonexistent/mcp-server"]) }.to raise_error(client_class::Dead, /can't start/)
  end
end
