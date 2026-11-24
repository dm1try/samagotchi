# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "socket"
require "securerandom"
require_relative "../../support/fake_executables"
require_relative "../../support/fake_chi_peer"

# The claude-peer bundle's scripts/pair-remote: the id through the remote,
# the ssh -R forward in the background with a control socket, then
# scripts/pair --inbox-socket. ssh and chi are fakes (SSH, CHI): this checks
# what the script asks them, in what order, and how it ends when ssh can't
# start the forward without a prompt. scripts/pair has its own spec.
RSpec.describe "The claude-peer pair-remote script" do
  let(:script) { File.expand_path("../../../lib/samagotchi/bundles/claude-peer/scripts/pair-remote", __dir__) }
  # Short (a control socket's path has a length limit): TMPDIR for the
  # script too, so its private folder is in here.
  let(:tmpdir) { File.realpath(Dir.mktmpdir("cpr", "/tmp")) }
  let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:id) { SecureRandom.uuid }
  let(:id8) { id[0, 8] }
  let(:remote_sock) { "/tmp/claude-peer-#{id8}.sock" }
  let(:private_dir) { File.join(tmpdir, "claude-peer-#{Process.uid}") }
  let(:control) { File.join(private_dir, "#{id8}.ctl") }
  let(:context) { FakeChiPeer.new(bin) }
  let(:ssh_log) { File.join(tmpdir, "ssh.log") }
  # `chi sessions list --format tsv --archived` answers the listed ids;
  # every other call goes to the chi peer fake.
  let(:chi) do
    FakeExecutables.fake_executable(bin, "chi", <<~SH)
      if [ "$1" = sessions ]; then
        printf '%s\\n' "$CHI_REMOTE $*" >> '#{tmpdir}/sessions.log'
        [ -z "${FAKE_LIST_FAIL:-}" ] || { echo "no such remote" >&2; exit 1; }
        printf '%s\\tone\\n%s\\tother\\n' "${FAKE_ID:-#{id}}" "${FAKE_OTHER_ID:-ffffffff-0000-4000-8000-000000000000}"
        exit 0
      fi
      [ -z "${FAKE_PAIR_FAIL:-}" ] || { echo "chi web isn't answering" >&2; exit 1; }
      exec '#{context.path}' "$@"
    SH
  end
  # Logs each call; FAKE_SSH_FAIL fails every call but -O exit (BatchMode's
  # refusal: no key, a password or 2FA asked).
  let(:ssh) do
    FakeExecutables.fake_executable(bin, "ssh", <<~SH)
      { for a do printf '%s\\037' "$a"; done; printf '\\n'; } >> '#{ssh_log}'
      for a do [ "$a" != -O ] || exit 0; done
      if [ -n "${FAKE_SSH_FAIL:-}" ]; then echo "$FAKE_SSH_FAIL" >&2; exit 255; fi
      exit 0
    SH
  end

  after { FileUtils.rm_rf(tmpdir) }

  def run(*args, extra: {})
    env = { "CHI" => chi, "SSH" => ssh, "CHI_REMOTE" => nil, "CLAUDE_CODE_MESSAGING_SOCKET" => "/tmp/claude-local.sock",
            "TMPDIR" => "#{tmpdir}/" }
    Open3.capture3(env.merge(extra), "sh", script, *args, chdir: tmpdir)
  end

  def ssh_calls = File.exist?(ssh_log) ? File.readlines(ssh_log, chomp: true).map { |l| l.split("\x1f") } : []

  it "resolves the id through the remote, removes the stale socket, forwards in the background, pairs, says how to end it" do
    out, err, status = run("pod", "pod", id[0, 6])

    expect([status.exitstatus, err]).to eq([0, ""])
    expect(File.read(File.join(tmpdir, "sessions.log"))).to eq("pod sessions list --format tsv --archived\n")
    expect(ssh_calls).to eq([
      ["-o", "BatchMode=yes", "pod", "rm", "-f", remote_sock],
      ["-f", "-N", "-M", "-S", control, "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
       "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3", "-R", "#{remote_sock}:/tmp/claude-local.sock", "pod"]
    ])
    expect(File.stat(private_dir).mode & 0o777).to eq(0o700)
    expect(context.calls.map(&:first).uniq).to eq(["pod"])
    expect(context.pairing("claude")).to include(id: id, address: remote_sock)
    expect(out).to include("paired with chi #{id} (socket #{remote_sock} on chi's machine",
                           "end it with: ssh -S \"#{control}\" -O exit pod")
  end

  it "takes a chi web URL" do
    _, err, status = run("pod", "pod", "http://127.0.0.1:4567/#/s/#{id}")

    expect([status.exitstatus, err]).to eq([0, ""])
    expect(context.pairing("claude")).to include(address: remote_sock)
  end

  it "ends the forward an earlier run left (its control socket) before it removes the remote socket" do
    FileUtils.mkdir_p(private_dir, mode: 0o700)
    server = UNIXServer.new(control)
    begin
      _, err, status = run("pod", "pod", id)
    ensure
      server.close
    end

    expect([status.exitstatus, err]).to eq([0, ""])
    expect(ssh_calls.first).to eq(["-S", control, "-O", "exit", "pod"])
    expect(ssh_calls[1]).to eq(["-o", "BatchMode=yes", "pod", "rm", "-f", remote_sock])
  end

  it "prints the commands for the user and stops, pairing nothing, when ssh needs a prompt" do
    out, err, status = run("pod", "pod", id, extra: { "FAKE_SSH_FAIL" => "user@pod: Permission denied (publickey,keyboard-interactive)." })

    expect(status.exitstatus).to eq(1)
    expect(out).to eq("")
    expect(err).to include("didn't start the forward on its own: it needs a password or 2FA",
                           "ssh: user@pod: Permission denied (publickey,keyboard-interactive).",
                           "  ssh pod rm -f #{remote_sock}\n",
                           "  ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 " \
                           "-R \"#{remote_sock}:/tmp/claude-local.sock\" pod\n",
                           "then pair: CHI_REMOTE=pod sh \"#{File.dirname(script)}/pair\" --inbox-socket #{remote_sock} #{id}")
    expect(ssh_calls.size).to eq(1)
    expect(context.calls).to eq([])
  end

  it "ends the forward when pairing fails after it started, and exits 1" do
    _, err, status = run("pod", "pod", id, extra: { "FAKE_PAIR_FAIL" => "1" })

    expect(status.exitstatus).to eq(1)
    expect(err).to include("pair-remote: pairing failed; the forward is ended")
    expect(ssh_calls.map(&:first)).to eq(["-o", "-f", "-S"])
    expect(ssh_calls.last).to eq(["-S", control, "-O", "exit", "pod"])
  end

  it "refuses a listed id that isn't a session id, before any ssh" do
    _, err, status = run("pod", "pod", "x", extra: { "FAKE_ID" => "x; rm -rf ~" })

    expect([status.exitstatus, err]).to eq([1, "pair-remote: chi remote pod listed x; rm -rf ~, which isn't a session id\n"])
    expect(ssh_calls).to eq([])
  end

  it "refuses a private folder that is a link, or not its own" do
    FileUtils.mkdir_p(File.join(tmpdir, "elsewhere"))
    File.symlink(File.join(tmpdir, "elsewhere"), private_dir)
    _, err, status = run("pod", "pod", id)

    expect([status.exitstatus, err]).to eq([1, "pair-remote: #{private_dir} isn't a folder of yours: remove it and run this again\n"])
    expect(ssh_calls).to eq([])
  end

  it "stops with the reason for a prefix of no session, of several, and a remote it can't list" do
    _, err, status = run("pod", "pod", "abcabcab")
    expect([status.exitstatus, err]).to eq([1, "pair-remote: no session abcabcab on chi remote pod\n"])

    _, err, status = run("pod", "pod", id[0, 4], extra: { "FAKE_OTHER_ID" => "#{id[0, 4]}0000-0000-4000-8000-000000000000" })
    expect(err).to include("names several sessions")
    expect(status.exitstatus).to eq(1)

    _, err, status = run("pod", "nope", id, extra: { "FAKE_LIST_FAIL" => "1" })
    expect(err).to include("can't list the sessions on chi remote nope")
    expect(status.exitstatus).to eq(1)
    expect(ssh_calls).to eq([])
  end

  it "refuses without Claude's socket, and with the wrong arguments" do
    _, err, status = run("pod", "pod", id, extra: { "CLAUDE_CODE_MESSAGING_SOCKET" => nil })
    expect([status.exitstatus, err]).to eq([2, "pair-remote: CLAUDE_CODE_MESSAGING_SOCKET isn't set: run this from a Claude Code session (2.1.224 or later)\n"])

    _, err, status = run("pod", id)
    expect(status.exitstatus).to eq(2)
    expect(err).to start_with("usage: pair-remote <ssh host> <chi remote name>")
  end
end
