# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"
require "rbconfig"
require "samagotchi/peer_mailbox"
require_relative "../../support/fake_executables"
require_relative "../../support/fake_chi_peer"

# The codex-peer bundle's scripts/pair, as Codex runs it: one `chi peer pair
# codex <id> --address <thread>`. Nothing is queued: pairing only records
# the thread id.
#
# The mechanism runs this checkout's chi (isolated state): "with real chi".
# The variants (refusals, remote routing, sandbox hints) run on a fake chi
# (spec/support/fake_chi_peer.rb) and check what the script asked chi to do;
# chi peer has its own specs.
RSpec.describe "The codex-peer pair script" do
  let(:pair) { File.expand_path("../../../lib/samagotchi/bundles/codex-peer/scripts/pair", __dir__) }
  let(:tmpdir) { File.realpath(Dir.mktmpdir("codex-peer-pair")) }
  let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:state_home) { File.join(tmpdir, "state") }
  let(:id) { "0f1e2d3c-4b5a-4968-8776-655443322110" }
  let(:fake) { FakeChiPeer.new(bin) }
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
    let(:env) do
      { "XDG_STATE_HOME" => state_home, "XDG_CONFIG_HOME" => File.join(tmpdir, "config"), "CODEX_HOME" => nil,
        "CHI_REMOTE" => nil, "CHI" => FakeExecutables.fake_executable(bin, "chi", "exec #{RbConfig.ruby} #{chi_bin} \"$@\"") }
    end

    def link = Samagotchi::PeerMailbox.link(session.id, "codex", state_dir: state_dir)

    it "pairs from a chi web URL, and a re-pair by id prefix refreshes the thread" do
      out, err, status = run_pair("http://127.0.0.1:4567/#/s/#{session.id}", thread: thread_a)

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to eq("paired with chi #{session.id} (thread #{thread_a})\n")
      expect(link).to have_attributes(peer: "codex", address: thread_a, from: "Codex in #{tmpdir}")

      _, err, status = run_pair(session.id[0, 8], thread: thread_b)

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(link.address).to eq(thread_b)
    end

    it "says why when chi can't pair (no such session)" do
      _, err, status = run_pair("ffffffff", thread: thread_a)

      expect(status.exitstatus).to eq(1)
      expect(err).to include("ffffffff")
    end
  end

  it "pairs in one chi peer pair, the thread id as the address and its cwd as who paired" do
    odd = File.join(tmpdir, "odd\r\u0001dir").tap { |d| FileUtils.mkdir_p(d) }
    out, err, status = run_pair(id, thread: thread_a, chdir: odd)

    expect([status.exitstatus, err]).to eq([0, ""])
    expect(out).to eq("paired with chi #{id} (thread #{thread_a})\n")
    expect(fake.calls.map(&:last)).to eq([["peer", "pair", "codex", id, "--address", thread_a, "--from", "Codex in #{odd}"]])
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
    def run_remote(chi: fake.path, remote: nil, extra: {})
      run_pair(id, thread: thread_a, extra: { "CHI" => chi, "CHI_REMOTE" => remote }.merge(extra))
    end

    def says(remote, ask)
      "pair: chi is on #{remote}, so chi can't send to this Codex session (codex_send runs codex queue on chi's " \
        "machine): paired with chi #{id} for answers only. Answer chi with #{ask} peer say codex #{id}; chi's " \
        "replies reach you only when the user relays them (or asks you to run #{ask} send --wait #{id})\n"
    end

    it "with CHI_REMOTE set, pairs for answers only (no address) and says chi there can't send to this Codex" do
      out, err, status = run_remote(remote: " studio ")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to eq(says("studio", "CHI_REMOTE=studio #{fake.path}"))
      expect(fake.pairing("codex")).to eq(id: id, address: nil, from: "Codex in #{tmpdir} (on another machine)")
      expect(fake.calls.map(&:first)).to all(eq(" studio ")) # chi trims it itself
    end

    it "takes the remote a --remote NAME or --remote=NAME in CHI names over CHI_REMOTE, the last one" do
      out, err, status = run_remote(chi: "#{fake.path} --remote studio", remote: "other")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "#{fake.path} --remote studio"))

      out, err, status = run_remote(chi: "#{fake.path} --remote=laptop --remote=studio")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to start_with(says("studio", "#{fake.path} --remote=laptop --remote=studio"))
      expect(fake.pairing("codex")[:address]).to be_nil
    end

    it "pairs here, with the thread, with a blank CHI_REMOTE" do
      out, err, status = run_remote(remote: "  ")

      expect([status.exitstatus, err]).to eq([0, ""])
      expect(out).to eq("paired with chi #{id} (thread #{thread_a})\n")
      expect(fake.pairing("codex")).to include(address: thread_a)
    end

    it "says only chi's refusal when the pairing can't be made there" do
      out, err, status = run_remote(remote: "studio", extra: { "FAKE_CHI_FAIL" => "Error: no remote studio (chi remote ls)" })

      expect(status.exitstatus).to eq(1)
      expect(err).to eq("Error: no remote studio (chi remote ls)\n")
      expect(out).to eq("")
    end

    it "names the network_access line, not writable_roots, when chi can't reach the remote" do
      broke = "chi peer pair: studio (http://192.0.2.1:4567): the connection broke (EPERM)"

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

  it "names the mailbox's writable_roots line when Codex's sandbox keeps chi from writing its state" do
    blocked = "chi peer pair: Operation not permitted @ rb_sysopen - #{state_home}/samagotchi/mailbox/x"

    _, err, status = run_pair(id, thread: thread_a, extra: { "FAKE_CHI_FAIL" => blocked })

    expect(status.exitstatus).to eq(1)
    expect(err).to include("Operation not permitted",
                           "Codex's sandbox can't write chi's state: add to ~/.codex/config.toml",
                           "[sandbox_workspace_write]",
                           "writable_roots = [\"#{state_home}/samagotchi/mailbox\"]",
                           "then restart Codex")
  end
end
