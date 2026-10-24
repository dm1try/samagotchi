# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/web/tunnel"

RSpec.describe Samagotchi::Web::Tunnel do
  it "names its providers, and refuses another" do
    expect(described_class.for("tailscale")).to be_a(Samagotchi::Web::Tunnel::Tailscale)
    expect { described_class.for("ngrok") }.to raise_error(ArgumentError, /unknown tunnel ngrok/)
  end

  describe "the refusals' text" do
    it "says what is wrong and what to do" do
      expect(described_class::ConfigConflict.new("web.public_url", "https://a.example", "https://b.example").message)
        .to eq("web.public_url is https://a.example, but --tunnel sets it to https://b.example for this run: remove it " \
               "from config.yml or the environment (SAMAGOTCHI_WEB_PUBLIC_URL), or drop --tunnel")
      expect(described_class::AlreadyRunning.new(4567).message)
        .to eq("chi web already runs on port 4567, and --tunnel starts its own: stop that one first (Ctrl-C in its " \
               "terminal), or use --port")
      expect(described_class::CliFailed.new("tailscale serve status --json", "  boom\n").message)
        .to eq("tailscale serve status --json failed: boom")
      expect(described_class::CliFailed.new("tailscale status --json", "").message)
        .to eq("tailscale status --json failed (no output)")
      expect(described_class::CliTimeout.new("tailscale serve --bg", 15, "To enable, visit: https://login.example/x").message)
        .to eq("tailscale serve --bg didn't finish in 15 s and was stopped: To enable, visit: https://login.example/x " \
               "(if it printed a URL, open it to allow this, then run chi web again)")
      expect(described_class::CliTimeout.new("tailscale status --json", 5, "").message)
        .to eq("tailscale status --json didn't finish in 5 s and was stopped")
      expect(described_class::UnexpectedOutput.new("tailscale status --json").message)
        .to eq("tailscale status --json printed something chi can't read (a newer version?); nothing was changed")
    end
  end

  describe described_class::Runner do
    let(:runner) { described_class.new }

    it "returns both streams and whether it succeeded" do
      result = runner.call(["/bin/sh", "-c", "echo out; echo err >&2; exit 3"], timeout: 5)
      expect(result).to have_attributes(stdout: "out\n", stderr: "err\n", success: false, output: "out\n\nerr\n")
    end

    it "stops a command past its timeout, with what it printed by then" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { runner.call(["/bin/sh", "-c", "echo visit https://login.example; exec sleep 30"], timeout: 0.5) }
        .to raise_error(described_class::Timeout) { |e| expect(e.output).to include("visit https://login.example") }
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
    end
  end
end
