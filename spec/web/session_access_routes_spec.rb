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
require "samagotchi/worker_sidecar"
require "socket"
require_relative "../support/worker_links"

# chi web's routes for chi's session commands run against another machine
# (Web::SessionAccessRoutes, the remote-sessions plan's P2): resolve, the
# CLI's list rows, a wait's prepare and the wait, notes, a context push, and
# the create, turn, answer, delete and context changes they need.
RSpec.describe Samagotchi::Web::App, "session access routes" do
  include WorkerLinks

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
      expect([status, body]).to eq([409, { "error" => "busy", "detail" => "busy: a turn is running; --queue runs the message after it, chi send --wait #{busy.id} waits for it, chi --attach #{busy.id} shows it",
                                           "message" => "busy: a turn is running; --queue runs the message after it, chi send --wait #{busy.id} waits for it, chi --attach #{busy.id} shows it", "session_id" => busy.id }])
      expect(call("/api/sessions/#{busy.id}/wait/prepare", method: "POST", body: { busy: true, queue: true }).first).to eq(200)

      status, body = call("/api/sessions/#{waiting.id}/wait/prepare", method: "POST", body: { busy: true, queue: true })
      expect(status).to eq(409)
      expect(body["error"]).to eq("waiting")
      expect(body["message"]).to start_with("waiting for an answer: chi answer #{waiting.id}")
      expect(body["message"]).to end_with("(or --text); chi --attach #{waiting.id} shows it")
      # Its fields, which a chi --remote client words with its own commands.
      expect(body).to include("session_id" => waiting.id, "question" => include("id" => "q1", "question" => "Which?"),
                              "parent_strategy" => include("name", "allowed", "origin"))
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
      expect(body["running_look"]).to be_nil # no checkpoint mark: no turn to settle

      # One with its mark: the next slice gets it back (SessionAccess::Remote#wait_reply).
      marked = Samagotchi::Session.load(session.id, state_dir: state_dir)
      marked.interrupted_turn = Samagotchi::InterruptedTurn.new(started_at: Time.now.iso8601(3), iteration: 1)
      marked.save(state_dir: state_dir)
      look = { "last_end" => nil, "claimed" => [] }
      expect(wait(session, { cursor: nil, timeout: 0.2 }).last).to include("status" => "timeout", "running_look" => look)
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
      expect(wait(session, { running_look: { last_end: nil, claimed: ["../x"] } }).first).to eq(400)
      expect(wait(session, { running_look: "x" }).first).to eq(400)
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

  describe "POST /api/sessions: toolkit, tools, no_tools, parent_answers and chi send's refusals" do
    def create(body) = call("/api/sessions", method: "POST", body: body)

    it "saves the toolkit and parent_answers in the new session, and warns of a looser one than config.yml's" do
      parent_answers_config("standard")

      status, body = create(prompt: "hi", dir: folder, toolkit: "lean", tools: ["delegate"], no_tools: ["execute"],
                            parent_answers: "soft")

      expect(status).to eq(201), body.inspect
      saved = Samagotchi::Session.load(body["id"], state_dir: state_dir)
      expect(saved.toolkit).to eq(Samagotchi::Toolkit.new(name: "lean", add: ["delegate"], remove: ["execute"]))
      expect(saved.parent_answers).to eq("soft")
      expect(body).to include("parent_answers_warning" => "soft is looser than config.yml's guardrails.parent_answers: standard; " \
                                                          "standard applies", "model_warning" => nil)
    end

    it "refuses a bad toolkit or parent_answers, and either beside continues" do
      previous = make
      expect(create(prompt: "hi", toolkit: 3)).to match([400, include("error" => "invalid_toolkit")])
      expect(create(prompt: "hi", tools: "x")).to match([400, include("error" => "invalid_toolkit")])
      expect(create(prompt: "hi", parent_answers: "loose")).to match([400, include("error" => "invalid_parent_answers")])
      expect(create(continues: previous.id, idle: true, toolkit: "lean", parent_answers: "hard").last["detail"])
        .to end_with("leave out toolkit, parent_answers")
      expect(Process).not_to have_received(:spawn)
    end

    it "refuses chi send's loosening /parent-answers and a parent's /continue yes under hard, before anything spawns" do
      parent_answers_config("hard")

      expect(create(idle: true, preview: "/parent-answers soft", parent_answers: "standard", client_id: "cli:send"))
        .to match([403, include("error" => "parent_answers_refused", "detail" => Samagotchi::ParentAnswersCommand::REFUSED)])
      expect(create(idle: true, preview: "/continue yes", client_id: "cli:answer"))
        .to match([403, include("error" => "parent_continue_refused",
                                "detail" => include("a parent agent may only stop this turn here"))])
      previous = make(parent_answers: "hard")
      expect(create(continues: previous.id, idle: true, preview: "/parent-answers soft", client_id: "cli:send").first).to eq(403)
      expect(Process).not_to have_received(:spawn)
      # The page's lines aren't checked here (the worker checks every line).
      expect(create(idle: true, preview: "/parent-answers soft", dir: folder).first).to eq(201)
    end

    it "with check_vision refuses a model known not to take images (422 no_vision), the continued link's too" do
      blind = Samagotchi::VisionSupport::Answer.new(value: false, reason: "models.blind sets vision: false")
      allow(Samagotchi::SendCommand).to receive(:vision_answer).and_return(Samagotchi::SendCommand::UNKNOWN_VISION)
      allow(Samagotchi::SendCommand).to receive(:vision_answer).with("blind", typed: nil).and_return(blind)

      expect(create(idle: true, preview: "look", model: "blind", check_vision: true))
        .to eq([422, { "error" => "no_vision",
                       "detail" => "blind can't take images (models.blind sets vision: false); " \
                                   "send text only or switch the model (/model)" }])
      expect(create(continues: make(model: "blind").id, idle: true, check_vision: true).first).to eq(422)
      expect(create(idle: true, preview: "look", model: "blind", dir: folder).first).to eq(201)
    end
  end

  describe "POST /api/sessions/:id/turn: chi send's refusals" do
    def turn(session, body) = call("/api/sessions/#{session.id}/turn", method: "POST", body: body)

    it "refuses chi send's loosening /parent-answers and a parent's /continue yes the session's own level refuses" do
      parent_answers_config("soft")
      session = make(parent_answers: "hard")

      expect(turn(session, { prompt: "/parent-answers soft", client_id: "cli:send" }))
        .to match([403, include("error" => "parent_answers_refused")])
      expect(turn(session, { prompt: "/continue yes", client_id: "cli:answer" }))
        .to match([403, include("error" => "parent_continue_refused", "detail" => include("parent_answers: hard (this session)"))])
      expect(Dir[File.join(dir_of(session), "input", "*")]).to be_empty
    end

    it "with check_vision refuses images to a model known not to take them" do
      session = make(model: "blind")
      ref = Samagotchi::ImageStore.ingest(dir_of(session), bytes: File.binread(fixture_png), name: "a.png", source: "user")
      blind = Samagotchi::VisionSupport::Answer.new(value: false, reason: "models.blind sets vision: false")
      allow(Samagotchi::SendCommand).to receive(:vision_answer).and_return(blind)

      expect(turn(session, { prompt: "look", images: [ref], check_vision: true })).to match([422, include("error" => "no_vision")])
    end

    it "passes no_interrupt on to the worker's Bridge, and into the input file without one" do
      session = make
      own(session)
      bridge = instance_double(Samagotchi::BridgeClient)
      allow(bridge).to receive(:post_turn)
        .and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted","enqueued_id":"e1"}'))
      allow(app).to receive(:live_bridge_client).and_return(bridge)

      expect(turn(session, { prompt: "long", client_id: "tui:1", no_interrupt: true }).first).to eq(202)
      expect(bridge).to have_received(:post_turn).with(prompt: "long", client_id: "tui:1", no_interrupt: true)

      allow(app).to receive(:live_bridge_client).and_return(nil)
      expect(turn(session, { prompt: "long", client_id: "tui:1", no_interrupt: true })).to match([202, include("via" => "file")])
      inputs = Dir[File.join(dir_of(session), "input", "*")].map { |path| JSON.parse(File.read(path)) }
      expect(inputs).to contain_exactly(include("prompt" => "long", "no_interrupt" => true))
    end

    def fixture_png
      File.join(@tmp, "a.png").tap do |path|
        # A 1x1 PNG.
        File.binwrite(path, ["89504e470d0a1a0a0000000d4948445200000001000000010806000000" \
                             "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082"].pack("H*"))
      end
    end
  end

  describe "answer and dismiss: chi answer's client_id, the worker's refusals" do
    let(:session) { make(status: "running") }
    let(:bridge) { instance_double(Samagotchi::BridgeClient) }
    let(:ok) { Samagotchi::BridgeClient::Response.new(status: 200, body: "{}") }

    before { allow(app).to receive(:bridge_client).and_return(bridge) }

    def answer(body) = call("/api/sessions/#{session.id}/answer", method: "POST", body: { id: "q1", selected: ["A"] }.merge(body))

    it "passes on chi answer's client_id only; any other is dropped" do
      allow(bridge).to receive(:answer).and_return(ok)

      answer(client_id: "cli:answer")
      answer(client_id: "web:abc")
      answer({})

      expect(bridge).to have_received(:answer).with(id: "q1", selected: ["A"], freeform: nil, client_id: "cli:answer").once
      expect(bridge).to have_received(:answer).with(id: "q1", selected: ["A"], freeform: nil, client_id: nil).twice
    end

    it "passes the worker's 403 parent_answer_refused through, and sends once more after a 408 (504 after two)" do
      refused = Samagotchi::BridgeClient::Response.new(
        status: 403, body: '{"error":"parent_answer_refused","reason":"permit","detail":"only Deny can be given here"}'
      )
      allow(bridge).to receive(:answer).and_return(refused)
      expect(answer(client_id: "cli:answer")).to eq([403, { "error" => "parent_answer_refused", "reason" => "permit",
                                                            "detail" => "only Deny can be given here" }])

      late = Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}')
      allow(bridge).to receive(:answer).and_return(late, ok)
      expect(answer({}).first).to eq(200)
      allow(bridge).to receive(:answer).and_return(late, late)
      expect(answer({})).to match([504, include("error" => "worker_timeout")])
    end

    it "passes a dismissal's 409 not_dismissable through, with the worker's words" do
      allow(bridge).to receive(:dismiss_question).and_return(
        Samagotchi::BridgeClient::Response.new(status: 409, body: '{"error":"not_dismissable","detail":"answer Continue or Stop"}')
      )

      expect(call("/api/sessions/#{session.id}/question/dismiss", method: "POST", body: { id: "q1" }))
        .to eq([409, { "error" => "not_dismissable", "detail" => "answer Continue or Stop" }])
    end
  end

  describe "DELETE /api/sessions/:id: force" do
    it "refuses a live worker's session without force: 409 worker_running with DeleteRefused's message" do
      session = make
      own(session)

      status, body = call("/api/sessions/#{session.id}", method: "DELETE")

      expect([status, body]).to eq([409, { "error" => "worker_running", "detail" => "session #{session.id}'s worker is running",
                                           "message" => "session #{session.id}'s worker is running",
                                           "session_id" => session.id, "reason" => "worker_running" }])
      expect(Samagotchi::Session.exist?(session.id, state_dir: state_dir)).to be(true)
    end

    it "deletes a session with no worker without force" do
      session = make

      expect(call("/api/sessions/#{session.id}", method: "DELETE")).to match([200, include("status" => "deleted")])
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

  describe "what chi --remote reads besides (SessionAccess::Remote)" do
    it "names the session commands' routes and a remote attach's among GET /api/info's features" do
      expect(call("/api/info").last["features"]).to include("session_commands", "remote_attach")
    end

    it "answers ?brief=1 with the session file's status, names, folder, model, owner and pending question, no messages" do
      question = Samagotchi::PendingQuestion.new(id: "q1", question: "Go?", options: %w[Yes No])
      session = make(status: "running", pending_question: question, parent_answers: "hard")
      own(session)

      status, body = call("/api/sessions/#{session.id}?brief=1")

      expect(status).to eq(200)
      expect(body.keys).to contain_exactly("brief", "session", "pending_question")
      expect(body["session"]).to include("id" => session.id, "status" => "running", "display_title" => session.display_title,
                                         "working_directory" => folder, "project_root" => session.project_root,
                                         "model_name" => "m", "parent_answers" => "hard", "owner" => "worker")
      expect(body["pending_question"]).to include("id" => "q1", "options" => %w[Yes No])
      expect(call("/api/sessions/#{make.id}?brief=1").last).to include("pending_question" => nil)
      expect(call("/api/sessions/#{session.id.tr("0-9a-f", "0")}?brief=1").first).to eq(404)
    end

    it "says in a turn's 202 whether it went through the worker's Bridge or its input file" do
      session = make
      allow(Samagotchi::SessionManager).to receive(:resume_session)

      status, body = call("/api/sessions/#{session.id}/turn", method: "POST", body: { prompt: "hi", history: false })

      expect(status).to eq(202)
      expect(body).to include("via" => "file", "enqueued_id" => be_a(String))
    end

    it "with ?full=1 lists each source as added (its command too) and its snapshot, and a shadowed one" do
      session = make
      own_sources = Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir)
      project = Samagotchi::ContextSources.project_location_for(session.project_root, state_dir: state_dir)
      source = lambda do |name, scope, cmd: nil|
        Samagotchi::ContextSources::Source.new(name: name, cmd: cmd, every_seconds: nil, why: "w", hint: "h", scope: scope,
                                               added_by: "cli", created_at: "2026-10-23T10:00:00Z")
      end
      own_sources.add(source.call("ci", own_sources.scope, cmd: "echo ci"))
      project.add(source.call("ci", project.scope, cmd: "echo theirs"))
      project.add(source.call("notes", project.scope))
      project.record_text("notes", Samagotchi::ContextSources::Fetched.new(text: "body", summary: "s", wake: false, hint: nil))
      path = "/api/sessions/#{session.id}/context"

      expect(call(path).last["sources"].map { |row| row["name"] }).to eq(%w[ci notes])
      expect(JSON.generate(call(path).last)).not_to include("echo ci")

      rows = call("#{path}?full=1").last["sources"]
      expect(rows.map { |row| [row["name"], row.dig("source", "cmd"), row["shadowed"]] })
        .to eq([["ci", "echo ci", false], ["ci", "echo theirs", true], ["notes", nil, false]])
      expect(rows.first["source"]).to eq(own_sources.source("ci").to_h)
      expect(rows.last["snapshot"]).to include("summary" => "s", "revision" => Samagotchi::ContextSources.revision_of("body"))
      expect(rows.last["snapshot"]).not_to have_key("text")
      expect(call("#{path}/notes?full=1").last).to include("text" => "body", "source" => include("name" => "notes"))
    end
  end

  describe "a remote attach's worker: POST /api/sessions/:id/wake, GET …/worker" do
    let(:servers) { [] }
    let(:worker_json) do
      { "epoch" => "e1e1e1e1", "started_at" => "2026-10-23T12:00:00.000Z", "version" => "9.9.9",
        "features" => %w[delivery unqueue] }
    end

    after { servers.each(&:close) }

    # A live worker's sidecar: a port that takes a connect, an epoch.
    def live_worker(session, epoch: "e1e1e1e1")
      server = TCPServer.new("127.0.0.1", 0).tap { |opened| servers << opened }
      Samagotchi::WorkerSidecar.new(port: server.local_address.ip_port, session_id: session.id, started_at: "2026-10-23T12:00:00.000Z",
                                    version: "9.9.9", features: %w[delivery unqueue], epoch: epoch).write(dir_of(session))
    end

    def wake(session, body = {}) = call("/api/sessions/#{session.id}/wake", method: "POST", body: body)

    it "answers a live worker as is (woke: false), with the session's model, this machine's default and parent strategy" do
      session = make(model: "m")
      own(session)
      live_worker(session)
      allow(Samagotchi::ModelProfile).to receive(:default_model_name).and_return("server-default")
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      parent_answers_config("soft")

      status, body = wake(session)

      expect(status).to eq(200)
      expect(body).to include("session_id" => session.id, "woke" => false, "worker" => worker_json, "model_name" => "m",
                              "default_model" => "server-default", "installed" => nil)
      expect(body["parent_strategy"]).to include("name" => "soft")
      expect(Samagotchi::SessionManager).not_to have_received(:resume_session)
    end

    it "resumes an idle session's worker and waits for its Bridge, at most WAKE_MAX_WAIT" do
      session = make
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await) { live_worker(session) && live_link(Samagotchi::WorkerSidecar.read(dir_of(session))) }

      expect(wake(session, { wait: 60 })).to match([200, include("woke" => true, "worker" => worker_json)])
      expect(Samagotchi::SessionManager).to have_received(:resume_session).with(session.id, state_dir: state_dir)
      expect(Samagotchi::WorkerLink).to have_received(:await)
        .with(session.id, session_dir: dir_of(session), timeout: described_class::WAKE_MAX_WAIT)
    end

    it "answers 504 worker_timeout in chi --attach's words when the Bridge doesn't come in time" do
      session = make
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)

      late = "the worker for session #{session.id} did not start its Bridge in time"
      expect(wake(session, { wait: 0.5 }))
        .to eq([504, { "error" => "worker_timeout", "detail" => late, "message" => late, "session_id" => session.id }])
      expect(Samagotchi::WorkerLink).to have_received(:await).with(session.id, session_dir: dir_of(session), timeout: 0.5)
    end

    it "refuses a chi REPL's session (409 owned_by_tui), a leftover scratch one (409 scratch) and a bad wait (400)" do
      repl = make
      own(repl, kind: "tui")
      status, body = wake(repl)
      expect([status, body["error"], body["message"]])
        .to eq([409, "owned_by_tui", Samagotchi::SessionManager::OwnedByTUI.new(repl.id).message])

      scratch = make.tap do |made|
        made.scratch = true
        made.save(state_dir: state_dir)
      end
      expect(wake(scratch)).to eq([409, { "error" => "scratch", "detail" => Samagotchi::LaunchMode::SCRATCH_LEFTOVER,
                                          "message" => Samagotchi::LaunchMode::SCRATCH_LEFTOVER,
                                          "session_id" => scratch.id }])

      expect(wake(make, { wait: "soon" }).first(1)).to eq([400])
    end

    it "answers 404 not_found for no such session, in a session's words, never a missing route's" do
      [call("/api/sessions/feedbeef00/wake", method: "POST", body: {}), call("/api/sessions/feedbeef00/worker")].each do |status, body|
        expect(status).to eq(404)
        expect(body["error"]).to eq("not_found")
        expect(body["detail"]).not_to start_with("not found: /")
      end
    end

    it "reads the worker without starting one: live with its epoch, idle, stopped, a chi REPL's" do
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      live = make
      own(live)
      live_worker(live)
      expect(call("/api/sessions/#{live.id}/worker"))
        .to match([200, include("session_id" => live.id, "live" => true, "stopped" => false, "owner" => "worker",
                                "worker" => worker_json, "parent_strategy" => include("name"))])

      idle = make
      expect(call("/api/sessions/#{idle.id}/worker").last)
        .to include("live" => false, "stopped" => false, "owner" => nil, "worker" => nil)

      stopped = make
      Samagotchi::Session.mark_stopped(stopped.id, state_dir: state_dir)
      expect(call("/api/sessions/#{stopped.id}/worker").last).to include("live" => false, "stopped" => true)

      repl = make
      own(repl, kind: "tui")
      expect(call("/api/sessions/#{repl.id}/worker").last).to include("live" => false, "owner" => "tui")
      expect(Samagotchi::SessionManager).not_to have_received(:resume_session)
    end

    it "reads an older worker's sidecar (no epoch) as epoch null" do
      session = make
      own(session)
      live_worker(session, epoch: nil)

      expect(call("/api/sessions/#{session.id}/worker").last["worker"]).to include("epoch" => nil)
    end
  end

  describe "a remote attach's terminal commands: exit, recap, stats, children counts, a turn's records" do
    let(:session) { make(status: "running") }
    let(:bridge) { instance_double(Samagotchi::BridgeClient) }
    let(:path) { "/api/sessions/#{session.id}" }

    before { allow(app).to receive(:bridge_client).and_return(bridge) }

    def reply(status, body) = Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(body))

    it "relays /exit with an attached TUI's client id only, and delete; 200 as the worker said" do
      allow(bridge).to receive(:request_exit).and_return(reply(200, { status: "exiting", session_id: session.id, discard: false }))

      expect(call("#{path}/exit", method: "POST", body: { client_id: "tui:1@mac", delete: true }))
        .to eq([200, { "status" => "exiting", "session_id" => session.id, "discard" => false }])
      call("#{path}/exit", method: "POST", body: { client_id: "web:x" })
      call("#{path}/exit", method: "POST", body: {})

      expect(bridge).to have_received(:request_exit).with(client_id: "tui:1@mac", delete: true).once
      expect(bridge).to have_received(:request_exit).with(client_id: nil, delete: false).twice
    end

    it "passes the ask's stop: \"all\" on, and relays the holds and what was stopped" do
      allow(bridge).to receive(:request_exit).and_return(
        reply(409, { status: "held", reason: "reminders", session_id: session.id,
                     holds: [{ "kind" => "reminders", "items" => [{ "id" => "api_health", "label" => "api_health",
                                                                    "detail" => "every 20m" }] }] }),
        reply(200, { status: "exiting", session_id: session.id, stopped: { "reminders" => ["api_health"] } })
      )

      status, body = call("#{path}/exit", method: "POST", body: { client_id: "tui:1@mac", stop: "all" })

      expect(bridge).to have_received(:request_exit).with(client_id: "tui:1@mac", delete: false, stop: true)
      expect(status).to eq(409)
      expect(body["holds"].first["items"].first["label"]).to eq("api_health")

      status, body = call("#{path}/exit", method: "POST", body: { client_id: "tui:1@mac", stop: "all" })
      expect(status).to eq(200)
      expect(body["stopped"]).to eq({ "reminders" => ["api_health"] })
    end

    it "answers a held worker's 409 with its reason and tasks, and the words" do
      allow(bridge).to receive(:request_exit)
        .and_return(reply(409, { status: "held", reason: "other_ui", tasks: [{ id: "t1", command: "sleep 9" }], session_id: session.id }))

      status, body = call("#{path}/exit", method: "POST", body: { client_id: "tui:1@mac" })

      expect(status).to eq(409)
      expect(body).to include("error" => "held", "status" => "held", "reason" => "other_ui", "session_id" => session.id,
                              "tasks" => [{ "id" => "t1", "command" => "sleep 9" }])
      expect(body["message"]).to eq(body["detail"])
    end

    it "maps exit's and recap's failures as every relay, with {error, detail, message}" do
      allow(bridge).to receive_messages(request_exit: reply(404, { error: "not_found" }), request_recap: reply(408, { error: "deadline_passed" }))

      exit_status, exit_body = call("#{path}/exit", method: "POST", body: {})
      recap_status, recap_body = call("#{path}/recap", method: "POST")
      expect([exit_status, exit_body["error"], recap_status, recap_body["error"]]).to eq([501, "not_supported", 504, "worker_timeout"])
      [exit_body, recap_body].each { |body| expect(body["message"]).to eq(body["detail"]) }

      allow(app).to receive(:bridge_client).and_return(nil)
      %w[exit recap].each do |route|
        expect(call("#{path}/#{route}", method: "POST", body: {}))
          .to eq([503, { "error" => "not_live", "detail" => "no live bridge for session #{session.id}",
                         "message" => "no live bridge for session #{session.id}" }])
      end
      expect(call("#{path}/stats").first).to eq(503)
    end

    it "relays /recap: the worker's saved recap and what came of asking" do
      recap = { enabled: true, saved: { text: "Fixed it.", turns_since: 0 }, request: "started", min_user_turns: 2 }
      allow(bridge).to receive(:request_recap).and_return(reply(200, recap))

      expect(call("#{path}/recap", method: "POST")).to eq([200, JSON.parse(JSON.generate(recap))])
    end

    it "reads /stats from the worker, its state's metrics for an older one, 504 when it doesn't answer" do
      allow(bridge).to receive(:get).with("stats").and_return([200, { "metrics" => { "turns" => 2 } }])
      expect(call("#{path}/stats")).to eq([200, { "session_id" => session.id, "metrics" => { "turns" => 2 } }])

      allow(bridge).to receive(:get).with("stats").and_return([404, { "error" => "not_found" }])
      allow(bridge).to receive(:get).with("state").and_return([200, { "session_state_snapshot" => { "metrics" => { "turns" => 1 } } }])
      expect(call("#{path}/stats").last["metrics"]).to eq("turns" => 1)

      allow(bridge).to receive(:get).with("stats").and_return([nil, nil])
      status, body = call("#{path}/stats")
      expect([status, body["error"], body["message"]]).to eq([504, "worker_timeout", body["detail"]])
    end

    it "counts the session's delegates here; 404 for no session, never a missing route's words" do
      expect(call("#{path}/children/counts")).to eq([200, { "running" => 0, "waiting" => 0, "unreported" => 0 }])

      status, body = call("/api/sessions/feedbeef00/children/counts")
      expect([status, body["error"]]).to eq([404, "not_found"])
      expect(body["detail"]).not_to start_with("not found: /")
    end

    it "gives a turn's saved records as saved, none for a turn without; 400 for a bad id, 404 for no session" do
      File.write(File.join(dir_of(session), "analytics.json"), JSON.generate(
        "tool_records" => [{ "turn_id" => "t1", "iteration" => 1, "call_index" => 1, "tool" => "read", "duration_ms" => 42 },
                           { "turn_id" => "t0", "iteration" => 1, "call_index" => 1, "tool" => "read", "duration_ms" => 9 }],
        "turn_records" => [{ "id" => "t1", "status" => "failed", "failure" => { "summary" => "boom" } }]
      ))

      status, body = call("#{path}/turns/t1/records")
      expect(status).to eq(200)
      expect(body["tool_records"].map { |r| r["duration_ms"] }).to eq([42])
      expect(body["turn_record"]).to include("status" => "failed")
      expect(call("#{path}/turns/t9/records")).to eq([200, { "tool_records" => [], "turn_record" => nil }])

      expect(call("#{path}/turns/a%20b/records")).to match([400, include("error" => "invalid_turn_id", "message" => anything)])
      expect(call("/api/sessions/feedbeef00/turns/t1/records").first).to eq(404)
    end
  end
end
