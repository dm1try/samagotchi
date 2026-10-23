# frozen_string_literal: true

require "stringio"
require "socket"
require "tmpdir"
require "spec_helper"
require "samagotchi/session_access/dispatch"
require_relative "support/remote_backend"

# bin/chi's front for chi --remote NAME and CHI_REMOTE: which remote, what
# runs there, what is refused (exit 2), and the subcommand run with a Remote.
RSpec.describe Samagotchi::SessionAccess::Dispatch do
  let(:tmpdir) { Dir.mktmpdir("dispatch") }

  after { FileUtils.rm_rf(tmpdir) }

  def from(*argv, env: {}) = described_class.from(argv, env: env)

  describe ".from" do
    it "takes --remote NAME or --remote=NAME off the front; the flag beats CHI_REMOTE; no default remote" do
      expect(from("--remote", "studio", "send", "-m", "x", "ab")).to have_attributes(remote: "studio", argv: %w[send -m x ab])
      expect(from("--remote=box", "note", env: { "CHI_REMOTE" => "studio" })).to have_attributes(remote: "box", argv: %w[note])
      expect(from("send", env: { "CHI_REMOTE" => "studio" }).remote).to eq("studio")
      expect(from("send", env: { "CHI_REMOTE" => " " }).remote).to be_nil
      expect(from("send", "--remote", "x").remote).to be_nil
      expect(from("--remote", "a", "--remote", "b", "send").remote).to eq("b")
    end

    it "refuses --remote with no name" do
      ["--remote", "--remote=", "--remote --attach"].each do |args|
        expect { from(*args.split) }.to raise_error(described_class::Usage, /--remote needs a remote's name/), args
      end
    end
  end

  describe "#refusal (SessionAccess::Contract)" do
    def refusal(*argv) = described_class.new(argv, remote: "studio").refusal

    it "lets the supported session commands and flags through" do
      [%w[send -m x ab], %w[send --new --dir /p --wait -m x], %w[answer ab --question q --option 1], %w[note --all -m x],
       %w[context add x --push ab], %w[context push x ab], %w[context ls --format json ab], %w[sessions list --live],
       %w[sessions delete --force ab], %w[send --help]].each do |argv|
        expect(refusal(*argv)).to be_nil, argv.join(" ")
      end
    end

    it "refuses what runs on this machine only, in one message" do
      {
        %w[sessions stats ab] => "chi sessions stats", %w[sessions prune] => "chi sessions prune",
        %w[context mute x ab] => "chi context mute", %w[context add x --push --project] => "chi context add --project",
        %w[context ls --project] => "chi context ls --project", %w[broadcast -m x] => "chi broadcast",
        %w[bundle list] => "chi bundle", %w[memory ls] => "chi memory", %w[web] => "chi web", %w[self] => "chi self",
        %w[--attach ab --verbose] => "chi --verbose", %w[-v -p hi] => "chi --verbose", %w[--no-shared] => "chi --no-shared",
        %w[--memory m --attach ab] => "chi --memory", %w[--dir /x --mute m] => "chi --mute",
        %w[--append-system-prompt=f.md] => "chi --append-system-prompt", %w[--attach ab --status-line on] => "chi --status-line"
      }.each do |argv, words|
        expect(refusal(*argv)).to eq("#{words} runs on this machine only: run it on studio"), argv.join(" ")
      end
      expect(refusal("-p", "hi", "--non-interactive"))
        .to eq("chi --non-interactive runs on this machine only: run it on studio " \
               "(chi --remote studio send --new --dir D -m TEXT --wait runs one turn there)")
    end

    it "lets a remote attach's run flags through, a flag's value never read as a flag (bin/chi parses them)" do
      [[], %w[--attach ab], %w[--resume ab -p hi], %w[--dir /x -p hi --model m --thinking low], %w[-p --verbose],
       %w[--attach ab --no-interrupt --no-default-input --set a=b --toolkit lean --tool x --no-tool y]].each do |argv|
        expect(refusal(*argv)).to be_nil, argv.join(" ")
        expect(described_class.new(argv, remote: "studio")).to be_run_flags
      end
      expect(described_class.new(%w[send -m x], remote: "studio")).not_to be_run_flags
    end

    it "runs chi remote, --version and --help here whatever the remote" do
      expect(described_class.new(%w[remote ls], remote: "studio")).to be_here
      expect(described_class.new(%w[--version], remote: "studio")).to be_here
      expect(described_class.new(%w[send -m x], remote: "studio")).not_to be_here
    end
  end

  describe "#run" do
    let(:err) { StringIO.new }
    let(:remotes) { File.join(tmpdir, "config", "samagotchi", "remotes.yml") }
    let(:subcommands) { { "note" => ["samagotchi/note_command", "NoteCommand"], "bundle" => %w[x X] } }

    around { |example| with_env("XDG_CONFIG_HOME" => File.join(tmpdir, "config")) { example.run } }

    it "exits 2 for a refusal, an unknown remote, and 1 for an unknown command" do
      expect(described_class.new(%w[bundle list], remote: "studio").run(subcommands, stderr: err)).to eq(2)
      expect(described_class.new(%w[note -m x ab], remote: "nope").run(subcommands, stderr: err)).to eq(2)
      expect(described_class.new(%w[sned], remote: "studio").run(subcommands, stderr: err)).to eq(1)
      expect(err.string.lines).to eq(["Error: chi bundle runs on this machine only: run it on studio\n",
                                      "Error: no remote nope (chi remote ls lists them; chi remote add NAME URL adds one)\n",
                                      "Error: unknown command sned (see chi --help)\n"])
    end

    it "runs the command with a Remote on the named remote, and names it when it can't be reached" do
      Samagotchi::Remotes.put(RemoteBackend.entry, path: remotes)
      state_dir = File.join(tmpdir, "state")
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap { |s| s.save(state_dir: state_dir) }
      out = StringIO.new
      allow($stdout).to receive(:puts) { |line| out.puts(line) }

      transport = RemoteBackend::RackTransport.new(RemoteBackend.app(state_dir: state_dir))
      expect(described_class.new(["note", "-m", "hi", session.id[0, 8]], remote: "studio").run(subcommands, stderr: err, transport: transport))
        .to eq(0), err.string
      expect(out.string).to include("#{session.id[0, 8]}  waits for the session's next start (1 note queued)")

      down = ->(*_a, **_o) { raise Samagotchi::SessionAccess::RemoteFailed, "remote studio (http://192.0.2.10:4567): connection refused" }
      expect(described_class.new(%w[note -m hi ab], remote: "studio").run(subcommands, stderr: err, transport: down)).to eq(1)
      expect(err.string).to include("chi note: remote studio (http://192.0.2.10:4567): connection refused")
    end
  end

  describe "bin/chi" do
    it "refuses a local-only command under --remote and CHI_REMOTE before anything else (exit 2), and runs chi remote" do
      env = isolated_chi_env(tmpdir)
      out, err, status = run_chi("--remote", "studio", "sessions", "stats", "ab", env: env)
      expect([status.exitstatus, err]).to eq([2, "Error: chi sessions stats runs on this machine only: run it on studio\n"]), out

      _out, err, status = fork_chi("send", "-m", "x", "ab", env: env.merge("CHI_REMOTE" => "nope"))
      expect([status.exitstatus, err]).to eq([2, "Error: no remote nope (chi remote ls lists them; chi remote add NAME URL adds one)\n"])

      out, _err, status = fork_chi("remote", "ls", env: env.merge("CHI_REMOTE" => "nope"))
      expect([status.exitstatus, out]).to eq([0, "no remotes (chi remote add NAME URL --token-file FILE)\n"])
    end

    it "takes a remote attach's run flags to the remote before this machine's checks; refuses the local-only ones (exit 2)" do
      env = isolated_chi_env(tmpdir)
      closed = TCPServer.new("127.0.0.1", 0).then { |server| server.local_address.ip_port.tap { server.close } }
      Samagotchi::Remotes.put(Samagotchi::Remotes::Entry.new(name: "studio", url: "http://127.0.0.1:#{closed}", token: nil),
                              path: File.join(tmpdir, "config", "samagotchi", "remotes.yml"))

      # Never resolved here (no such session on this machine): the remote is asked.
      _out, err, status = fork_chi("--remote", "studio", "--attach", "ab12", env: env)
      expect([status.exitstatus, err]).to eq([1, "Error: remote studio (http://127.0.0.1:#{closed}): connection refused\n"])

      _out, err, status = fork_chi("--remote", "studio", "-p", "hi", env: env)
      expect([status.exitstatus, err]).to eq([2, "Error: a new session on studio needs --dir, that machine's absolute path " \
                                                 "(or --attach ID / --resume ID)\n"])

      _out, err, status = fork_chi("--remote", "studio", "--attach", "ab12", "--verbose", env: env)
      expect([status.exitstatus, err]).to eq([2, "Error: chi --verbose runs on this machine only: run it on studio\n"])

      _out, err, status = fork_chi("--dir", "/x", "-p", "hi", env: env)
      expect([status.exitstatus, err]).to eq([2, "Error: --dir goes with --remote; cd there instead\n"])
    end
  end
end
