# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "rbconfig"
require "samagotchi/context_sources"
require_relative "../../support/fake_executables"

# The codex-peer bundle's scripts/pair, as Codex runs it: with this
# checkout's chi (isolated state) attaching codex-inbox and codex-outbox
# to a chi session. Nothing is queued: pairing only records the thread id.
RSpec.describe "The codex-peer pair script" do
  let(:pair) { File.expand_path("../../../lib/samagotchi/bundles/codex-peer/scripts/pair", __dir__) }
  let(:chi_bin) { File.expand_path("../../../bin/chi", __dir__) }
  let(:tmpdir) { File.realpath(Dir.mktmpdir("codex-peer-pair")) }
  let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:state_home) { File.join(tmpdir, "state") }
  let(:state_dir) { File.join(state_home, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                       .tap { |s| s.save(state_dir: state_dir) }
  end
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }
  let(:env) do
    { "XDG_STATE_HOME" => state_home, "XDG_CONFIG_HOME" => File.join(tmpdir, "config"), "CODEX_HOME" => nil,
      "CHI" => FakeExecutables.fake_executable(bin, "chi", "exec #{RbConfig.ruby} #{chi_bin} \"$@\"") }
  end
  let(:thread_a) { "019a1b2c-3d4e-7f80-9abc-def012345678" }
  let(:thread_b) { "019a1b2c-3d4e-7f80-9abc-def0123456ff" }

  after { FileUtils.rm_rf(tmpdir) }

  def run_pair(arg, thread:, extra: {})
    Open3.capture3(env.merge("CODEX_THREAD_ID" => thread).merge(extra), "sh", pair, arg, chdir: tmpdir)
  end

  it "pairs from a chi web URL, and a re-pair by id prefix refreshes the thread and keeps Codex's last answer" do
    out, err, status = run_pair("http://127.0.0.1:4567/#/s/#{session.id}", thread: thread_a)

    expect([status.exitstatus, err]).to eq([0, ""])
    expect(out).to include("paired with chi #{session.id} (thread #{thread_a})", "codex-inbox", "codex-outbox")
    expect(own.source("codex-inbox")).to have_attributes(hint: thread_a, cmd: nil)
    inbox = own.snapshot("codex-inbox")
    expect(inbox).to have_attributes(hint: thread_a, summary: "Codex paired from #{tmpdir}")
    expect(inbox.text).to include("Codex peer inbox", "thread: #{thread_a}", "codex cwd: #{tmpdir}", "codex_send")
    # No placeholder: Codex's first answer (wake: true) wakes chi (chi 0.63.0).
    expect(own.source("codex-outbox")).to have_attributes(hint: "latest Codex reply", cmd: nil)
    expect(own.snapshot("codex-outbox").text).to be_nil

    own.record_text("codex-outbox", Samagotchi::ContextSources::Fetched.new(text: "VERDICT: OK", summary: "ok",
                                                                            wake: true, hint: nil))
    _, err, status = run_pair(session.id[0, 8], thread: thread_b)

    expect([status.exitstatus, err]).to eq([0, ""])
    expect(own.snapshot("codex-inbox").hint).to eq(thread_b)
    expect(own.snapshot("codex-outbox").text).to eq("VERDICT: OK")
  end

  it "refuses outside Codex, a URL without a session and a missing argument, touching nothing" do
    _, err, status = run_pair(session.id, thread: "")
    expect([status.exitstatus, err]).to eq([2, "pair: CODEX_THREAD_ID isn't set: run this from a Codex CLI session\n"])

    _, err, status = run_pair("http://127.0.0.1:4567/", thread: thread_a)
    expect([status.exitstatus, err]).to eq([2, "pair: no session id in http://127.0.0.1:4567/ (a chi web URL ends in #/s/<id>)\n"])

    _, err, status = Open3.capture3(env, "sh", pair)
    expect([status.exitstatus, err]).to eq([2, "usage: pair <chi session id or URL (http://127.0.0.1:4567/#/s/<id>)>\n"])
    expect(own.source("codex-inbox")).to be_nil
  end

  it "says why when chi can't attach (no such session)" do
    _, err, status = run_pair("ffffffff", thread: thread_a)

    expect(status.exitstatus).to eq(1)
    expect(err).to include("ffffffff")
  end

  it "names the writable_roots line when Codex's sandbox keeps chi from writing its state" do
    blocked = FakeExecutables.fake_executable(bin, "chi-blocked",
                                              "echo \"chi: Operation not permitted @ rb_sysopen - #{state_home}/x\" >&2\nexit 1")

    _, err, status = run_pair(session.id, thread: thread_a, extra: { "CHI" => blocked })

    expect(status.exitstatus).to eq(1)
    expect(err).to include("Operation not permitted",
                           "Codex's sandbox can't write chi's state: add to ~/.codex/config.toml",
                           "[sandbox_workspace_write]",
                           "writable_roots = [\"#{state_home}/samagotchi/context\"]",
                           "then restart Codex")
  end
end
