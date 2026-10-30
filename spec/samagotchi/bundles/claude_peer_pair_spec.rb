# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "rbconfig"
require "samagotchi/context_sources"
require_relative "../../support/fake_executables"
require_relative "../../support/fake_chi_context"

# The claude-peer bundle's scripts/pair, as Claude runs it, attaching
# claude-inbox and claude-outbox to a chi session. No socket is opened:
# pairing only records its path.
#
# The mechanism runs this checkout's chi (isolated state): "with real chi".
# The variants (shells, refusals, remote routing, odd cwds) run on a fake chi
# (spec/support/fake_chi_context.rb) and check what the script asked chi to
# do; chi's context commands have their own specs.
RSpec.describe "The claude-peer pair script" do
  let(:pair) { File.expand_path("../../../lib/samagotchi/bundles/claude-peer/scripts/pair", __dir__) }
  let(:tmpdir) { File.realpath(Dir.mktmpdir("claude-peer-pair")) }
  let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:id) { "0f1e2d3c-4b5a-4968-8776-655443322110" }
  let(:fake) { FakeChiContext.new(bin) }
  let(:env) { { "CHI" => fake.path, "CHI_REMOTE" => nil } }
  let(:usage) { "usage: pair [--inbox-socket PATH] <chi session id or URL (http://127.0.0.1:4567/#/s/<id>)>\n" }

  after { FileUtils.rm_rf(tmpdir) }

  def run_pair(*args, socket:, extra: {}, chdir: tmpdir)
    Open3.capture3(env.merge("CLAUDE_CODE_MESSAGING_SOCKET" => socket).merge(extra), "sh", pair, *args, chdir: chdir)
  end

  context "with real chi" do
    let(:chi_bin) { File.expand_path("../../../bin/chi", __dir__) }
    let(:state_home) { File.join(tmpdir, "state") }
    let(:state_dir) { File.join(state_home, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                         .tap { |s| s.save(state_dir: state_dir) }
    end
    let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }
    let(:env) do
      { "XDG_STATE_HOME" => state_home, "XDG_CONFIG_HOME" => File.join(tmpdir, "config"), "CHI_REMOTE" => nil,
        "CHI" => FakeExecutables.fake_executable(bin, "chi", "exec #{RbConfig.ruby} #{chi_bin} \"$@\"") }
    end

    it "pairs from a chi web URL, and a re-pair by id prefix refreshes the socket and keeps Claude's last answer" do
      out, err, status = run_pair("http://127.0.0.1:4567/#/s/#{session.id}", socket: "/tmp/claude-a.sock")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to include("paired with chi #{session.id} (socket /tmp/claude-a.sock)", "claude-inbox", "claude-outbox")
      expect(own.source("claude-inbox")).to have_attributes(hint: "/tmp/claude-a.sock", cmd: nil)
      inbox = own.snapshot("claude-inbox")
      expect(inbox).to have_attributes(hint: "/tmp/claude-a.sock", summary: "Claude Code paired from #{tmpdir}")
      expect(inbox.text).to include("socket: /tmp/claude-a.sock", "claude cwd: #{tmpdir}", "claude_send")
      # No placeholder: Claude's first answer (wake: true) wakes chi (chi 0.63.0).
      expect(own.source("claude-outbox")).to have_attributes(hint: "latest Claude reply", cmd: nil)
      expect(own.snapshot("claude-outbox").text).to be_nil

      own.record_text("claude-outbox", Samagotchi::ContextSources::Fetched.new(text: "VERDICT: OK", summary: "ok",
                                                                               wake: true, hint: nil))
      _, err, status = run_pair(session.id[0, 8], socket: "/tmp/claude-b.sock")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(own.snapshot("claude-inbox").hint).to eq("/tmp/claude-b.sock")
      expect(own.snapshot("claude-outbox").text).to eq("VERDICT: OK")
    end

    it "says why when chi can't attach (no such session)" do
      _, err, status = run_pair("ffffffff", socket: "/tmp/x.sock")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("ffffffff")
    end
  end

  # Not only as `sh pair`: an assignment before `shift` on one line kept
  # its value only where shift is a POSIX special builtin (dash, bash as
  # sh), so `bash pair` and zsh refused every call with the usage.
  %w[bash zsh].each do |shell|
    it "pairs run by #{shell}, an id alone or with --inbox-socket" do
      skip "no #{shell}" unless system("command -v #{shell} >/dev/null 2>&1")
      socket = { "CLAUDE_CODE_MESSAGING_SOCKET" => "/tmp/claude-a.sock" }
      _, err, status = Open3.capture3(env.merge(socket), shell, pair, id, chdir: tmpdir)
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(fake.source("claude-inbox")).to include(hint: "/tmp/claude-a.sock")

      _, err, status = Open3.capture3(env.merge(socket), shell, pair, "--inbox-socket=/tmp/pod.sock", id, chdir: tmpdir)
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(fake.pushed("claude-inbox")).to include("hint" => "/tmp/pod.sock")
    end
  end

  it "pushes a cwd with a carriage return or another control character as valid JSON" do
    odd = File.join(tmpdir, "odd\r\u0001dir").tap { |d| FileUtils.mkdir_p(d) }
    _, err, status = run_pair(id, socket: "/tmp/claude-a.sock", chdir: odd)

    expect([status.exitstatus, err]).to eq([0, ""])
    # Parsed strictly: a raw CR or \x01 in a JSON string is refused.
    pushed = fake.pushed("claude-inbox")
    expect(pushed["text"]).to include("claude cwd: #{odd}\n")
    expect(pushed["summary"]).to eq("Claude Code paired from #{odd}")
  end

  it "refuses outside Claude Code, a URL without a session and a missing argument, never running chi" do
    _, err, status = run_pair(id, socket: "")
    expect([status.exitstatus, err]).to eq([2, "pair: CLAUDE_CODE_MESSAGING_SOCKET isn't set: run this from a Claude Code " \
                                               "session (2.1.224 or later)\n"])

    _, err, status = run_pair("http://127.0.0.1:4567/", socket: "/tmp/x.sock")
    expect([status.exitstatus, err]).to eq([2, "pair: no session id in http://127.0.0.1:4567/ (a chi web URL ends in #/s/<id>)\n"])

    _, err, status = Open3.capture3(env, "sh", pair)
    expect([status.exitstatus, err]).to eq([2, usage])
    expect(fake.calls).to eq([])
  end

  it "refuses a relative --inbox-socket and one without a path, never running chi" do
    _, err, status = run_pair("--inbox-socket", "claude.sock", id, socket: "/tmp/claude-a.sock")
    expect([status.exitstatus, err]).to eq([2, "pair: --inbox-socket needs an absolute socket path on chi's machine " \
                                             "(the ssh -R forward's remote end): claude.sock\n"])

    [["--inbox-socket", id], ["--inbox-socket=", id], ["--inbox-socket", "/tmp/pod.sock", id, id]].each do |args|
      _, err, status = run_pair(*args, socket: "/tmp/claude-a.sock")
      expect([status.exitstatus, err]).to eq([2, usage]), args.inspect
    end

    expect(fake.calls).to eq([])
  end

  context "through a remote" do
    let(:remote_why) { "Claude's answers to what you sent it (claude-peer); Claude runs on another machine: claude_send can't reach it" }
    let(:local_why) { "Claude's answers to what you sent it (claude-peer)" }

    def run_remote(chi: fake.path, remote: nil, args: [id], extra: {})
      run_pair(*args, socket: "/tmp/claude-a.sock", extra: { "CHI" => chi, "CHI_REMOTE" => remote }.merge(extra))
    end

    def says(remote, ask)
      "pair: chi is on #{remote}, so chi can't send to this Claude session (claude_send needs its socket on chi's " \
        "machine): paired with chi #{id}, claude-outbox only. Answer chi with #{ask} context push claude-outbox " \
        "#{id}; chi's replies reach you only when the user relays them (or asks you to run #{ask} send --wait " \
        "#{id})\n"
    end

    def forward_hint(remote)
      "pair: to let chi send here too, forward this Claude's socket to #{remote} with ssh -R and pair again with " \
        "--inbox-socket (the chi-peer skill's \"chi on another machine over SSH\")\n"
    end

    it "with CHI_REMOTE set, attaches only claude-outbox and says chi there can't send to this Claude" do
      out, err, status = run_remote(remote: " studio ")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "CHI_REMOTE=studio #{fake.path}"))
      expect(out).to include(forward_hint("studio"))
      expect(out).not_to include("claude-inbox", "(socket")
      expect(fake.source("claude-outbox")).to eq(why: remote_why, hint: "latest Claude reply")
      expect(fake.source("claude-inbox")).to be_nil
      expect(fake.calls.map(&:first)).to all(eq(" studio ")) # chi trims it itself
      expect(fake.calls.flat_map(&:last)).not_to include("claude-inbox")
    end

    it "takes the remote a --remote NAME or --remote=NAME in CHI names over CHI_REMOTE, the last one" do
      out, err, status = run_remote(chi: "#{fake.path} --remote studio", remote: "other")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "#{fake.path} --remote studio"))

      out, err, status = run_remote(chi: "#{fake.path} --remote=laptop --remote=studio")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "#{fake.path} --remote=laptop --remote=studio"))
      expect(fake.source("claude-inbox")).to be_nil
    end

    it "pairs here, both sources, with a blank CHI_REMOTE" do
      out, err, status = run_remote(remote: "  ")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to include("paired with chi #{id} (socket /tmp/claude-a.sock)")
      expect(out).not_to include("pair: chi is on")
      expect(fake.source("claude-inbox")).to include(hint: "/tmp/claude-a.sock")
    end

    it "through a remote, --inbox-socket attaches both sources with that path as the hint" do
      out, err, status = run_remote(remote: "studio", args: ["--inbox-socket", "/tmp/pod-claude.sock", id])

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to include("paired with chi #{id} (socket /tmp/pod-claude.sock on chi's machine, " \
                             "forwarded to this Claude's /tmp/claude-a.sock)")
      expect(out).not_to include("pair: chi is on")
      expect(fake.source("claude-inbox")).to include(hint: "/tmp/pod-claude.sock")
      inbox = fake.pushed("claude-inbox")
      expect(inbox).to include("hint" => "/tmp/pod-claude.sock", "summary" => "Claude Code paired from #{tmpdir} over ssh")
      expect(inbox["text"]).to include("socket: /tmp/pod-claude.sock (on this machine: an ssh -R forward of Claude's " \
                                       "socket /tmp/claude-a.sock", "claude cwd: #{tmpdir}", "the ssh tunnel may be down")
      expect(fake.source("claude-outbox")).to eq(why: local_why, hint: "latest Claude reply")

      # The --inbox-socket=PATH form does the same.
      _, err, status = run_remote(remote: "studio", args: ["--inbox-socket=/tmp/pod-claude.sock", id])
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(fake.pushed("claude-inbox")).to include("hint" => "/tmp/pod-claude.sock")
    end

    it "re-pairing with --inbox-socket replaces an outbox-only pairing's claude-outbox and its why" do
      _, err, status = run_remote(remote: "studio")
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(fake.source("claude-outbox")).to include(why: remote_why)

      _, err, status = run_remote(remote: "studio", args: ["--inbox-socket", "/tmp/pod-claude.sock", id])
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(fake.calls.map(&:last)).to include(["context", "rm", "claude-outbox", id])
      expect(fake.source("claude-outbox")).to eq(why: local_why, hint: "latest Claude reply")
      expect(fake.source("claude-inbox")).to include(hint: "/tmp/pod-claude.sock")
    end

    it "says only chi's refusal when the outbox can't be attached there" do
      out, err, status = run_remote(remote: "studio", extra: { "FAKE_CHI_FAIL" => "Error: no remote studio (chi remote ls)" })

      expect(status.exitstatus).to eq(1)
      expect(err).to eq("Error: no remote studio (chi remote ls)\n")
      expect(out).to eq("")
    end
  end
end
