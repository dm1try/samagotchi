# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "rbconfig"
require "samagotchi/context_sources"
require_relative "../../support/fake_executables"

# The claude-peer bundle's scripts/pair, as Claude runs it: with this
# checkout's chi (isolated state) attaching claude-inbox and claude-outbox
# to a chi session. No socket is opened: pairing only records its path.
RSpec.describe "The claude-peer pair script" do
  let(:pair) { File.expand_path("../../../lib/samagotchi/bundles/claude-peer/scripts/pair", __dir__) }
  let(:chi_bin) { File.expand_path("../../../bin/chi", __dir__) }
  let(:tmpdir) { File.realpath(Dir.mktmpdir("claude-peer-pair")) }
  let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:state_home) { File.join(tmpdir, "state") }
  let(:state_dir) { File.join(state_home, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                       .tap { |s| s.save(state_dir: state_dir) }
  end
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }
  let(:env) do
    { "XDG_STATE_HOME" => state_home, "XDG_CONFIG_HOME" => File.join(tmpdir, "config"),
      "CHI" => FakeExecutables.fake_executable(bin, "chi", "exec #{RbConfig.ruby} #{chi_bin} \"$@\"") }
  end

  after { FileUtils.rm_rf(tmpdir) }

  def run_pair(*args, socket:)
    Open3.capture3(env.merge("CLAUDE_CODE_MESSAGING_SOCKET" => socket), "sh", pair, *args, chdir: tmpdir)
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

  # Not only as `sh pair`: an assignment before `shift` on one line kept
  # its value only where shift is a POSIX special builtin (dash, bash as
  # sh), so `bash pair` and zsh refused every call with the usage.
  %w[bash zsh].each do |shell|
    it "pairs run by #{shell}, an id alone or with --inbox-socket" do
      skip "no #{shell}" unless system("command -v #{shell} >/dev/null 2>&1")
      socket = { "CLAUDE_CODE_MESSAGING_SOCKET" => "/tmp/claude-a.sock" }
      _, err, status = Open3.capture3(env.merge(socket), shell, pair, session.id, chdir: tmpdir)
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(own.source("claude-inbox")).to have_attributes(hint: "/tmp/claude-a.sock")

      _, err, status = Open3.capture3(env.merge(socket), shell, pair, "--inbox-socket=/tmp/pod.sock", session.id, chdir: tmpdir)
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(own.snapshot("claude-inbox").hint).to eq("/tmp/pod.sock")
    end
  end

  it "pushes a cwd with a carriage return or another control character as valid JSON" do
    odd = File.join(tmpdir, "odd\r\u0001dir").tap { |d| FileUtils.mkdir_p(d) }
    _, err, status = Open3.capture3(env.merge("CLAUDE_CODE_MESSAGING_SOCKET" => "/tmp/claude-a.sock"), "sh", pair, session.id,
                                    chdir: odd)

    expect([status.exitstatus, err]).to eq([0, ""])
    # The push parsed (a raw CR or \x01 in a JSON string is refused); the
    # one-line summary has chi's own CR-as-space.
    expect(own.snapshot("claude-inbox").text).to include("claude cwd: #{odd}\n")
    expect(own.snapshot("claude-inbox").summary).to end_with("odd \u0001dir")
  end

  it "refuses outside Claude Code, a URL without a session and a missing argument, touching nothing" do
    _, err, status = run_pair(session.id, socket: "")
    expect([status.exitstatus, err]).to eq([2, "pair: CLAUDE_CODE_MESSAGING_SOCKET isn't set: run this from a Claude Code " \
                                               "session (2.1.224 or later)\n"])

    _, err, status = run_pair("http://127.0.0.1:4567/", socket: "/tmp/x.sock")
    expect([status.exitstatus, err]).to eq([2, "pair: no session id in http://127.0.0.1:4567/ (a chi web URL ends in #/s/<id>)\n"])

    _, err, status = Open3.capture3(env, "sh", pair)
    expect([status.exitstatus, err]).to eq([2, "usage: pair [--inbox-socket PATH] " \
                                             "<chi session id or URL (http://127.0.0.1:4567/#/s/<id>)>\n"])
    expect(own.source("claude-inbox")).to be_nil
  end

  it "refuses a relative --inbox-socket and one without a path, touching nothing" do
    _, err, status = run_pair("--inbox-socket", "claude.sock", session.id, socket: "/tmp/claude-a.sock")
    expect([status.exitstatus, err]).to eq([2, "pair: --inbox-socket needs an absolute socket path on chi's machine " \
                                             "(the ssh -R forward's remote end): claude.sock\n"])

    _, err, status = Open3.capture3(env.merge("CLAUDE_CODE_MESSAGING_SOCKET" => "/tmp/claude-a.sock"),
                                    "sh", pair, "--inbox-socket", session.id, chdir: tmpdir)
    expect([status.exitstatus, err]).to eq([2, "usage: pair [--inbox-socket PATH] " \
                                             "<chi session id or URL (http://127.0.0.1:4567/#/s/<id>)>\n"])

    _, err, status = Open3.capture3(env.merge("CLAUDE_CODE_MESSAGING_SOCKET" => "/tmp/claude-a.sock"),
                                    "sh", pair, "--inbox-socket=", session.id, chdir: tmpdir)
    expect([status.exitstatus, err]).to eq([2, "usage: pair [--inbox-socket PATH] " \
                                             "<chi session id or URL (http://127.0.0.1:4567/#/s/<id>)>\n"])

    _, err, status = Open3.capture3(env.merge("CLAUDE_CODE_MESSAGING_SOCKET" => "/tmp/claude-a.sock"),
                                    "sh", pair, "--inbox-socket", "/tmp/pod.sock", session.id, session.id,
                                    chdir: tmpdir)
    expect([status.exitstatus, err]).to eq([2, "usage: pair [--inbox-socket PATH] " \
                                             "<chi session id or URL (http://127.0.0.1:4567/#/s/<id>)>\n"])

    expect(own.source("claude-inbox")).to be_nil
    expect(own.source("claude-outbox")).to be_nil
  end

  context "through a remote" do
    # A chi that drops the remote (CHI_REMOTE, a --remote NAME word) and runs
    # this checkout's chi here, logging the remote and arguments it was given:
    # the script's branch, no chi web.
    let(:log) { File.join(tmpdir, "chi.log") }
    let(:local_chi) do
      FakeExecutables.fake_executable(bin, "chi-remote", <<~SH)
        printf '%s|%s\n' "${CHI_REMOTE:-}" "$*" >> #{log}
        unset CHI_REMOTE
        skip=
        for a do
          shift
          if [ -n "$skip" ]; then skip=; continue; fi
          case $a in --remote) skip=1; continue ;; --remote=*) continue ;; esac
          set -- "$@" "$a"
        done
        exec #{RbConfig.ruby} #{chi_bin} "$@"
      SH
    end
    let(:remote_why) { "Claude's answers to what you sent it (claude-peer); Claude runs on another machine: claude_send can't reach it" }
    let(:local_why) { "Claude's answers to what you sent it (claude-peer)" }

    def run_remote(chi:, remote: nil, args: [session.id])
      extra = { "CHI" => chi, "CHI_REMOTE" => remote, "CLAUDE_CODE_MESSAGING_SOCKET" => "/tmp/claude-a.sock" }
      Open3.capture3(env.merge(extra), "sh", pair, *args, chdir: tmpdir)
    end

    def says(remote, ask)
      "pair: chi is on #{remote}, so chi can't send to this Claude session (claude_send needs its socket on chi's " \
        "machine): paired with chi #{session.id}, claude-outbox only. Answer chi with #{ask} context push claude-outbox " \
        "#{session.id}; chi's replies reach you only when the user relays them (or asks you to run #{ask} send --wait " \
        "#{session.id})\n"
    end

    def forward_hint(remote)
      "pair: to let chi send here too, forward this Claude's socket to #{remote} with ssh -R and pair again with " \
        "--inbox-socket (the chi-peer skill's \"chi on another machine over SSH\")\n"
    end

    it "with CHI_REMOTE set, attaches only claude-outbox and says chi there can't send to this Claude" do
      out, err, status = run_remote(chi: local_chi, remote: " studio ")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "CHI_REMOTE=studio #{local_chi}"))
      expect(out).to include(forward_hint("studio"))
      expect(out).not_to include("claude-inbox", "(socket")
      expect(own.source("claude-outbox")).to have_attributes(why: remote_why, hint: "latest Claude reply", cmd: nil)
      expect(own.source("claude-inbox")).to be_nil
      expect(File.readlines(log)).to all(start_with(" studio |")) # chi trims it itself
      expect(File.read(log)).not_to include("claude-inbox")
    end

    it "takes the remote a --remote NAME or --remote=NAME in CHI names over CHI_REMOTE, the last one" do
      out, err, status = run_remote(chi: "#{local_chi} --remote studio", remote: "other")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "#{local_chi} --remote studio"))

      out, err, status = run_remote(chi: "#{local_chi} --remote=laptop --remote=studio")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "#{local_chi} --remote=laptop --remote=studio"))
      expect(own.source("claude-inbox")).to be_nil
    end

    it "pairs here, both sources, with a blank CHI_REMOTE" do
      out, err, status = run_remote(chi: local_chi, remote: "  ")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to include("paired with chi #{session.id} (socket /tmp/claude-a.sock)")
      expect(out).not_to include("pair: chi is on")
      expect(own.source("claude-inbox")).to have_attributes(hint: "/tmp/claude-a.sock")
    end

    it "through a remote, --inbox-socket attaches both sources with that path as the hint" do
      out, err, status = run_remote(chi: local_chi, remote: "studio", args: ["--inbox-socket", "/tmp/pod-claude.sock", session.id])

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to include("paired with chi #{session.id} (socket /tmp/pod-claude.sock on chi's machine, " \
                             "forwarded to this Claude's /tmp/claude-a.sock)")
      expect(out).not_to include("pair: chi is on")
      expect(own.source("claude-inbox")).to have_attributes(hint: "/tmp/pod-claude.sock", cmd: nil)
      inbox = own.snapshot("claude-inbox")
      expect(inbox.summary).to eq("Claude Code paired from #{tmpdir} over ssh")
      expect(inbox.text).to include("socket: /tmp/pod-claude.sock (on this machine: an ssh -R forward of Claude's " \
                                    "socket /tmp/claude-a.sock", "claude cwd: #{tmpdir}", "the ssh tunnel may be down")
      expect(own.source("claude-outbox")).to have_attributes(why: local_why, hint: "latest Claude reply")

      # The --inbox-socket=PATH form does the same.
      _, err, status = run_remote(chi: local_chi, remote: "studio", args: ["--inbox-socket=/tmp/pod-claude.sock", session.id])
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(own.snapshot("claude-inbox").hint).to eq("/tmp/pod-claude.sock")
    end

    it "re-pairing with --inbox-socket replaces an outbox-only pairing's claude-outbox and its why" do
      _, err, status = run_remote(chi: local_chi, remote: "studio")
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(own.source("claude-outbox")).to have_attributes(why: remote_why)

      _, err, status = run_remote(chi: local_chi, remote: "studio", args: ["--inbox-socket", "/tmp/pod-claude.sock", session.id])
      expect([status.exitstatus, err]).to eq([0, ""])
      expect(own.source("claude-outbox")).to have_attributes(why: local_why, hint: "latest Claude reply")
      expect(own.source("claude-inbox")).to have_attributes(hint: "/tmp/pod-claude.sock")
    end

    it "says only chi's refusal when the outbox can't be attached there" do
      out, err, status = run_remote(chi: env["CHI"], remote: "studio")

      expect(status.exitstatus).to eq(1)
      expect(err).to start_with("Error: no remote studio (")
      expect(out).to eq("")
      expect(own.source("claude-outbox")).to be_nil
    end
  end

  it "says why when chi can't attach (no such session)" do
    _, err, status = run_pair("ffffffff", socket: "/tmp/x.sock")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("ffffffff")
  end
end
