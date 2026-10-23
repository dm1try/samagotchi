# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/remote_command"
require_relative "support/remote_backend"

RSpec.describe Samagotchi::RemoteCommand do
  let(:tmpdir) { Dir.mktmpdir("remote-command") }
  let(:path) { File.join(tmpdir, "samagotchi", "remotes.yml") }
  let(:token_file) { File.join(tmpdir, "token").tap { |f| File.write(f, "#{RemoteBackend::TOKEN}\n") } }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:app) { RemoteBackend.app(state_dir: File.join(tmpdir, "state")) }
  # chi web on the LAN, through its Rack app; with +reply+ a fixed answer,
  # with +raises+ a connection that fails as HTTPTransport's does.
  let(:reply) { nil }
  let(:raises) { nil }
  let(:transport) do
    lambda do |entry|
      lambda do |*_args, **_opts|
        raise Samagotchi::SessionAccess::RemoteFailed, "#{entry.label}: #{raises}" if raises
        return Samagotchi::SessionAccess::HTTPTransport::Reply.of(*reply) if reply

        RemoteBackend::RackTransport.new(app, token: entry.token).call(:get, "/api/info")
      end
    end
  end

  after { FileUtils.rm_rf(tmpdir) }

  def run(*argv, stdin: StringIO.new(""))
    described_class.new(argv, stdin: stdin, stdout: out, stderr: err, path: path, transport: transport).run
  end

  def saved = Samagotchi::Remotes.all(path: path)

  it "adds a remote after GET /api/info answers with the token: its chi and LAN address" do
    expect(run("add", "studio", "http://#{RemoteBackend::LAN_IP}:4567", "--token-file", token_file)).to eq(0), err.string
    expect(out.string).to eq("studio  http://#{RemoteBackend::LAN_IP}:4567  chi #{Samagotchi::VERSION}, LAN #{RemoteBackend::LAN_IP}\n")
    expect(saved.map(&:to_h)).to eq([{ name: "studio", url: "http://#{RemoteBackend::LAN_IP}:4567", token: RemoteBackend::TOKEN }])
  end

  it "takes the token from stdin, and replaces a remote of the same name" do
    run("add", "studio", RemoteBackend::LAN_IP, "--token-file", token_file)
    expect(run("add", "studio", RemoteBackend::LAN_IP, "--token-stdin", stdin: StringIO.new("#{RemoteBackend::TOKEN}\n"))).to eq(0), err.string
    expect(saved.size).to eq(1)
  end

  describe "a remote it can't use: nothing saved, exit 1" do
    it "says the token was refused (401)" do
      File.write(token_file, "wrong\n")
      expect(run("add", "studio", RemoteBackend::LAN_IP, "--token-file", token_file)).to eq(1)
      expect(err.string).to include("remote studio (http://#{RemoteBackend::LAN_IP}:4567): the token was refused")
      expect(saved).to be_empty
    end

    context "with a hostname (403 forbidden)" do
      let(:reply) { [403, JSON.generate(error: "forbidden", detail: "only the host names 127.0.0.1, [::1], localhost and 192.168.1.29 are answered")] }

      it "says to use the LAN IP it answers" do
        expect(run("add", "studio", "http://studio.local:4567", "--token-file", token_file)).to eq(1)
        expect(err.string).to include("use the LAN IP 192.168.1.29, not a hostname")
      end
    end

    context "when nothing answers" do
      let(:raises) { "connection refused" }

      it "says to start chi web there on the LAN" do
        expect(run("add", "studio", "192.168.1.29", "--token-file", token_file)).to eq(1)
        expect(err.string).to eq("chi remote add: remote studio (http://192.168.1.29:4567): connection refused: " \
                                 "start chi web on 192.168.1.29 with web.host: lan\n")
      end
    end

    context "with a chi web from before the session commands' routes" do
      let(:reply) { [200, JSON.generate(app: "chi-web", version: "0.102.0", features: %w[dir newest_workers])] }

      it "names its chi and says to update it" do
        expect(run("add", "studio", "192.168.1.29")).to eq(1)
        expect(err.string).to include("remote studio runs chi 0.102.0, too old for this command through --remote: update chi there (chi update)")
      end
    end

    context "with something else on the port" do
      let(:reply) { [200, "<html>"] }

      it "says it isn't chi web" do
        expect(run("add", "studio", "192.168.1.29")).to eq(1)
        expect(err.string).to include("not chi web (GET /api/info answered 200)")
      end
    end
  end

  it "refuses a bad name or address, both token flags, an unreadable or empty token file (usage 2 or 1)" do
    expect(run("add", "a b", "192.168.1.29")).to eq(2)
    expect(run("add", "studio", "ftp://x")).to eq(2)
    expect(run("add", "studio", "192.168.1.29", "--token-file", token_file, "--token-stdin")).to eq(2)
    expect(run("add", "studio")).to eq(2)
    expect(run("add", "studio", "192.168.1.29", "--token-file", File.join(tmpdir, "none"))).to eq(1)
    File.write(token_file, "\n")
    expect(run("add", "studio", "192.168.1.29", "--token-file", token_file)).to eq(1)
    expect(err.string).to include("holds no token")
    expect(saved).to be_empty
  end

  it "lists the remotes without their tokens, as text or json, and removes one" do
    run("add", "studio", RemoteBackend::LAN_IP, "--token-file", token_file)
    Samagotchi::Remotes.put(Samagotchi::Remotes::Entry.new(name: "box", url: "http://127.0.0.1:4567", token: nil), path: path)
    out.truncate(0)
    out.rewind

    expect(run("ls")).to eq(0)
    expect(out.string).to eq("box     http://127.0.0.1:4567  (no token)\nstudio  http://#{RemoteBackend::LAN_IP}:4567\n")
    expect(run("ls", "--format", "json")).to eq(0)
    expect(out.string).not_to include(RemoteBackend::TOKEN)
    expect(JSON.parse(out.string.lines.last)).to eq([{ "name" => "box", "url" => "http://127.0.0.1:4567", "token" => false },
                                                     { "name" => "studio", "url" => "http://#{RemoteBackend::LAN_IP}:4567", "token" => true }])
    expect(run("rm", "box")).to eq(0)
    expect(run("rm", "box")).to eq(1)
    expect(err.string).to include("no remote box")
  end

  it "prints its usage" do
    expect(run).to eq(0)
    expect(out.string).to include("chi remote <add|ls|rm>", "--token-file FILE", "CHI_REMOTE=NAME")
    expect(run("bogus")).to eq(2)
  end
end
