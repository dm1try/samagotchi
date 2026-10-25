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

  # A start that binds the port (calls on_bound, the tunnel's up), then
  # returns +result+ or raises +error+.
  def bound(result = true, error: nil)
    allow(described_class).to receive(:start) do |on_bound:, **|
      on_bound.call
      yield if block_given?
      raise error if error

      result
    end
  end

  it "runs chi web with the tunnel's public_url for this run, then turns the serve off" do
    config_before = File.read(config_file)
    served = nil
    bound { served = fake.serve }

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

  it "turns it off after Ctrl-C and SIGTERM" do
    bound(error: Interrupt)
    expect { expect(launch).to eq(Samagotchi::CLI::Exit::INTERRUPTED) }
      .to output("Tailscale Serve: port 443 is off again.\nChi Web stopped.\n").to_stdout
    bound(error: SignalException.new("TERM"))
    expect { expect { launch }.to raise_error(SignalException) }.to output(/off again/).to_stdout
    expect(fake.argv.count("serve --https=443 off")).to eq(2)
  end

  # Between the free-port probe and the bind another listener can take the
  # port: Serve would forward the tailnet to it.
  it "turns Serve on only once the port is bound: a port taken never reaches Serve" do
    allow(Samagotchi::Web::App).to receive(:new).and_return(double("app", "server_running=": nil))
    allow(Samagotchi::Web::SessionHub).to receive(:new)
      .and_return(instance_double(Samagotchi::Web::SessionHub, start: nil, stop: nil, scan: nil, subscribe: -> {}))
    allow(Samagotchi::Web::Token).to receive_messages(load_or_create: nil, read: "T")
    allow(described_class).to receive(:push_runtime).and_return(nil)
    allow(Rackup::Handler::WEBrick).to receive(:run).and_raise(Errno::EADDRINUSE)
    expect { expect(launch).to eq(1) }.to output(/port 4567 is in use/).to_stderr
    expect(fake.argv.grep(/\Aserve --/)).to eq([])

    served = nil
    allow(Rackup::Handler::WEBrick).to receive(:run) do |_app, opts|
      expect(fake.argv.grep(/serve --bg/)).to eq([])
      expect { opts[:StartCallback].call }.to output(/\AChi Web on .*Proxied: /m).to_stdout
      served = fake.serve
    end
    expect { expect(launch).to eq(0) }.to output(/off again/).to_stdout
    expect(served).to eq(FakeTailscale.fixture("serve-443-on.json"))
  end

  # A Ctrl-C from another thread once the block is true (Thread#raise is
  # how Ruby hands a signal to the main thread; RSpec traps SIGINT itself).
  def interrupt_when(what, &ready)
    target = Thread.current
    Thread.new do
      wait_for(what, &ready)
      target.raise(Interrupt)
    end
  end

  it "turns it off after a Ctrl-C while serve --bg runs (Serve keeps what it set)" do
    bound
    fake.slow!("serve-bg", 0.4)
    interrupter = interrupt_when("serve --bg to start") { fake.argv.include?("serve --bg --https=443 http://127.0.0.1:4567") }
    expect { expect(launch).to eq(Samagotchi::CLI::Exit::INTERRUPTED) }
      .to output("Tailscale Serve: port 443 is off again.\nChi Web stopped.\n").to_stdout
    interrupter.join
    expect(fake.argv.last).to eq("serve --https=443 off")
    expect(fake.serve).to eq({})
  end

  it "finishes the teardown through a second Ctrl-C, with the first one's exit status" do
    interrupter = nil
    bound(error: SignalException.new("TERM")) do
      fake.slow!("serve-status", 0.4)
      interrupter = interrupt_when("the teardown's serve status") { fake.argv.count("serve status --json") == 2 }
    end
    expect { expect { launch }.to raise_error(SignalException, "SIGTERM") }
      .to output("Tailscale Serve: port 443 is off again.\n").to_stdout
    expect(fake.argv.last).to eq("serve --https=443 off")
    expect(fake.serve).to eq({})
  ensure
    interrupter&.join
  end

  it "adopts a leftover serve for its port and still turns it off" do
    fake.serve = "serve-443-on.json"
    bound
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
    expect(described_class).not_to have_received(:start)
    allow(Samagotchi::Web::Grants).to receive(:check_permissions!)
    fake.fail!("serve-bg", "Serve is not enabled on your tailnet.")
    bound
    expect { expect(launch).to eq(1) }.to output(/\AError: tailscale serve --bg .* failed: Serve is not enabled/).to_stderr
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
    bound
    with_env("SAMAGOTCHI_WEB_PUSH_ENABLED" => "false", "SAMAGOTCHI_WEB_PUSH_CONTACT" => "chi@localhost") do
      expect { expect(launch).to eq(0) }.to output.to_stdout
    end
  end

  it "warns when the off fails, without changing the exit status" do
    bound
    fake.fail!("serve-off", "permission denied")
    expect { expect(launch).to eq(0) }
      .to output(/\AWarning: Tailscale Serve may still forward #{Regexp.escape(name)} to 127.0.0.1:4567 /).to_stdout
  end

  it "leaves 443 alone when someone changed it while chi web ran" do
    bound { fake.serve = fake.serve.tap { |s| s["Web"]["#{name}:443"]["Handlers"]["/files"] = { "Path" => "/tmp/x" } } }
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
