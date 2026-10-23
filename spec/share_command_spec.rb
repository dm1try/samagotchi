# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/share_command"
require "samagotchi/participants"
require "samagotchi/web/running"
require_relative "support/remote_backend"

# chi share: invite a participant to review a session, list them, revoke
# them, on this machine and through chi --remote (RemoteBackend.both).
RSpec.describe Samagotchi::ShareCommand do
  let(:tmpdir) { Dir.mktmpdir("share") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions") }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state_dir)) }
  let(:session) { new_session }

  # No chi web of this machine's answers (a real one may run on the port).
  before { allow(Samagotchi::Web::InfoProbe).to receive(:call).and_return(:free) }

  after { FileUtils.rm_rf(tmpdir) }

  def new_session
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |session|
      session.save(state_dir: state_dir)
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))
    end
  end

  it "keeps Local's default port in step with chi web's" do
    require "samagotchi/web/server"
    expect(Samagotchi::SessionAccess::Local::WEB_PORT).to eq(Samagotchi::Web::Server::DEFAULT_PORT)
  end

  it "prints the usage for no arguments and --help" do
    expect(described_class.new([], stdout: out, stderr: err).run).to eq(0)
    expect(out.string).to start_with("Usage: chi share ID --name NAME")
  end

  RemoteBackend.both(self) do
    def run(*argv, tty: false)
      described_class.new(argv, stdout: out, stderr: err, state_dir: state_dir, access: backend_access(state_dir), tty: tty).run
    end

    describe "chi share ID --name NAME" do
      it "invites them: one line, the link once, how to end it; only a digest is kept" do
        expect(run(session.id[0, 8], "--name", "Alex", "--expires", "3d")).to eq(0), err.string

        grant = grants.list(session_id: session.id).first
        lines = out.string.lines.map(&:chomp)
        expires = Time.iso8601(grant.expires_at).localtime.strftime("%Y-%m-%d %H:%M")
        expect(lines[0]).to eq("#{grant.id}  Alex (human, reviewer) · session #{session.id[0, 8]} · expires #{expires} · cap $2.00")
        token = lines[1][/token=(chp_[^#]+)#/, 1]
        expect(grants.lookup(token)&.id).to eq(grant.id)
        expect(lines[1]).to end_with("#s=#{session.id}")
        expect(lines[2]).to eq("(shown once: chi keeps only its digest; chi share revoke #{session.id[0, 8]} #{grant.id} ends it)")
        expect(Time.iso8601(grant.expires_at) - Time.iso8601(grant.created_at)).to eq(3 * 86_400)
        expect(File.read(grants.path)).not_to include(token)
      end

      it "names the remote's LAN address in a remote's link" do
        skip "the local link is this machine's chi web's" unless backend == :remote

        run(session.id, "--name", "Alex")
        expect(out.string.lines[1]).to start_with("http://#{RemoteBackend::LAN_IP}:4567/?token=chp_")
        expect(out.string).not_to include("isn't on the LAN")
      end

      it "says when the link opens on that machine only (no LAN chi web)", local_only: "the probe is this machine's" do
        run(session.id, "--name", "Alex")
        expect(out.string.lines[1]).to start_with("http://127.0.0.1:4567/?token=chp_")
        expect(out.string).to include("chi web isn't on the LAN there (web.host: lan): this link opens on that machine only")
      end

      it "names the port the running chi web recorded, not web.port's", local_only: "the probe is this machine's" do
        Samagotchi::Web::Running.record(port: 4999, path: Samagotchi::Web::Running.path(state_dir: state_dir))
        allow(Samagotchi::Web::InfoProbe).to receive(:call).with("127.0.0.1", 4999, timeout: anything)
                                                           .and_return({ "app" => "chi-web", "lan" => "192.0.2.5" })

        run(session.id, "--name", "Alex")
        expect(out.string.lines[1]).to start_with("http://192.0.2.5:4999/?token=chp_")
        expect(out.string).not_to include("isn't on the LAN")
      end

      it "falls back to web.port when nothing answers on the recorded port", local_only: "the probe is this machine's" do
        Samagotchi::Web::Running.record(port: 4999, path: Samagotchi::Web::Running.path(state_dir: state_dir))
        allow(Samagotchi::Web::InfoProbe).to receive(:call).with("127.0.0.1", 4567, timeout: anything)
                                                           .and_return({ "app" => "chi-web", "lan" => "192.0.2.5" })

        run(session.id, "--name", "Alex")
        expect(out.string.lines[1]).to start_with("http://192.0.2.5:4567/?token=chp_")
      end

      it "takes --agent, and prints a QR code at a terminal" do
        expect(run(session.id, "--name", "Bot", "--agent", tty: true)).to eq(0), err.string
        expect(grants.list.first.kind).to eq("agent")
        expect(out.string.lines.size).to be > 10
      end

      it "refuses usage errors (exit 2) and an unknown session (exit 1)" do
        expect(run(session.id)).to eq(2)
        expect(run(session.id, "--name", "A", "--expires", "40d")).to eq(2)
        expect(run(session.id, "--name", "A", "--expires", "soon")).to eq(2)
        expect(run(session.id, "--name", " [ ] ")).to eq(2)
        expect(run("ffffffff", "--name", "A")).to eq(1)
        expect(err.string.lines.map(&:chomp)).to eq([
          "chi share: --name NAME: who the link is for (see chi share --help)",
          "chi share: --expires takes Nh or Nd, 1h to 30d (e.g. 3d) (see chi share --help)",
          "chi share: --expires takes Nh or Nd, 1h to 30d (e.g. 3d) (see chi share --help)",
          "chi share: a participant needs a name (see chi share --help)",
          "chi share: no session ffffffff"
        ])
        expect(grants.list).to eq([])
      end

      it "takes --cap in dollars, and refuses one out of range" do
        expect(run(session.id, "--name", "Alex", "--cap", "5.5")).to eq(0), err.string
        expect(grants.list.first.spend_cap).to eq(5.5)
        expect(out.string.lines[0]).to end_with("· cap $5.50\n")
        expect(run(session.id, "--name", "Kim", "--cap", "1001")).to eq(2)
        expect(run(session.id, "--name", "Kim", "--cap", "lots")).to eq(2)
        expect(err.string.lines.map(&:chomp).uniq).to eq(["chi share: #{described_class::CAP_USAGE} (see chi share --help)"])
        expect(grants.list.size).to eq(1)
      end

      it "refuses an archived session" do
        Samagotchi::ArchiveStore.archive(session.id, state_dir: state_dir)
        expect(run(session.id, "--name", "A")).to eq(2)
        expect(err.string).to include("is archived: unarchive it to invite anyone")
      end
    end

    describe "chi share ls" do
      it "lists one session's or every session's participants, never a token, as text or JSON" do
        a = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
        other = new_session
        Samagotchi::Participants.invite(grants, session_id: other.id, name: "Kim", kind: "agent", state_dir: state_dir)

        expect(run("ls")).to eq(0), err.string
        lines = out.string.lines.map(&:rstrip)
        expect(lines[0].split(/\s{2,}/))
          .to eq(["SESSION", "PARTICIPANT", "NAME", "KIND", "ROLE", "CREATED", "EXPIRES", "LAST USED", "CAP", "STATE"])
        expect(lines.size).to eq(3)
        expect(lines[1].split(/\s{2,}/).values_at(0, 1, 2, 3, 4, 7, 8, 9))
          .to eq([session.id[0, 8], a.grant.id, "Alex", "human", "reviewer", "-", "$2.00", "active"])
        expect(out.string).not_to include(a.token)

        out.truncate(0)
        out.rewind
        expect(run("ls", session.id[0, 8], "--format", "json")).to eq(0)
        rows = JSON.parse(out.string)
        expect(rows.map { |row| row["name"] }).to eq(["Alex"])
        expect(rows.first.keys).not_to include("digest", "token")
      end

      it "says when there are none" do
        expect(run("ls", session.id)).to eq(0)
        expect(out.string).to eq("no participants in #{session.id[0, 8]} (chi share #{session.id[0, 8]} --name NAME invites one)\n")
      end
    end

    describe "chi share cap" do
      it "sets an active participant's cap, from their next turn; refuses another session's or a bad one" do
        a = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
        expect(run("cap", session.id[0, 8], a.grant.id, "$10")).to eq(0), err.string
        expect(out.string).to eq("#{a.grant.id}  Alex  cap $10.00\n")
        expect(grants.find(a.grant.id).spend_cap).to eq(10.0)
        expect(Samagotchi::Participants.read(session.id, state_dir: state_dir).first.cap).to eq(10.0)

        other = new_session
        expect(run("cap", other.id, a.grant.id, "3")).to eq(2)
        expect(run("cap", session.id, a.grant.id, "1001")).to eq(2)
        expect(run("cap", session.id, "alex", "3")).to eq(2)
        expect(err.string.lines.map(&:chomp)).to eq([
          "chi share cap: #{Samagotchi::Participants.no_participant(a.grant.id, other.id)} (see chi share cap --help)",
          "chi share cap: #{described_class::CAP_USAGE} (see chi share cap --help)",
          "chi share cap: not a participant: alex (chi share ls lists them) (see chi share cap --help)"
        ])
        expect(grants.find(a.grant.id).spend_cap).to eq(10.0)
      end
    end

    describe "chi share revoke" do
      it "revokes one participant, a session's, or every one with --all" do
        a = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir)
        Samagotchi::Participants.invite(grants, session_id: session.id, name: "Sam", state_dir: state_dir)
        other = new_session
        Samagotchi::Participants.invite(grants, session_id: other.id, name: "Kim", state_dir: state_dir)

        expect(run("revoke", session.id, a.grant.id)).to eq(0), err.string
        expect(out.string).to eq("#{a.grant.id}  Alex  revoked\n")
        expect(run("revoke", session.id[0, 8])).to eq(0)
        expect(out.string.lines.last).to end_with("Sam  revoked\n")
        expect(run("revoke", "--all")).to eq(0)
        expect(out.string.lines.last).to end_with("Kim  revoked\n")
        expect(run("revoke", "--all")).to eq(0)
        expect(out.string.lines.last).to eq("nothing to revoke\n")
        expect(grants.list.map { |g| g.state(grants.now) }.uniq).to eq([:revoked])
      end

      it "refuses a bad participant id or mixed arguments (exit 2)" do
        expect(run("revoke")).to eq(2)
        expect(run("revoke", session.id, "alex")).to eq(2)
        expect(run("revoke", session.id, "--all")).to eq(2)
        expect(err.string).to include("chi share revoke: not a participant: alex (chi share ls lists them)")
      end
    end
  end

  describe "a participant's token through --remote" do
    it "is refused the owner's share routes in its one message (Dispatch prints it, exit 1)" do
      issued = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Bot", kind: "agent", state_dir: state_dir)
      access = RemoteBackend.access(state_dir: state_dir, token: issued.token)
      expect { described_class.new(["ls", session.id], stdout: out, stderr: err, access: access).run }
        .to raise_error(Samagotchi::SessionAccess::NotPermitted,
                        "#{RemoteBackend.entry.label}: this token is a participant's: only the session's owner can do that")
    end
  end
end
