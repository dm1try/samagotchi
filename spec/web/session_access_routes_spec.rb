# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/session_manager"
require "samagotchi/owner_lock"
require "samagotchi/archive_store"

# chi web's routes for chi's session commands run against another machine
# (Web::SessionAccessRoutes, the remote-sessions plan's P2): resolve, the
# CLI's list rows, a wait's prepare and the wait, notes, a context push, and
# the create, turn, answer, delete and context changes they need.
RSpec.describe Samagotchi::Web::App, "session access routes" do
  around do |example|
    Dir.mktmpdir("web-access") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    ensure
      @locks&.each(&:release)
    end
  end

  let(:state_dir) { File.join(@tmp, "state").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:folder) { File.join(@tmp, "proj").tap { |dir| FileUtils.mkdir_p(File.join(dir, ".git")) } }
  let(:app) do
    described_class.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0,
                        wait_poll_interval: 0.01)
  end

  before { allow(Process).to receive(:spawn).and_return(12_345) }

  def call(path, method: "GET", body: nil)
    env = Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: method,
                                          input: body.nil? ? nil : JSON.generate(body))
    status, _headers, chunks = app.call(env)
    [status, JSON.parse(chunks.to_a.join)]
  end

  def make(status: "idle", prompt: "hi", pending_question: nil, parent_answers: nil, model: "m", dir: folder)
    Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: dir).tap do |s|
      s.parent_answers = parent_answers
      s.status = status
      s.last_prompt = prompt
      s.pending_question = pending_question
      s.save(state_dir: state_dir)
      FileUtils.mkdir_p(dir_of(s))
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)

  def own(session, kind: "worker")
    (@locks ||= []) << Samagotchi::OwnerLock.acquire(dir_of(session), kind: kind)
  end

  def parent_answers_config(name)
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return(name)
  end

  describe "GET /api/sessions/resolve" do
    it "answers the full id of an id or a unique prefix" do
      session = make

      expect(call("/api/sessions/resolve?id=#{session.id}")).to eq([200, { "id" => session.id }])
      expect(call("/api/sessions/resolve?id=#{session.id[0, 6]}")).to eq([200, { "id" => session.id }])
    end

    it "answers 404 not_found for no such session or no id, and 400 ambiguous_id with the ids for a prefix of several" do
      a = make
      b = make
      b_id = "#{a.id[0, 4]}#{b.id[4..]}"
      File.rename(Samagotchi::Session.session_file(b.id, state_dir: state_dir),
                  Samagotchi::Session.session_file(b_id, state_dir: state_dir))

      expect(call("/api/sessions/resolve?id=feedbeef")).to eq([404, { "error" => "not_found", "detail" => "no session feedbeef" }])
      expect(call("/api/sessions/resolve").first).to eq(404)
      status, body = call("/api/sessions/resolve?id=#{a.id[0, 4]}")
      expect(status).to eq(400)
      expect(body).to include("error" => "ambiguous_id", "ids" => [a.id, b_id].sort)
      expect(body["message"]).to start_with("session id #{a.id[0, 4]} matches 2 sessions:")
      expect(body["detail"]).to eq(body["message"])
    end
  end

  describe "GET /api/sessions/summaries" do
    it "carries what chi sessions list prints: status, live, owner, recap, ctx_pct, waiting" do
      waiting = make(status: "running", pending_question: { id: "q1", question: "Which?" })
      own(waiting)
      File.write(File.join(dir_of(waiting), "recap.json"), JSON.generate(text: "Fixed the flaky spec. Then more."))
      idle = make(prompt: "later")

      status, rows = call("/api/sessions/summaries")

      expect(status).to eq(200)
      expect(rows.map { |r| r["id"] }).to contain_exactly(waiting.id, idle.id)
      row = rows.find { |r| r["id"] == waiting.id }
      expect(row).to include("status" => "running", "live" => true, "busy" => true, "owner" => "worker",
                             "recap" => "Fixed the flaky spec.", "waiting" => "question", "waiting_id" => "q1")
      expect(row).to have_key("ctx_pct")
      expect(rows.find { |r| r["id"] == idle.id }).to include("live" => false, "waiting" => nil, "preview" => "later")
    end

    it "filters as chi sessions list's flags: live, cwd, dir (a project), archived, tests, limit, sort" do
      live = make.tap do |s|
        s.created_at = "2020-01-01T00:00:00Z"
        s.save(state_dir: state_dir)
      end
      own(live)
      other_dir = File.join(@tmp, "other").tap { |d| FileUtils.mkdir_p(File.join(d, ".git")) }
      elsewhere = make(dir: other_dir)
      archived = make
      Samagotchi::ArchiveStore.archive(archived.id, state_dir: state_dir)
      test_run = make.tap do |s|
        s.test_run = true
        s.save(state_dir: state_dir)
      end
      ids = ->(query) { call("/api/sessions/summaries#{query}").last.map { |r| r["id"] } }

      expect(ids.call("?live=1")).to eq([live.id])
      expect(ids.call("?cwd=#{other_dir}")).to eq([elsewhere.id])
      expect(ids.call("?dir=#{other_dir}")).to eq([elsewhere.id])
      expect(ids.call("")).not_to include(archived.id)
      expect(ids.call("?archived=1")).to include(archived.id)
      expect(ids.call("")).to include(test_run.id)
      expect(ids.call("?tests=0")).not_to include(test_run.id)
      expect(ids.call("?limit=1").size).to eq(1)
      expect(ids.call("?sort=created_at&order=asc").first).to eq(live.id)
    end

    it "answers 400 for a cwd that isn't absolute and a dir that isn't a folder" do
      expect(call("/api/sessions/summaries?cwd=rel/path")).to match([400, include("error" => "invalid_cwd")])
      expect(call("/api/sessions/summaries?dir=/no/such/dir")).to match([400, include("error" => "invalid_dir")])
    end
  end

  describe "POST /api/sessions/:id/wait/prepare" do
    it "answers prepare_wait's WaitStart: cursor, baseline, own turn, running, live, settled" do
      session = make
      Samagotchi::SessionInbox.write_output(dir_of(session), "an older reply")
      reply = Dir.children(File.join(dir_of(session), "output")).first

      status, body = call("/api/sessions/#{session.id}/wait/prepare", method: "POST", body: {})

      expect(status).to eq(200)
      expect(body).to eq("session_id" => session.id, "cursor" => reply,
                         "baseline" => { "messages" => 0, "question_id" => nil, "last_turn" => nil },
                         "own_turn" => nil, "known_turn" => nil, "running" => false, "live" => false,
                         "settled" => false, "last_turn_id" => nil)
    end

    it "takes the question answered as the baseline's (or none), a --turn to check, and created for --new" do
      session = make(status: "running", pending_question: { id: "q1", question: "Which?" })
      path = "/api/sessions/#{session.id}/wait/prepare"

      expect(call(path, method: "POST", body: {}).last["baseline"]).to include("question_id" => "q1")
      expect(call(path, method: "POST", body: { question_id: "q9" }).last["baseline"]).to include("question_id" => "q9")
      expect(call(path, method: "POST", body: { question_id: nil }).last["baseline"]).to include("question_id" => nil)
      expect(call(path, method: "POST", body: { turn: "t-1" }).last).to include("known_turn" => false, "running" => true)
      expect(call(path, method: "POST", body: { created: true }).last)
        .to include("cursor" => nil, "baseline" => include("question_id" => nil), "running" => false)
    end

    it "with created: a first turn that already ended is not the baseline's (its end is the answer)" do
      session = make
      session.last_turn = Samagotchi::LastTurn.new(outcome: "failed", ended_at: Time.now.utc.iso8601)
      session.save(state_dir: state_dir)

      expect(call("/api/sessions/#{session.id}/wait/prepare", method: "POST", body: { created: true }).last["baseline"])
        .to eq("messages" => 0, "question_id" => nil, "last_turn" => nil)
    end

    it "with busy: refuses a running turn (409 busy) and a question it waits on (409 waiting), in chi send's words" do
      busy = make(status: "running")
      own(busy)
      waiting = make(status: "running", pending_question: { id: "q1", question: "Which?" })
      own(waiting)

      status, body = call("/api/sessions/#{busy.id}/wait/prepare", method: "POST", body: { busy: true })
      expect([status, body]).to eq([409, { "error" => "busy", "detail" => "busy: a turn is running; wait or attach",
                                           "message" => "busy: a turn is running; wait or attach", "session_id" => busy.id }])
      expect(call("/api/sessions/#{busy.id}/wait/prepare", method: "POST", body: { busy: true, queue: true }).first).to eq(200)

      status, body = call("/api/sessions/#{waiting.id}/wait/prepare", method: "POST", body: { busy: true, queue: true })
      expect(status).to eq(409)
      expect(body["error"]).to eq("waiting")
      expect(body["message"]).to start_with("waiting for an answer: chi answer #{waiting.id}")
      expect(body["message"]).to end_with("(or --text); chi --attach #{waiting.id} shows it")
    end

    it "answers 400 for a body that isn't an object or a turn that isn't a string, and 404 for no such session" do
      session = make
      env = Rack::MockRequest.env_for("/api/sessions/#{session.id}/wait/prepare", "HTTP_HOST" => "127.0.0.1",
                                                                                  method: "POST", input: "[1]")
      expect(app.call(env).first).to eq(400)
      expect(call("/api/sessions/#{session.id}/wait/prepare", method: "POST", body: { turn: 3 }).first).to eq(400)
      expect(call("/api/sessions/11111111-2222-3333-4444-555555555555/wait/prepare", method: "POST", body: {}).first).to eq(404)
    end
  end

  describe "POST /api/sessions/:id/wait" do
    def wait(session, body) = call("/api/sessions/#{session.id}/wait", method: "POST", body: body)

    it "answers the reply past the cursor as plain fields, with the parent strategy and never the session" do
      parent_answers_config("standard")
      session = make
      Samagotchi::SessionInbox.write_output(dir_of(session), "the answer")

      status, body = wait(session, { cursor: nil, timeout: 1 })

      expect(status).to eq(200)
      expect(body).to include("status" => "done", "text" => "the answer", "question" => nil,
                              "parent_strategy" => include("name" => "standard", "origin" => "config"))
      expect(body["file"]).to end_with(".txt")
      expect(body).not_to have_key("session")
    end

    it "answers a question that waits, as PendingQuestion's file fields, under the session's own stricter strategy" do
      parent_answers_config("soft")
      session = make(status: "running", pending_question: { id: "q2", question: "Delete it?", options: %w[Yes No] },
                     parent_answers: "hard")
      own(session)

      status, body = wait(session, { baseline: { messages: 0, question_id: nil, last_turn: nil }, timeout: 1 })

      expect(status).to eq(200)
      expect(body).to include("status" => "waiting_for_answer",
                              "question" => include("id" => "q2", "question" => "Delete it?", "options" => %w[Yes No]),
                              "parent_strategy" => include("name" => "hard", "origin" => "session"))
    end

    it "answers status timeout within its timeout (the client asks again), and caps it" do
      session = make(status: "running")
      own(session)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, body = wait(session, { cursor: nil, timeout: 0.2, owner_grace: 5 })

      expect([status, body["status"]]).to eq([200, "timeout"])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(described_class::WAIT_MAX_SECONDS).to eq(30.0)
    end

    it "answers 503 server_stopping when chi web stops mid-wait" do
      session = make(status: "running")
      own(session)
      app.server_running = -> { false }

      expect(wait(session, { timeout: 5 })).to match([503, include("error" => "server_stopping")])
    end

    it "answers 400 for a bad cursor, baseline or timeout, and 404 for no such session" do
      session = make
      expect(wait(session, { cursor: 7 }).first).to eq(400)
      expect(wait(session, { baseline: { messages: "x" } }).first).to eq(400)
      expect(wait(session, { baseline: { other: 1 } }).first).to eq(400)
      expect(wait(session, { timeout: -1 }).first).to eq(400)
      expect(call("/api/sessions/11111111-2222-3333-4444-555555555555/wait", method: "POST", body: {}).first).to eq(404)
    end
  end

  describe "POST /api/sessions/:id/notes" do
    def note(session, body) = call("/api/sessions/#{session.id}/notes", method: "POST", body: body)

    it "queues a note for a live worker, and says how many wait for a session without one" do
      live = make
      own(live)
      idle = make

      expect(note(live, { text: "fyi", source: "ci" })).to eq([200, { "status" => "queued", "session_id" => live.id, "queued" => 0 }])
      expect(note(idle, { text: "one" })).to eq([200, { "status" => "waits", "session_id" => idle.id, "queued" => 1 }])
      expect(note(idle, { text: "two" }).last).to include("queued" => 2)
      sources = Dir[File.join(dir_of(live), "notes", "*")].map { |f| File.read(f) }
      expect(sources.join).to include("ci")
    end

    it "refuses a chi REPL's session (409 owned_by_tui), an empty note, no text and the broadcast source" do
      repl = make
      own(repl, kind: "tui")
      idle = make

      status, body = note(repl, { text: "fyi" })
      expect(status).to eq(409)
      expect(body).to include("error" => "owned_by_tui", "status" => "refused", "session_id" => repl.id,
                              "message" => "session #{repl.id} is open in a chi REPL; close it there first")
      expect(note(idle, { text: "  " })).to match([400, include("error" => "note_rejected")])
      expect(note(idle, {})).to match([400, include("error" => "missing_fields")])
      expect(note(idle, { text: "x", source: "broadcast" }))
        .to eq([400, { "error" => "invalid_source", "detail" => "source broadcast is chi broadcast's own" }])
    end
  end

  describe "context: push and cmd sources, a push, rm of the session's own" do
    let(:session) { make }
    let(:path) { "/api/sessions/#{session.id}/context" }
    let(:location) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }

    it "attaches a --push source and a --cmd one, as chi context add (added_by from the body)" do
      expect(call(path, method: "POST", body: { name: "notes", push: true, why: "the notes", hint: "x", added_by: "cli" }))
        .to eq([201, { "status" => "attached", "name" => "notes" }])
      expect(call(path, method: "POST", body: { name: "ci", cmd: "echo hi", every: 60, added_by: "agent" }).first).to eq(201)

      expect(location.source("notes")).to have_attributes(cmd: nil, why: "the notes", hint: "x", added_by: "cli", scope: "session")
      expect(location.source("ci")).to have_attributes(cmd: "echo hi", every_seconds: 60, added_by: "agent")
    end

    it "refuses a bad body, a bad name, every on a push source, too short an every, an empty cmd and a name taken" do
      expect(call(path, method: "POST", body: { name: "x", push: true, cmd: "ls" }).first).to eq(400)
      expect(call(path, method: "POST", body: { name: "x" }).first).to eq(400)
      expect(call(path, method: "POST", body: { name: "Bad Name", push: true })).to match([400, include("error" => "invalid_source")])
      expect(call(path, method: "POST", body: { name: "x", push: true, every: 60 })).to match([400, include("error" => "invalid_source")])
      expect(call(path, method: "POST", body: { name: "x", cmd: "ls", every: 5 })).to match([400, include("error" => "invalid_source")])
      expect(call(path, method: "POST", body: { name: "x", cmd: " " })).to match([400, include("error" => "invalid_source")])
      expect(call(path, method: "POST", body: { name: "x", push: true }).first).to eq(201)
      expect(call(path, method: "POST", body: { name: "x", push: true })).to match([409, include("error" => "exists")])
    end

    it "pushes new text into a --push source; 404 for none, 409 not_push for a command source, 400 for no text" do
      call(path, method: "POST", body: { name: "notes", push: true })
      call(path, method: "POST", body: { name: "ci", cmd: "echo hi" })

      status, body = call("#{path}/notes/push", method: "POST", body: { text: "hello", summary: "1 new", wake: true })
      expect(status).to eq(200)
      expect(body).to include("status" => "pushed", "name" => "notes", "before" => nil, "changed" => true)
      expect(location.snapshot("notes")).to have_attributes(text: "hello", summary: "1 new")
      expect(call("#{path}/notes/push", method: "POST", body: { text: "hello" }).last).to include("changed" => false)

      expect(call("#{path}/nope/push", method: "POST", body: { text: "x" })).to match([404, include("error" => "not_found")])
      expect(call("#{path}/ci/push", method: "POST", body: { text: "x" }))
        .to eq([409, { "error" => "not_push", "detail" => "ci runs a command, which writes its text: push goes to a --push source" }])
      expect(call("#{path}/notes/push", method: "POST", body: { text: " " })).to match([400, include("error" => "invalid_text")])
      expect(call("#{path}/notes/push", method: "POST", body: {})).to match([400, include("error" => "missing_fields")])
    end

    it "with own=1 detaches only the session's own source: a project's is 409 project_source, none 404" do
      call(path, method: "POST", body: { name: "mine", push: true })
      project = Samagotchi::ContextSources.project_location_for(session.project_root, state_dir: state_dir)
      project.add(Samagotchi::ContextSources::Source.new(name: "ours", cmd: nil, every_seconds: nil, why: nil, hint: nil,
                                                         scope: project.scope, added_by: "cli", created_at: nil))

      expect(call("#{path}/mine?own=1", method: "DELETE")).to eq([200, { "status" => "detached", "name" => "mine" }])
      expect(call("#{path}/ours?own=1", method: "DELETE"))
        .to eq([409, { "error" => "project_source",
                       "detail" => "ours is the project's: chi context rm ours --project, or mute it for this session" }])
      expect(call("#{path}/gone?own=1", method: "DELETE").first).to eq(404)
      expect(project.source("ours")).not_to be_nil
    end
  end

  describe "the refusals' fields: a remote client raises the same exception" do
    it "names an archive's reason and the delegate that holds it" do
      session = make(status: "running")
      own(session)

      expect(call("/api/sessions/#{session.id}/archive", method: "POST", body: {}))
        .to eq([409, { "error" => "busy", "detail" => "a turn is running; wait for it or cancel it first",
                       "message" => "a turn is running; wait for it or cancel it first", "session_id" => session.id,
                       "reason" => "busy", "busy_id" => session.id }])
    end

    it "gives a chi REPL's session its OwnedByTUI message and id, and a restart refusal its reason" do
      session = make
      own(session, kind: "tui")

      expect(call("/api/sessions/#{session.id}/stop", method: "POST", body: {}))
        .to eq([409, { "error" => "owned_by_tui", "detail" => "session #{session.id} is open in a chi REPL; close it there first",
                       "message" => "session #{session.id} is open in a chi REPL; close it there first",
                       "session_id" => session.id }])
      idle = make
      status, body = call("/api/sessions/#{idle.id}/restart", method: "POST", body: {})
      expect(status).to eq(409)
      expect(body).to include("error" => "not_running", "reason" => "not_running", "session_id" => idle.id)
      expect(body["message"]).to eq(body["detail"])
    end

    it "lists an ambiguous continue's sessions" do
      a = make
      b = make
      File.rename(Samagotchi::Session.session_file(b.id, state_dir: state_dir),
                  Samagotchi::Session.session_file("#{a.id[0, 4]}#{b.id[4..]}", state_dir: state_dir))

      status, body = call("/api/sessions", method: "POST", body: { continues: a.id[0, 4], idle: true })

      expect(status).to eq(400)
      expect(body).to include("error" => "ambiguous_id", "ids" => [a.id, "#{a.id[0, 4]}#{b.id[4..]}"].sort)
    end
  end
end
