# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "rbconfig"
require "samagotchi/context_sources"
require_relative "../../support/fake_executables"
require_relative "../../support/fake_chi_context"

# The codex-peer bundle's scripts/pair, as Codex runs it, attaching
# codex-inbox and codex-outbox to a chi session. Nothing is queued: pairing
# only records the thread id.
#
# The mechanism runs this checkout's chi (isolated state): "with real chi".
# The variants (refusals, remote routing, odd cwds, sandbox hints) run on a
# fake chi (spec/support/fake_chi_context.rb) and check what the script
# asked chi to do; chi's context commands have their own specs.
RSpec.describe "The codex-peer pair script" do
  let(:pair) { File.expand_path("../../../lib/samagotchi/bundles/codex-peer/scripts/pair", __dir__) }
  let(:tmpdir) { File.realpath(Dir.mktmpdir("codex-peer-pair")) }
  let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:state_home) { File.join(tmpdir, "state") }
  let(:id) { "0f1e2d3c-4b5a-4968-8776-655443322110" }
  let(:fake) { FakeChiContext.new(bin) }
  let(:env) do
    { "XDG_STATE_HOME" => state_home, "CODEX_HOME" => nil, "CHI_REMOTE" => nil, "CHI" => fake.path }
  end
  let(:thread_a) { "019a1b2c-3d4e-7f80-9abc-def012345678" }
  let(:thread_b) { "019a1b2c-3d4e-7f80-9abc-def0123456ff" }

  after { FileUtils.rm_rf(tmpdir) }

  def run_pair(arg, thread:, extra: {}, chdir: tmpdir)
    Open3.capture3(env.merge("CODEX_THREAD_ID" => thread).merge(extra), "sh", pair, arg, chdir: chdir)
  end

  context "with real chi" do
    let(:chi_bin) { File.expand_path("../../../bin/chi", __dir__) }
    let(:state_dir) { File.join(state_home, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                         .tap { |s| s.save(state_dir: state_dir) }
    end
    let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }
    let(:env) do
      { "XDG_STATE_HOME" => state_home, "XDG_CONFIG_HOME" => File.join(tmpdir, "config"), "CODEX_HOME" => nil,
        "CHI_REMOTE" => nil, "CHI" => FakeExecutables.fake_executable(bin, "chi", "exec #{RbConfig.ruby} #{chi_bin} \"$@\"") }
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

    it "says why when chi can't attach (no such session)" do
      _, err, status = run_pair("ffffffff", thread: thread_a)

      expect(status.exitstatus).to eq(1)
      expect(err).to include("ffffffff")
    end
  end

  it "pushes a cwd with a carriage return or another control character as valid JSON" do
    odd = File.join(tmpdir, "odd\r\u0001dir").tap { |d| FileUtils.mkdir_p(d) }
    _, err, status = run_pair(id, thread: thread_a, chdir: odd)

    expect([status.exitstatus, err]).to eq([0, ""])
    # Parsed strictly: a raw CR or \x01 in a JSON string is refused.
    pushed = fake.pushed("codex-inbox")
    expect(pushed["text"]).to include("codex cwd: #{odd}\n")
    expect(pushed["summary"]).to eq("Codex paired from #{odd}")
  end

  it "refuses outside Codex, a URL without a session and a missing argument, never running chi" do
    _, err, status = run_pair(id, thread: "")
    expect([status.exitstatus, err]).to eq([2, "pair: CODEX_THREAD_ID isn't set: run this from a Codex CLI session\n"])

    _, err, status = run_pair("http://127.0.0.1:4567/", thread: thread_a)
    expect([status.exitstatus, err]).to eq([2, "pair: no session id in http://127.0.0.1:4567/ (a chi web URL ends in #/s/<id>)\n"])

    _, err, status = Open3.capture3(env, "sh", pair)
    expect([status.exitstatus, err]).to eq([2, "usage: pair <chi session id or URL (http://127.0.0.1:4567/#/s/<id>)>\n"])
    expect(fake.calls).to eq([])
  end

  context "through a remote" do
    let(:remote_why) { "Codex's answers to what you sent it (codex-peer); Codex runs on another machine: codex_send can't reach it" }

    def run_remote(chi: fake.path, remote: nil, extra: {})
      run_pair(id, thread: thread_a, extra: { "CHI" => chi, "CHI_REMOTE" => remote }.merge(extra))
    end

    def says(remote, ask)
      "pair: chi is on #{remote}, so chi can't send to this Codex session (codex_send runs codex queue on chi's " \
        "machine): paired with chi #{id}, codex-outbox only. Answer chi with #{ask} context push codex-outbox " \
        "#{id}; chi's replies reach you only when the user relays them (or asks you to run #{ask} send --wait " \
        "#{id})\n"
    end

    it "with CHI_REMOTE set, attaches only codex-outbox and says chi there can't send to this Codex" do
      out, err, status = run_remote(remote: " studio ")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "CHI_REMOTE=studio #{fake.path}"))
      expect(out).not_to include("codex-inbox", "(thread")
      expect(fake.source("codex-outbox")).to eq(why: remote_why, hint: "latest Codex reply")
      expect(fake.source("codex-inbox")).to be_nil
      expect(fake.calls.map(&:first)).to all(eq(" studio ")) # chi trims it itself
      expect(fake.calls.flat_map(&:last)).not_to include("codex-inbox")
    end

    it "takes the remote a --remote NAME or --remote=NAME in CHI names over CHI_REMOTE, the last one" do
      out, err, status = run_remote(chi: "#{fake.path} --remote studio", remote: "other")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "#{fake.path} --remote studio"))

      out, err, status = run_remote(chi: "#{fake.path} --remote=laptop --remote=studio")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "#{fake.path} --remote=laptop --remote=studio"))
      expect(fake.source("codex-inbox")).to be_nil
    end

    it "pairs here, both sources, with a blank CHI_REMOTE" do
      out, err, status = run_remote(remote: "  ")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to include("paired with chi #{id} (thread #{thread_a})")
      expect(out).not_to include("pair: chi is on")
      expect(fake.source("codex-inbox")).to include(hint: thread_a)
    end

    it "says only chi's refusal when the outbox can't be attached there" do
      out, err, status = run_remote(remote: "studio", extra: { "FAKE_CHI_FAIL" => "Error: no remote studio (chi remote ls)" })

      expect(status.exitstatus).to eq(1)
      expect(err).to eq("Error: no remote studio (chi remote ls)\n")
      expect(out).to eq("")
    end

    it "names the network_access line, not writable_roots, when chi can't reach the remote" do
      broke = "chi context: studio (http://192.0.2.1:4567): the connection broke (EPERM)"

      _, err, status = run_remote(remote: "studio", extra: { "FAKE_CHI_FAIL" => broke })

      expect(status.exitstatus).to eq(1)
      expect(err).to eq(<<~ERR)
        #{broke}
        pair: Codex's sandbox may be keeping chi from reaching studio (workspace-write has no network by default): if so, add to ~/.codex/config.toml
          [sandbox_workspace_write]
          network_access = true
        then restart Codex and pair again.
      ERR
    end
  end

  it "names the writable_roots line when Codex's sandbox keeps chi from writing its state" do
    blocked = "chi: Operation not permitted @ rb_sysopen - #{state_home}/x"

    _, err, status = run_pair(id, thread: thread_a, extra: { "FAKE_CHI_FAIL" => blocked })

    expect(status.exitstatus).to eq(1)
    expect(err).to include("Operation not permitted",
                           "Codex's sandbox can't write chi's state: add to ~/.codex/config.toml",
                           "[sandbox_workspace_write]",
                           "writable_roots = [\"#{state_home}/samagotchi/context\"]",
                           "then restart Codex")
  end
end
