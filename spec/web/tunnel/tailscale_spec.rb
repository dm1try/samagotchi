# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/web/tunnel/tailscale"
require_relative "../../support/fake_tailscale"

RSpec.describe Samagotchi::Web::Tunnel::Tailscale do
  let(:dir) { Dir.mktmpdir("fake-tailscale") }
  let(:fake) { FakeTailscale.new(dir) }
  let(:env) { { described_class::ENV_CLI => fake.path, "PATH" => "" } }
  let(:tunnel) { described_class.new(env: env, app_cli: File.join(dir, "no-app")) }
  let(:name) { FakeTailscale::NAME }

  after { FileUtils.rm_rf(dir) }

  def prepare(port: 4567, **config) = tunnel.prepare(port: port, **config)

  describe "#cli" do
    it "takes SAMAGOTCHI_TAILSCALE_CLI first, before tailscale on PATH" do
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      FakeExecutables.fake_executable(bin, "tailscale", "exit 0")
      expect(described_class.new(env: env.merge("PATH" => bin)).cli).to eq(fake.path)
      expect(described_class.new(env: { "PATH" => "/nowhere:#{bin}" }, app_cli: File.join(dir, "no-app")).cli)
        .to eq(File.join(bin, "tailscale"))
    end

    it "refuses an override that can't run, never falling back to PATH" do
      FakeExecutables.fake_executable(dir, "tailscale-on-path", "exit 0")
      broken = described_class.new(env: { described_class::ENV_CLI => File.join(dir, "missing"), "PATH" => dir })
      expect { broken.cli }.to raise_error(described_class::CliOverrideMissing)
    end

    it "falls back to the app's CLI, but never in a test run" do
      app = FakeExecutables.fake_executable(dir, "Tailscale", "exit 0")
      expect(described_class.new(env: { "PATH" => "" }, app_cli: app).cli).to eq(app)
      expect { described_class.new(env: { "PATH" => "", "SAMAGOTCHI_ENV" => "test" }, app_cli: app).cli }
        .to raise_error(described_class::CliMissing)
      expect { described_class.new(env: { "PATH" => "", "CI" => "1" }, app_cli: app).cli }
        .to raise_error(described_class::CliMissing)
      expect { described_class.new(env: { "PATH" => "" }, app_cli: File.join(dir, "no-app")).cli }
        .to raise_error(described_class::CliMissing)
    end

    it "is the suite's missing file by default, so no spec runs the real one" do
      expect(ENV.fetch(described_class::ENV_CLI)).to eq(SPEC_TAILSCALE_CLI)
      expect { described_class.new.cli }.to raise_error(described_class::CliOverrideMissing)
    end
  end

  describe "#prepare" do
    it "makes this run's public_url from the machine's name, with Tailscale-User-Login and its login as the owner" do
      plan = prepare
      expect(plan.public_url).to eq(Samagotchi::Web::PublicUrl.from_config(
        url: "https://#{name}", identity_header: "Tailscale-User-Login", owner: "owner@example.com"
      ))
      expect(plan).to have_attributes(owner_source: :login, adopted: false, lock_off: true, port: 4567, dns_name: name,
                                      target: "http://127.0.0.1:4567")
      expect(fake.argv).to eq(["status --json", "serve status --json", "lock status --json"])
    end

    it "takes web.proxy.owner over the machine's login, a tagged machine too" do
      fake.status = fake.status.tap { |s| s["Self"]["Tags"] = ["tag:server"] }
      plan = prepare(config_owner: "Phone@Example.com")
      expect(plan.public_url.owner).to eq("phone@example.com")
      expect(plan.owner_source).to eq(:config)
    end

    it "refuses a tagged machine without web.proxy.owner" do
      fake.status = fake.status.tap { |s| s["Self"]["Tags"] = ["tag:server"] }
      expect { prepare }.to raise_error(described_class::TaggedOwner)
    end

    it "refuses unless Tailscale runs, with a name and its certificate" do
      fake.status = fake.status.merge("BackendState" => "NeedsLogin")
      expect { prepare }.to raise_error(described_class::NotRunning, /NeedsLogin/)
      fake.status = "status.json"
      fake.status = fake.status.tap { |s| s["Self"].delete("DNSName") }
      expect { prepare }.to raise_error(described_class::NoDnsName)
      fake.status = "status.json"
      fake.status = fake.status.merge("CertDomains" => nil)
      expect { prepare }.to raise_error(described_class::NoHttps)
      expect(fake.argv.uniq).to eq(["status --json"])
    end

    it "refuses a status it can't read, and a failing or hanging command" do
      fake.status = { "BackendState" => "Running", "Self" => { "DNSName" => "#{name}.", "UserID" => 9 },
                      "CertDomains" => [name], "User" => {} }
      expect { prepare }.to raise_error(Samagotchi::Web::Tunnel::UnexpectedOutput)
      File.write(File.join(dir, "state", "status.json"), "not json")
      expect { prepare }.to raise_error(Samagotchi::Web::Tunnel::UnexpectedOutput)
      fake.fail!("status", "failed to connect to local tailscaled")
      expect { prepare }.to raise_error(Samagotchi::Web::Tunnel::CliFailed, /failed to connect to local tailscaled/)
    end

    it "stops a command that doesn't finish in time" do
      stub_const("#{described_class}::STATUS_TIMEOUT", 0.3)
      fake.hang!("status", "waiting")
      expect { prepare }.to raise_error(Samagotchi::Web::Tunnel::CliTimeout, /waiting/)
    end

    it "refuses a web.public_url or identity header that differs from the tunnel's, from config or the environment" do
      expect { prepare(config_public_url: "https://other.example") }
        .to raise_error(Samagotchi::Web::Tunnel::ConfigConflict, /web.public_url/)
      expect { prepare(config_identity_header: "X-Forwarded-Email") }
        .to raise_error(Samagotchi::Web::Tunnel::ConfigConflict, /identity_header/)
      expect { prepare(config_identity_header: "none") }.to raise_error(Samagotchi::Web::Tunnel::ConfigConflict)
      expect(prepare(config_public_url: "https://#{name.upcase}/", config_identity_header: "tailscale-user-login"))
        .to be_a(Samagotchi::Web::Tunnel::Plan)
    end

    it "says nothing about Tailnet Lock when it is on or its status fails" do
      fake.lock = { "Enabled" => true }
      expect(prepare.lock_off).to be false
      fake.fail!("lock")
      expect(prepare.lock_off).to be false
    end
  end

  describe "what Serve has on 443" do
    it "adopts exactly its own handler for this port, other ports left out of it" do
      fake.serve = "serve-443-on.json"
      expect(prepare.adopted).to be true
      fake.serve = "serve-443-8443.json"
      expect(prepare.adopted).to be true
      fake.serve = "serve-8443-only.json"
      expect(prepare.adopted).to be false
    end

    it "refuses 443 serving another port, other paths, TCP forwarding or another name" do
      fake.serve = "serve-443-on.json"
      expect { prepare(port: 4568) }.to raise_error(described_class::ServeInUse, %r{/ → http://127.0.0.1:4567})
      on = FakeTailscale.fixture("serve-443-on.json")
      paths = Marshal.load(Marshal.dump(on))
      paths["Web"]["#{name}:443"]["Handlers"]["/files"] = { "Path" => "/Users/x/files" }
      tcp = { "TCP" => { "443" => { "TCPForward" => "127.0.0.1:22" } } }
      other_name = { "TCP" => on["TCP"], "Web" => { "other.example-tailnet.ts.net:443" => on["Web"].values.first } }
      [paths, tcp, other_name].each do |serve|
        fake.serve = serve
        expect { prepare }.to raise_error(described_class::ServeInUse)
      end
    end

    it "refuses Funnel on 443, whatever it serves" do
      fake.serve = FakeTailscale.fixture("serve-443-on.json").merge("AllowFunnel" => { "#{name}:443" => true })
      expect { prepare }.to raise_error(described_class::Funnel)
      fake.serve = { "AllowFunnel" => { "#{name}:443" => true } }
      expect { prepare }.to raise_error(described_class::Funnel)
    end
  end

  describe "#up and #down" do
    # What ran after prepare's three looks.
    def commands = fake.argv.drop(3)

    it "serves 443 to this port, then turns it off on exit, other ports untouched" do
      fake.serve = "serve-8443-only.json"
      plan = prepare
      tunnel.up(plan)
      expect(fake.serve).to eq(FakeTailscale.fixture("serve-443-8443.json"))
      expect(tunnel.down(plan)).to eq(:off)
      expect(commands).to eq(["serve --bg --https=443 http://127.0.0.1:4567", "serve status --json", "serve --https=443 off"])
      expect(fake.serve).to eq(FakeTailscale.fixture("serve-8443-only.json"))
      expect(tunnel.down_line(plan, :off)).to eq("Tailscale Serve: port 443 is off again.")
    end

    it "adopts a leftover: the same serve again (idempotent), off on exit" do
      fake.serve = "serve-443-on.json"
      plan = prepare
      tunnel.up(plan)
      expect(tunnel.down(plan)).to eq(:off)
      expect(commands).to eq(["serve --bg --https=443 http://127.0.0.1:4567", "serve status --json", "serve --https=443 off"])
      expect(fake.serve).to eq({})
    end

    it "leaves 443 alone when it changed while chi web ran: another handler, another target, Funnel" do
      plan = prepare
      tunnel.up(plan)
      served = fake.serve
      added = Marshal.load(Marshal.dump(served)).tap do |s|
        s["Web"]["#{name}:443"]["Handlers"]["/files"] = { "Path" => "/tmp/x" }
      end
      moved = JSON.parse(JSON.generate(served).sub("127.0.0.1:4567", "127.0.0.1:9999"))
      funnel = served.merge("AllowFunnel" => { "#{name}:443" => true })
      [added, moved, funnel].each do |changed|
        fake.serve = changed
        expect(tunnel.down(plan)).to eq(:changed)
        expect(fake.serve).to eq(changed)
      end
      expect(commands).not_to include("serve --https=443 off")
      expect(tunnel.down_line(plan, :changed))
        .to eq("Tailscale Serve's port 443 changed while chi web ran (#{name}): left as it is (tailscale serve status " \
               "shows it)")
    end

    it "says nothing when 443 is off already" do
      plan = prepare
      expect(tunnel.down(plan)).to eq(:gone)
      expect(tunnel.down_line(plan, :gone)).to be_nil
      expect(commands).to eq(["serve status --json"])
    end

    it "refuses with serve's output when it fails or waits for consent" do
      plan = prepare
      fake.fail!("serve-bg", "Serve is not enabled on your tailnet.")
      expect { tunnel.up(plan) }.to raise_error(Samagotchi::Web::Tunnel::CliFailed, /Serve is not enabled/)
      FileUtils.rm_f(File.join(dir, "state", "fail-serve-bg"))
      stub_const("#{described_class}::SERVE_TIMEOUT", 0.3)
      fake.hang!("serve-bg", "To enable, visit: https://login.tailscale.com/f/serve?node=nEXAMPLE")
      expect { tunnel.up(plan) }.to raise_error(Samagotchi::Web::Tunnel::CliTimeout, %r{https://login.tailscale.com/f/serve})
      expect(fake.serve).to eq({})
    end

    it "raises a failed off for the caller's warning" do
      plan = prepare
      tunnel.up(plan)
      fake.fail!("serve-off", "permission denied")
      expect { tunnel.down(plan) }.to raise_error(Samagotchi::Web::Tunnel::CliFailed) { |e|
        expect(tunnel.down_warning(plan, e))
          .to eq("Warning: Tailscale Serve may still forward #{name} to 127.0.0.1:4567 (tailscale serve --https=443 off " \
                 "failed: permission denied): turn it off with tailscale serve --https=443 off")
      }
    end
  end

  describe "the refusals' text" do
    it "says what is wrong and what to do" do
      expect(described_class::CliMissing.new.message)
        .to eq("tailscale isn't installed: no tailscale on PATH or at /Applications/Tailscale.app/Contents/MacOS/Tailscale " \
               "(install it from tailscale.com, or set SAMAGOTCHI_TAILSCALE_CLI to its path)")
      expect(described_class::CliOverrideMissing.new("/x").message)
        .to eq("SAMAGOTCHI_TAILSCALE_CLI is /x, which isn't an executable file")
      expect(described_class::NotRunning.new("NeedsLogin").message)
        .to eq("Tailscale isn't connected (NeedsLogin): open the Tailscale app and sign in, then run this again")
      expect(described_class::NoDnsName.new.message)
        .to eq("this machine has no tailnet name: turn on MagicDNS in the Tailscale admin console (DNS)")
      expect(described_class::NoHttps.new(name).message)
        .to eq("HTTPS certificates are off for this tailnet (none for #{name}): turn them on in the Tailscale admin " \
               "console (DNS); rename this machine first, certificate names go into a public log")
      expect(described_class::TaggedOwner.new(["tag:server"]).message)
        .to eq("this machine is tagged (tag:server), so its Tailscale login isn't a person's: set web.proxy.owner to " \
               "your Tailscale login")
      expect(described_class::ServeInUse.new("/ → http://127.0.0.1:9999").message)
        .to eq("Tailscale Serve already serves port 443 here (/ → http://127.0.0.1:9999), and chi web won't change it: " \
               "turn it off with tailscale serve --https=443 off, or use it as it is without --tunnel")
      expect(described_class::Funnel.new("#{name}:443").message)
        .to eq("Tailscale Funnel is on for #{name}:443 (the public internet), and chi web never runs behind Funnel: " \
               "turn it off first (tailscale funnel status shows it)")
    end
  end
end
