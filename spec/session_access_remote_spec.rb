# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/send_command"
require "samagotchi/sessions_command"
require "samagotchi/owner_lock"
require_relative "support/remote_backend"
require "samagotchi/participants"

# SessionAccess::Remote's own side, against chi web's Rack app in this
# process: the server check, the errors it raises, the wait it repeats, and
# what chi send --new sends (the same session as on this machine). The
# commands' behaviour on both backends is in their own specs
# (RemoteBackend.both).
RSpec.describe Samagotchi::SessionAccess::Remote do
  let(:tmpdir) { Dir.mktmpdir("remote-access") }
  let(:locks) { [] }
  let(:app) { RemoteBackend.app(state_dir: tmpdir) }
  let(:transport) { RemoteBackend::RackTransport.new(app) }
  let(:remote) { described_class.new(RemoteBackend.entry, transport: transport, sleeper: ->(_s) {}) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  before { allow(Process).to receive(:spawn).and_return(12_345) }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(owner: nil, status: "idle", id: nil, scratch: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir, scratch: scratch).tap do |s|
      s.id = id if id
      s.status = status
      s.last_prompt = "hi"
      s.save(state_dir: tmpdir)
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(s.id, state_dir: tmpdir), kind: owner) if owner
    end
  end

  # A transport that answers +replies+ in turn (the last one repeats) after
  # a chi web's GET /api/info.
  def scripted(*replies, info: { app: "chi-web", version: "9.9.9", features: ["session_commands"] }, clock: nil, on_call: nil)
    calls = []
    fake = lambda do |method, path, **opts|
      calls << [method, path, opts]
      on_call&.call(path)
      next Samagotchi::SessionAccess::HTTPTransport::Reply.of(200, JSON.generate(info)) if path == "/api/info"

      status, body = replies.size > 1 ? replies.shift : replies.first
      Samagotchi::SessionAccess::HTTPTransport::Reply.of(status, JSON.generate(body))
    end
    clock = clock ? { clock: clock } : {}
    [described_class.new(RemoteBackend.entry, transport: fake, sleeper: ->(_s) {}, **clock), calls]
  end

  describe "the server" do
    it "is asked once, before the first request, whether it has the session commands' routes" do
      session = make
      remote.show(session.id)
      remote.show(session.id)

      expect(transport.requests.map(&:last).count("/api/info")).to eq(1)
      expect(transport.requests.first).to eq([:get, "/api/info"])
    end

    it "names its chi and says to update it when it lacks them, or answers 404 for a route" do
      old, = scripted([200, {}], info: { app: "chi-web", version: "0.102.0", features: %w[dir] })
      expect { old.resolve_id("ab12") }
        .to raise_error(Samagotchi::SessionAccess::RemoteTooOld, "remote studio runs chi 0.102.0, too old for this command through --remote: update chi there (chi update)")

      missing, = scripted([404, { error: "not_found", detail: "not found: /api/sessions/resolve" }])
      expect { missing.resolve_id("ab12") }.to raise_error(Samagotchi::SessionAccess::RemoteTooOld, /runs chi 9.9.9/)
    end

    it "says the token was refused, and that a hostname isn't answered, naming the remote" do
      refused = described_class.new(RemoteBackend.entry(token: "wrong"),
                                    transport: RemoteBackend::RackTransport.new(app, token: "wrong"))
      expect { refused.resolve_id("ab12") }
        .to raise_error(Samagotchi::SessionAccess::RemoteFailed, %r{\Aremote studio \(http://192.0.2.10:4567\): the token was refused})

      forbidden, = scripted([403, { error: "forbidden", detail: "only the host names 127.0.0.1, [::1], localhost and 192.0.2.10 are answered" }])
      expect { forbidden.resolve_id("ab12") }.to raise_error(Samagotchi::SessionAccess::RemoteFailed, /use the LAN IP 192.0.2.10, not a hostname/)
    end

    it "has the feature chi web names (Web::SessionAccessRoutes::FEATURE)" do
      expect(described_class::FEATURE).to eq(Samagotchi::Web::SessionAccessRoutes::FEATURE)
    end
  end

  describe "the errors a refusal raises, as on this machine" do
    it "resolves a prefix on the server: an unknown one comes back as given, several raise AmbiguousId with the ids" do
      a = make(id: "abcd1111-0000-0000-0000-000000000000")
      b = make(id: "abcd2222-0000-0000-0000-000000000000")

      expect(remote.resolve_id("abcd1")).to eq(a.id)
      expect(remote.resolve_id("ffff")).to eq("ffff")
      expect { remote.resolve("ffff") }.to raise_error(ArgumentError)
      expect { remote.resolve("abcd") }.to raise_error(Samagotchi::Session::AmbiguousId) { |e| expect(e.ids).to eq([a.id, b.id]) }
    end

    it "raises OwnedByTUI, DeleteRefused, ArchiveRefused and RestartRefused with their own words" do
      repl = make(owner: "tui")
      live = make(owner: "worker")
      scratch = make(scratch: true)

      expect { remote.stop(repl.id, wait: 1) }.to raise_error(Samagotchi::SessionManager::OwnedByTUI, Samagotchi::SessionManager::OwnedByTUI.new(repl.id).message)
      expect { remote.delete(live.id, force: false) }
        .to raise_error(Samagotchi::SessionManager::DeleteRefused) { |e| expect([e.session_id, e.reason]).to eq([live.id, :worker_running]) }
      expect { remote.archive(scratch.id) }
        .to raise_error(Samagotchi::SessionManager::ArchiveRefused, "a scratch session is deleted when you leave; nothing to archive")
      expect { remote.restart(make.id) }.to raise_error(Samagotchi::SessionManager::RestartRefused) { |e| expect(e.reason).to eq(:not_running) }
    end

    it "asks chi web to stop with the CLI's wait, which it caps at SessionManager::STOP_WAIT" do
      session = make
      allow(Samagotchi::SessionManager).to receive(:stop_session).and_return(true)

      expect(remote.stop(session.id, wait: Samagotchi::SessionManager::STOP_WAIT)).to be(true)
      expect(Samagotchi::SessionManager).to have_received(:stop_session)
        .with(session.id, state_dir: anything, wait: Samagotchi::SessionManager::STOP_WAIT)
    end

    it "shows a session as the commands read it: the file's status, folder, owner and pending question" do
      session = make(owner: "worker", status: "running")
      session.pending_question = Samagotchi::PendingQuestion.new(id: "q1", question: "Go?", options: %w[Yes No])
      session.save(state_dir: tmpdir)

      view = remote.show(session.id)
      expect(view).to have_attributes(id: session.id, status: "running", working_directory: tmpdir, model_name: "m")
      expect(view.owner).to be_worker
      expect(view.pending_question).to have_attributes(id: "q1", options: %w[Yes No])
    end
  end

  describe "a participant's token (one message per condition)" do
    let(:state) { File.join(tmpdir, "samagotchi", "sessions") }
    let(:grants) { Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: state)) }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap do |s|
        s.save(state_dir: state)
        FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state))
      end
    end
    let(:issued) { Samagotchi::Participants.invite(grants, session_id: session.id, name: "Agent", kind: "agent", state_dir: state) }

    def as_participant(token = issued.token)
      described_class.new(RemoteBackend.entry(token: token),
                          transport: RemoteBackend::RackTransport.new(RemoteBackend.app(state_dir: state), token: token),
                          sleeper: ->(_s) {})
    end

    it "passes the server check (the trimmed /api/info) and reads its session's brief view" do
      expect(as_participant.show(session.id)).to have_attributes(id: session.id, status: session.status)
    end

    it "raises NotPermitted on an owner's route, TokenRevoked once revoked, TokenExpired after its expiry" do
      label = RemoteBackend.entry.label
      expect { as_participant.summaries }
        .to raise_error(Samagotchi::SessionAccess::NotPermitted,
                        "#{label}: #{Samagotchi::ParticipantMessages::NOT_PERMITTED}")
      expect { as_participant.participants(session.id) }.to raise_error(Samagotchi::SessionAccess::NotPermitted)

      token = issued.token
      Samagotchi::Participants.revoke(grants, session_id: session.id, state_dir: state)
      expect { as_participant(token).show(session.id) }
        .to raise_error(Samagotchi::SessionAccess::TokenRevoked, "#{label}: this review link was revoked by the session's owner")
    end

    # The participant routes chi send --wait reaches (resolve, wait/prepare
    # and wait on a turn of theirs): --turn T, or the turn -m just queued.
    it "waits on their own turn with chi send --wait --turn: a turn waiting on the owner exits 3, wait again" do
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: state)
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "q", client_id: "review:#{issued.grant.id}",
                                                        author: issued.grant.author, enqueued_id: "e-1", delivery: "queue")
      app = RemoteBackend.app(state_dir: state)
      allow(app.send(:session_access)).to receive(:wait_reply)
        .and_return(Samagotchi::ReplyWait::Result.new(status: :waiting_for_answer, question: { "id" => "c1", "kind" => "continue" }))
      access = described_class.new(RemoteBackend.entry(token: issued.token),
                                   transport: RemoteBackend::RackTransport.new(app, token: issued.token), sleeper: ->(_s) {})
      wait_again = "chi --remote studio send --wait --turn e-1 #{session.id}"

      code = Samagotchi::SendCommand.new(["--wait", "--turn", "e-1", session.id[0, 8]], stdout: out, stderr: err,
                                                                                    state_dir: state, access: access).run
      expect([code, err.string]).to eq([3, "chi send: waiting for the session's owner: #{wait_again}\n"])
      json = StringIO.new
      Samagotchi::SendCommand.new(["--wait", "--format", "json", "--turn", "e-1", session.id], stdout: json, stderr: err,
                                                                                            state_dir: state, access: access).run
      expect(JSON.parse(json.string)).to eq("status" => "waiting_for_owner", "session_id" => session.id, "turn_id" => "e-1",
                                            "detail" => "waiting for the session's owner: #{wait_again}")
    end

    it "sends a review turn with chi send -m and names its id and the wait for it" do
      access = as_participant
      code = Samagotchi::SendCommand.new(["-m", "is step 3 right?", session.id[0, 8]], stdout: out, stderr: err,
                                                                                      state_dir: state, access: access).run

      expect(code).to eq(0), err.string
      turn = out.string[/review turn (\S+);/, 1]
      expect(turn).not_to be_nil
      expect(out.string).to eq("#{session.id[0, 8]}  sent (queued as review turn #{turn}; " \
                               "chi --remote studio send --wait --turn #{turn} #{session.id} waits for its reply)\n")
    end

    it "waits on the review turn chi send --wait -m queued, a running session too (no owner's busy check)" do
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.save(state_dir: state)
      app = RemoteBackend.app(state_dir: state)
      allow(app.send(:session_access)).to receive(:wait_reply).and_return(Samagotchi::ReplyWait::Result.new(status: :done, text: "yes"))
      access = described_class.new(RemoteBackend.entry(token: issued.token),
                                   transport: RemoteBackend::RackTransport.new(app, token: issued.token), sleeper: ->(_s) {})

      code = Samagotchi::SendCommand.new(["--wait", "-m", "is step 3 right?", session.id], stdout: out, stderr: err,
                                                                                          state_dir: state, access: access).run

      expect([code, out.string]).to eq([0, "yes\n"]), err.string
      turn = err.string[/queued as review turn (\S+)\)/, 1]
      expect(turn).not_to be_nil
      expect(app.send(:session_access)).to have_received(:wait_reply).with(session.id, hash_including(turn: turn, queued: true))
    end

    it "words each code once, whatever the route, in the server's own words (ParticipantMessages)" do
      label = RemoteBackend.entry.label
      messages = Samagotchi::ParticipantMessages
      {
        [401, "token_expired"] => [Samagotchi::SessionAccess::TokenExpired, messages::TOKEN_EXPIRED],
        [401, "token_revoked"] => [Samagotchi::SessionAccess::TokenRevoked, messages::TOKEN_REVOKED],
        [403, "not_permitted"] => [Samagotchi::SessionAccess::NotPermitted, messages::NOT_PERMITTED],
        [429, "too_many_turns"] => [Samagotchi::SessionAccess::TooManyTurns, messages::TOO_MANY_TURNS],
        [429, "cap_reached"] => [Samagotchi::SessionAccess::CapReached, messages::CAP_REACHED],
        [401, "unauthorized"] => [Samagotchi::SessionAccess::AuthRefused, "the token was refused"]
      }.each do |(status, code), (klass, words)|
        remote, = scripted([status, { error: code, detail: "server words" }])
        expect { remote.summaries }.to raise_error(klass) { |e| expect(e.message).to start_with("#{label}: #{words}") }
      end
      expect(Samagotchi::SessionAccess::TokenExpired.ancestors).to include(Samagotchi::SessionAccess::AuthRefused)
      expect(Samagotchi::Web::ParticipantAccess::ENDED)
        .to eq(revoked: ["token_revoked", messages::TOKEN_REVOKED], expired: ["token_expired", messages::TOKEN_EXPIRED])
    end
  end

  describe "a wait" do
    let(:baseline) { Samagotchi::ReplyWait::Baseline.new(messages: 0) }

    it "asks again after each slice that timed out, and after chi web stopped mid-wait, until the answer" do
      access, calls = scripted([200, { status: "timeout" }], [503, { error: "server_stopping" }],
                               [200, { status: "done", text: "hi", parent_strategy: { name: "standard", allowed: ["read"], origin: "session" } }])

      result = access.wait_reply("s1", cursor: nil, timeout: nil, baseline: baseline)

      expect(result).to have_attributes(status: :done, text: "hi")
      expect(calls.count { |_m, path, _o| path == "/api/sessions/s1/wait" }).to eq(3)
      expect(calls.last[2][:body]).to include(timeout: described_class::WAIT_SLICE)
      expect(access.parent_strategy("s1")).to have_attributes(name: "standard", allowed: ["read"], origin: :session)
    end

    it "asks for no more than the time left of its own --timeout, and times out itself" do
      # Each slice takes 30 s of a clock the spec moves: a 45 s --timeout is
      # asked as 30 s, then the 15 s left, then it times out without asking.
      now = 1000.0
      access, calls = scripted([200, { status: "timeout" }], clock: -> { now },
                                                             on_call: ->(path) { now += 30 if path.end_with?("/wait") })

      expect(access.wait_reply("s1", cursor: nil, timeout: 45, baseline: baseline).status).to eq(:timeout)
      expect(calls.drop(1).map { |_m, _p, o| o[:body][:timeout] }).to eq([30.0, 15.0])
    end

    it "holds a parent to the strictest strategy before any wait said the server's" do
      expect(remote.parent_strategy("s1").name).to eq("hard")
    end
  end

  describe "chi send through a Remote" do
    let(:folder) { File.join(tmpdir, "proj").tap { |dir| FileUtils.mkdir_p(dir) } }
    let(:spawned) { [] }

    before do
      allow(Samagotchi::SessionManager).to receive(:spawn_session) do |**kwargs|
        spawned << kwargs
        Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: folder).tap { |s| s.save(state_dir: tmpdir) }
      end
      allow(Samagotchi::SessionConfig).to receive(:availability)
        .and_return(Samagotchi::SessionConfig::Availability.new(offered: { "cost-cap" => ["cap"] }, notes: {}))
    end

    def send_command(*argv, access: remote)
      Samagotchi::SendCommand.new(argv, stdout: out, stderr: err, state_dir: tmpdir, access: access).run
    end

    it "--new starts the same session as on this machine: its folder, model and setup flags as typed" do
      flags = ["--new", "--dir", folder, "--model", "m2", "--toolkit", "lean", "--tool", "delegate", "--no-tool", "web_fetch",
               "--thinking", "high", "--llm-context", "stale,forget", "--llm-context-budget", "64k",
               "--set", "recap.enabled=off", "--set", "cost-cap.cap=3", "--parent-answers", "hard", "-m", "hi"]
      expect(send_command(*flags, access: nil)).to eq(0), err.string
      expect(send_command(*flags)).to eq(0), err.string

      here, there = spawned
      expect(there[:setup]).to eq(here[:setup])
      expect(there.slice(:prompt, :working_directory, :model_name)).to eq(here.slice(:prompt, :working_directory, :model_name))
    end

    it "--new needs --dir as an absolute path there, and a bad flag value is the server's usage error (exit 2)" do
      expect(send_command("--new", "-m", "hi")).to eq(2)
      # One line, not the whole usage after it.
      expect(err.string).to eq("chi send: --new on studio needs --dir: a folder there (see chi send --help)\n")
      err.truncate(0)
      err.rewind
      expect(send_command("--new", "--dir", "proj", "-m", "hi")).to eq(2)
      expect(err.string).to eq("chi send: --dir is a folder on studio: give its absolute path (see chi send --help)\n")
      expect(send_command("--new", "--dir", File.join(tmpdir, "gone"), "-m", "hi")).to eq(2)
      expect(err.string).to include("not a folder: #{File.join(tmpdir, "gone")}")
      expect(send_command("--new", "--dir", folder, "--set", "nope.x=1", "-m", "hi")).to eq(2)
      expect(err.string).to include("no installed bundle nope")
      expect(spawned).to be_empty
    end

    it "refuses a --model whose host isn't configured there as it does here: one line, exit 1" do
      unknown = "unknown host 'gone' in model 'gone:org/model'; the configured hosts are main"
      allow(Samagotchi::SessionManager).to receive(:spawn_session).and_raise(Samagotchi::ModelProfile::UnknownHost, unknown)

      lines = [nil, remote].map do |access|
        err.truncate(0)
        err.rewind
        [send_command("--new", "--dir", folder, "--model", "gone:org/model", "-m", "hi", access: access), err.string]
      end
      expect(lines).to eq([[1, "chi send: could not start a session: #{unknown}\n"]] * 2)
    end

    it "warns of a --parent-answers looser than the server's config.yml, in its words" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("standard")

      expect(send_command("--new", "--dir", folder, "--parent-answers", "soft", "-m", "hi")).to eq(0), err.string
      expect(err.string).to include("chi send: warning: --parent-answers soft is looser than config.yml's guardrails.parent_answers: standard")
    end

    it "is refused per target when a target's turn route refuses a loosening /parent-answers; the others take it" do
      a = make
      b = make
      b.parent_answers = "standard"
      b.save(state_dir: tmpdir)
      allow(Samagotchi::SessionManager).to receive(:resume_session)

      expect(send_command("-m", "/parent-answers soft", a.id, b.id)).to eq(1)
      expect(out.string.lines).to eq(["#{a.id[0, 8]}  sent (started its worker)\n",
                                      "#{b.id[0, 8]}  refused: #{Samagotchi::ParentAnswersCommand::REFUSED}\n"])
    end

    it "names the remote when it can't be reached, in the line and the JSON" do
      down = described_class.new(RemoteBackend.entry, transport: lambda { |*_a, **_o|
        raise Samagotchi::SessionAccess::RemoteFailed, "remote studio (http://192.0.2.10:4567): connection refused"
      })

      expect(send_command("--wait", "--format", "json", "-m", "x", "abcd", access: down)).to eq(1)
      expect(JSON.parse(out.string)).to include("status" => "error", "detail" => "remote studio (http://192.0.2.10:4567): connection refused")
    end
  end

  describe "chi sessions list through a Remote" do
    def list(*argv)
      Samagotchi::SessionsCommand.new(["list", *argv], stdout: out, stderr: err, access: remote).run
    end

    it "lists every project's sessions by default, and --scope=project only with --cwd, a folder there" do
      make

      expect(with_env("CI" => nil, "SAMAGOTCHI_ENV" => "test") { list("--format", "tsv") }).to eq(0), err.string
      expect(out.string.lines.size).to eq(1)
      expect(list("--scope=project")).to eq(2)
      expect(err.string).to include("--scope=project on a remote needs --cwd: a folder there")
    end
  end
end
