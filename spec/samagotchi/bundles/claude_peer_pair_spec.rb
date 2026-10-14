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

  def run_pair(arg, socket:)
    Open3.capture3(env.merge("CLAUDE_CODE_MESSAGING_SOCKET" => socket), "sh", pair, arg, chdir: tmpdir)
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

  it "refuses outside Claude Code, a URL without a session and a missing argument, touching nothing" do
    _, err, status = run_pair(session.id, socket: "")
    expect([status.exitstatus, err]).to eq([2, "pair: CLAUDE_CODE_MESSAGING_SOCKET isn't set: run this from a Claude Code " \
                                               "session (2.1.224 or later)\n"])

    _, err, status = run_pair("http://127.0.0.1:4567/", socket: "/tmp/x.sock")
    expect([status.exitstatus, err]).to eq([2, "pair: no session id in http://127.0.0.1:4567/ (a chi web URL ends in #/s/<id>)\n"])

    _, err, status = Open3.capture3(env, "sh", pair)
    expect([status.exitstatus, err]).to eq([2, "usage: pair <chi session id or URL (http://127.0.0.1:4567/#/s/<id>)>\n"])
    expect(own.source("claude-inbox")).to be_nil
  end

  it "says why when chi can't attach (no such session)" do
    _, err, status = run_pair("ffffffff", socket: "/tmp/x.sock")

    expect(status.exitstatus).to eq(1)
    expect(err).to include("ffffffff")
  end
end
