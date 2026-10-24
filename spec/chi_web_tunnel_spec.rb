# frozen_string_literal: true

require "spec_helper"
require "socket"
require "tmpdir"
require "samagotchi/web/tunnel"
require_relative "support/fake_tailscale"

# A real `chi web --tunnel tailscale` process on a fake tailscale: the
# serve is on while it runs, a second --tunnel on its port is refused and
# leaves it, and SIGTERM still turns it off (the teardown is an ensure, no
# trap). The fake must be what ran: its log is never empty.
RSpec.describe "chi web --tunnel tailscale" do
  let(:dir) { Dir.mktmpdir("chi-web-tunnel") }
  let(:fake) { FakeTailscale.new(File.join(dir, "fake").tap { |d| FileUtils.mkdir_p(d) }) }
  let(:port) { TCPServer.open("127.0.0.1", 0).then { |server| server.addr[1].tap { server.close } } }
  let(:env) { isolated_chi_env(dir, "SAMAGOTCHI_TAILSCALE_CLI" => fake.path) }

  after { FileUtils.rm_rf(dir) }

  it "serves 443 to its port while it runs and turns it off on SIGTERM" do
    FileUtils.mkdir_p(File.join(dir, "config", "samagotchi"))
    FileUtils.cp(File.join(SPEC_XDG_CONFIG_HOME, "samagotchi", "config.yml"), File.join(dir, "config", "samagotchi"))
    log = File.join(dir, "out.log")
    pid = Process.spawn(env, *ChiCli::RUBY, ChiCli::CHI, "web", "--tunnel", "tailscale", "--port", port.to_s,
                        in: File::NULL, out: log, err: %i[child out], pgroup: true)
    begin
      wait_for("chi web's start lines", timeout: 30, seen: -> { File.read(log) }) { File.read(log).include?("Press Ctrl-C") }
      out = File.read(log)
      expect(out).to include("Proxied: https://#{FakeTailscale::NAME}/#code=chc_", "via Tailscale Serve (tailnet only)",
                             "Tailnet Lock is off")
      expect(fake.serve.dig("Web", "#{FakeTailscale::NAME}:443", "Handlers", "/", "Proxy")).to eq("http://127.0.0.1:#{port}")

      # A second --tunnel on the same port: refused, the first one's serve kept.
      _out, err, status = run_chi("web", "--tunnel", "tailscale", "--port", port.to_s, env: env, timeout: 30)
      expect([err, status.exitstatus]).to eq(["Error: #{Samagotchi::Web::Tunnel::AlreadyRunning.new(port).message}\n", 1])
      expect(fake.serve.dig("Web", "#{FakeTailscale::NAME}:443", "Handlers", "/", "Proxy")).to eq("http://127.0.0.1:#{port}")

      Process.kill("TERM", pid)
      _, status = Process.wait2(pid)
      pid = nil
      expect(status.termsig).to eq(Signal.list["TERM"])
    ensure
      if pid
        Process.kill("KILL", -pid)
        Process.wait(pid)
      end
    end
    expect(fake.argv).not_to be_empty
    expect(fake.argv.last).to eq("serve --https=443 off")
    expect(fake.argv.count("serve --https=443 off")).to eq(1)
    expect(fake.serve).to eq({})
    expect(File.read(log)).to include("Tailscale Serve: port 443 is off again.")
  end
end
