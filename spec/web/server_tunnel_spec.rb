# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/web/server"
require "samagotchi/web/tunnel/tailscale"
require_relative "../support/fake_tailscale"

# chi web --tunnel tailscale: Server.launch with a fake tailscale
# (SAMAGOTCHI_TAILSCALE_CLI) and a stubbed start.
RSpec.describe Samagotchi::Web::Server, "with --tunnel tailscale" do
  let(:dir) { Dir.mktmpdir("server-tunnel") }
  let(:fake) { FakeTailscale.new(dir) }
  let(:name) { FakeTailscale::NAME }
  let(:config_file) { File.join(ENV.fetch("XDG_CONFIG_HOME"), "samagotchi", "config.yml") }

  around do |example|
    with_env("SAMAGOTCHI_TAILSCALE_CLI" => fake.path) { example.run }
  ensure
    FileUtils.rm_rf(dir)
  end

  before do
    allow(described_class).to receive(:probe).and_return(:free)
    allow(Samagotchi::Web::Grants).to receive(:check_permissions!)
  end

  def launch = described_class.launch(port: 4567, dir: "/", tunnel: "tailscale")

  it "runs chi web with the tunnel's public_url for this run, then turns the serve off" do
    config_before = File.read(config_file)
    served = nil
    allow(described_class).to receive(:start) do |**|
      served = fake.serve
      true
    end

    expect { expect(launch).to eq(0) }.to output("Tailscale Serve: port 443 is off again.\n").to_stdout
    expect(described_class).to have_received(:start).with(hash_including(
      public_url: Samagotchi::Web::PublicUrl.from_config(
        url: "https://#{name}", identity_header: "Tailscale-User-Login",
        owner: "owner@example.com"
      ),
      public_notes: [a_string_including("via Tailscale Serve (tailnet only), " \
                                        "owner owner@example.com (this machine's " \
                                        "Tailscale login)"),
                     a_string_starting_with("Tailnet Lock is off")]
    ))
    expect(served).to eq(FakeTailscale.fixture("serve-443-on.json"))
    expect(fake.argv).to eq(["status --json", "serve status --json", "lock status --json",
                             "serve --bg --https=443 http://127.0.0.1:4567", "serve status --json", "serve --https=443 off"])
    expect(fake.serve).to eq({})
    expect(File.read(config_file)).to eq(config_before)
  end

  it "turns it off after Ctrl-C, SIGTERM and a port taken" do
    allow(described_class).to receive(:start).and_raise(Interrupt)
    expect { expect(launch).to eq(Samagotchi::CLI::Exit::INTERRUPTED) }
      .to output("Tailscale Serve: port 443 is off again.\nChi Web stopped.\n").to_stdout
    allow(described_class).to receive(:start).and_raise(SignalException, "TERM")
    expect { expect { launch }.to raise_error(SignalException) }.to output(/off again/).to_stdout
    allow(described_class).to receive(:start).and_return(false)
    expect { expect(launch).to eq(1) }.to output(/off again/).to_stdout
    expect(fake.argv.count("serve --https=443 off")).to eq(3)
  end

  it "adopts a leftover serve for its port and still turns it off" do
    fake.serve = "serve-443-on.json"
    allow(described_class).to receive(:start).and_return(true)
    expect { launch }.to output(/off again/).to_stdout
    expect(described_class).to have_received(:start)
      .with(hash_including(public_notes: include(a_string_including("Serve already forwarded port 443 here"))))
    expect(fake.serve).to eq({})
  end

  it "leaves a live tunnel's serve alone when a chi web already runs on the port" do
    fake.serve = "serve-443-on.json"
    allow(described_class).to receive(:probe).and_return({ "app" => "chi-web", "pid" => 42 })
    allow(described_class).to receive(:start)
    expect { expect(launch).to eq(1) }.to output("Error: #{Samagotchi::Web::Tunnel::AlreadyRunning.new(4567).message}\n")
      .to_stderr
    expect(described_class).not_to have_received(:start)
    expect(fake.argv).to eq([])
    expect(fake.serve).to eq(FakeTailscale.fixture("serve-443-on.json"))
  end

  it "refuses before it changes anything: a foreign 443, insecure grants, a failed serve" do
    allow(described_class).to receive(:start)
    fake.serve = "serve-443-on.json"
    expect { expect(described_class.launch(port: 4568, dir: "/", tunnel: "tailscale")).to eq(1) }
      .to output(/\AError: Tailscale Serve already serves port 443 here/).to_stderr
    fake.serve = "serve-off.json"
    allow(Samagotchi::Web::Grants).to receive(:check_permissions!).and_raise(Samagotchi::Web::Grants::Insecure, "0644")
    expect { expect(launch).to eq(1) }.to output("Error: 0644\n").to_stderr
    allow(Samagotchi::Web::Grants).to receive(:check_permissions!)
    fake.fail!("serve-bg", "Serve is not enabled on your tailnet.")
    expect { expect(launch).to eq(1) }.to output(/\AError: tailscale serve --bg .* failed: Serve is not enabled/).to_stderr
    expect(described_class).not_to have_received(:start)
    expect(fake.argv).not_to include("serve --https=443 off")
  end

  it "refuses a web.push.contact the push services would refuse, or a push store others can read, before the tunnel" do
    allow(described_class).to receive(:start)
    with_env("SAMAGOTCHI_WEB_PUSH_CONTACT" => "chi@localhost") do
      expect { expect(launch).to eq(1) }
        .to output("Error: web.push.contact must be a mailto: address or an https URL (the push services refuse " \
                   "anything else), not chi@localhost\n").to_stderr
    end
    allow(Samagotchi::Web::Push).to receive(:preflight!).and_raise(Samagotchi::Web::Push::Store::Insecure, "0644 push")
    expect { expect(launch).to eq(1) }.to output("Error: 0644 push\n").to_stderr
    expect(described_class).not_to have_received(:start)
    expect(fake.argv.grep(/serve --bg/)).to eq([])
  end

  it "runs without push checks when web.push.enabled is false" do
    allow(described_class).to receive(:start).and_return(true)
    with_env("SAMAGOTCHI_WEB_PUSH_ENABLED" => "false", "SAMAGOTCHI_WEB_PUSH_CONTACT" => "chi@localhost") do
      expect { expect(launch).to eq(0) }.to output.to_stdout
    end
  end

  it "warns when the off fails, without changing the exit status" do
    allow(described_class).to receive(:start).and_return(true)
    fake.fail!("serve-off", "permission denied")
    expect { expect(launch).to eq(0) }
      .to output(/\AWarning: Tailscale Serve may still forward #{Regexp.escape(name)} to 127.0.0.1:4567 /).to_stdout
  end

  it "leaves 443 alone when someone changed it while chi web ran" do
    allow(described_class).to receive(:start) do |**|
      fake.serve = fake.serve.tap { |s| s["Web"]["#{name}:443"]["Handlers"]["/files"] = { "Path" => "/tmp/x" } }
      true
    end
    expect { launch }.to output(/changed while chi web ran/).to_stdout
    expect(fake.argv).not_to include("serve --https=443 off")
  end

  it "records its public_url, so a plain chi web on its port prints the proxied link while it runs" do
    expect(described_class.record_running(Samagotchi::Web::Running.path, 4567,
                                          Samagotchi::Web::PublicUrl.from_config(url: "https://#{name}"))).to be_a(String)
    allow(described_class).to receive(:probe).and_return({ "app" => "chi-web", "pid" => Process.pid })
    allow(Samagotchi::Web::Token).to receive(:read).and_return("T")
    allow(described_class).to receive(:owner_codes).and_return(double("codes", issue: "chc_C"))
    expect { described_class.launch(port: 4567, dir: "/", scope: "all") }
      .to output(a_string_including("Proxied: https://#{name}/#code=chc_C ")).to_stdout
    allow(described_class).to receive(:probe).and_return({ "app" => "chi-web", "pid" => Process.pid + 1 })
    expect { described_class.launch(port: 4567, dir: "/", scope: "all") }.not_to output(/Proxied/).to_stdout
  ensure
    Samagotchi::Web::Running.clear
  end

  it "adds the tunnel's lines and, at a terminal, the link's QR code to the start lines" do
    url = Samagotchi::Web::PublicUrl.from_config(url: "https://#{name}", identity_header: "Tailscale-User-Login",
                                                 owner: "owner@example.com")
    codes = double("codes", issue: "chc_C")
    lines = described_class.public_lines(url, token: "T", codes: codes, notes: ["via"], qr: true)
    expect(lines[0]).to start_with("Proxied: https://#{name}/#code=chc_C ")
    expect(lines[2]).to eq("via")
    expect(lines.drop(3)).to eq(Samagotchi::Web::QR.lines("https://#{name}/#code=chc_C"))
    expect(described_class.public_lines(url, token: "T", codes: codes).size).to eq(2)
  end
end
