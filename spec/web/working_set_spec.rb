# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/working_set_steer"
require "samagotchi/system_prompt"
require "samagotchi/model_profile"
require "samagotchi/tools/registry"
require "uri"

# GET /api/sessions/:id/working_set: the set as the model has it
# (WorkingSet), from a live worker's snapshot or the session file.
RSpec.describe Samagotchi::Web::App, "working set" do
  let(:tmpdir) { Dir.mktmpdir("web-ws") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:repo) { File.join(tmpdir, "app").tap { |d| FileUtils.mkdir_p(d) } }
  let(:path) { File.join(repo, "cart.rb").tap { |p| File.write(p, "one\n") } }
  let(:app) { described_class.new(state_dir: state_dir, session_class: Samagotchi::Session, bridge_wait_timeout: 0) }

  after { FileUtils.rm_rf(tmpdir) }

  def call(url)
    status, _headers, chunks = app.call(Rack::MockRequest.env_for(url, "HTTP_HOST" => "127.0.0.1"))
    [status, JSON.parse(chunks.to_a.join)]
  end

  def stamp
    stat = File.stat(path)
    { path: path, mtime_ns: (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec, size: stat.size }
  end

  def read_messages(edits: nil)
    [{ role: "user", content: "go" },
     { role: "model", content: "", tool_calls: [{ id: "c1", name: "read", arguments: { "path" => "cart.rb" } }] },
     { role: "tool_response", content: "[read]\none", tool_call_id: "c1", tool_ids: ["t1"], tool_stamps: [stamp],
       edits: edits }.compact]
  end

  def saved_session(messages)
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: repo).tap do |s|
      s.messages.concat(messages)
      s.save(state_dir: state_dir)
    end
  end

  it "builds it from the session file without a worker, a file changed since its read stale" do
    session = saved_session(read_messages)

    status, body = call("/api/sessions/#{session.id}/working_set")
    expect(status).to eq(200)
    expect(body).to eq("items" => [{ "kind" => "file", "key" => path, "state" => "live", "tokens" => 3, "ops" => ["read"],
                                     "count" => 1, "first_id" => "t1", "pinned" => false, "has_drop" => false }],
                       "at" => 3, "running" => false)

    File.write(path, "one\ntwo\n")
    expect(call("/api/sessions/#{session.id}/working_set").last["items"].first["state"]).to eq("stale")
  end

  it "marks the items the session pinned" do
    session = saved_session(read_messages)
    session.working_set_pins = [{ "kind" => "file", "key" => path }]
    session.save(state_dir: state_dir)

    expect(call("/api/sessions/#{session.id}/working_set").last["items"]).to match([include("key" => path, "pinned" => true)])
  end

  it "uses a live worker's idle working set without rebuilding it" do
    session = saved_session([])
    idle_set = {
      "items" => [{ "kind" => "memory", "key" => "notes", "state" => "live", "tokens" => 9, "ops" => ["read"],
                    "count" => 1, "first_id" => "t2", "pinned" => false, "has_drop" => false }],
      "at" => 7,
      "adds" => [{ "kind" => "file", "key" => File.join(repo, "future.rb"), "label" => "future.rb" }]
    }
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
      "snapshot" => { "current_turn" => nil, "idle_working_set" => idle_set }
    )
    expect(Samagotchi::WorkingSet).not_to receive(:build)

    status, body = call("/api/sessions/#{session.id}/working_set")

    expect(status).to eq(200)
    expect(body).to eq(idle_set.merge("running" => false))
  end

  it "carries the adds the next turn's note asks the model to read, through the session file" do
    target = Samagotchi::WorkingSetSteer.target("lib/tax.rb", cwd: repo)
    messages = Samagotchi::WorkingSetSteer.record!(read_messages, Samagotchi::WorkingSetSteer.add(read_messages, target, strategy: :none, cwd: repo))
    session = saved_session(messages)

    expect(call("/api/sessions/#{session.id}/working_set").last["adds"])
      .to eq([{ "kind" => "file", "key" => File.join(repo, "lib/tax.rb"), "label" => "lib/tax.rb" }])
  end

  it "builds it from a live worker's snapshot (string keys) under the worker's strategy" do
    session = saved_session([])
    forget = { "t1" => { "kind" => "forget", "note" => "cart", "by" => "model", "staged_at" => "x", "applied_at" => "x" } }
    live_messages = JSON.parse(JSON.generate(read_messages(edits: forget)))
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
      "snapshot" => { "messages" => live_messages },
      "session_state_snapshot" => { "llm_context" => { "strategy" => "forget" } }
    )

    _status, body = call("/api/sessions/#{session.id}/working_set")

    expect(body["items"]).to match([include("key" => path, "state" => "forgotten")])
    expect(body["at"]).to eq(3)
    expect(body["running"]).to be(false)
  end

  it "says dropped for a user's drop, from the file under none and a worker's snapshot (string keys)" do
    drop = { "t1" => { "kind" => "drop", "note" => "", "by" => "user", "staged_at" => "x", "applied_at" => "x" } }
    session = saved_session(read_messages(edits: drop))

    expect(call("/api/sessions/#{session.id}/working_set").last["items"]).to match([include("state" => "dropped")])

    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
      "snapshot" => { "messages" => JSON.parse(JSON.generate(read_messages(edits: drop))) }, "session_state_snapshot" => {}
    )
    expect(call("/api/sessions/#{session.id}/working_set").last["items"]).to match([include("state" => "dropped")])
  end

  it "says when a turn runs: before the turn's first set (or from an older worker), the session's messages" do
    session = saved_session([])
    live_messages = JSON.parse(JSON.generate(read_messages))
    [{ "messages" => live_messages, "current_turn" => { "parts" => [] }, "working_set" => nil },
     { "messages" => live_messages, "current_turn" => { "parts" => [] } }].each do |snapshot|
      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot")
                                             .and_return("snapshot" => snapshot, "session_state_snapshot" => {})

      _status, body = call("/api/sessions/#{session.id}/working_set")

      expect(body).to include("at" => 3, "running" => true)
      expect(body["items"]).to match([include("key" => path, "state" => "live")])
    end
  end

  it "answers the running turn's last set while a turn runs (the snapshot's messages lag it)" do
    session = saved_session([])
    turn_set = { "items" => [{ "kind" => "memory", "key" => "notes", "state" => "live", "tokens" => 9, "ops" => ["read"],
                               "count" => 1, "first_id" => "t2" }], "at" => 7 }
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
      "snapshot" => { "messages" => JSON.parse(JSON.generate(read_messages)), "current_turn" => { "parts" => [] },
                      "working_set" => turn_set },
      "session_state_snapshot" => {}
    )

    _status, body = call("/api/sessions/#{session.id}/working_set")

    expect(body).to eq(turn_set.merge("running" => true))
  end

  it "builds from the messages between turns, whatever set the snapshot carries" do
    session = saved_session([])
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
      "snapshot" => { "messages" => JSON.parse(JSON.generate(read_messages)), "current_turn" => nil,
                      "working_set" => { "items" => [], "at" => 9 } },
      "session_state_snapshot" => {}
    )

    _status, body = call("/api/sessions/#{session.id}/working_set")

    expect(body).to include("at" => 3, "running" => false)
    expect(body["items"]).to match([include("key" => path)])
  end

  it "is empty for a session without tool runs, and 404 for an unknown one" do
    session = saved_session([{ role: "user", content: "hi" }])

    expect(call("/api/sessions/#{session.id}/working_set")).to eq([200, { "items" => [], "at" => 1, "running" => false }])
    expect(call("/api/sessions/00000000-0000-4000-8000-000000000000/working_set").first).to eq(404)
  end

  describe "GET …/working_set/item (an item's timeline)" do
    require "cgi"

    def item(session, kind, key, extra = "")
      call("/api/sessions/#{session.id}/working_set/item?kind=#{kind}&key=#{CGI.escape(key)}#{extra}")
    end

    it "answers the item's runs from the session file, under the saved strategy" do
      session = saved_session(read_messages)

      status, body = item(session, "file", path)

      expect(status).to eq(200)
      expect(body).to include("kind" => "file", "key" => path)
      expect(body["events"]).to match([include("tool_id" => "t1", "op" => "read", "sent" => true, "text" => "one",
                                               "lines" => { "first" => 1, "last" => 1, "whole" => true, "partial" => false })])
    end

    it "asks a worker with the feature for just the item, the key intact, never the snapshot or the session file" do
      session = saved_session([])
      key = File.join(repo, "my dir/a&b=c.rb")
      allow(Samagotchi::WorkerLink).to receive(:live_features).with(session.id, state_dir: state_dir)
                                                               .and_return([Samagotchi::WorkingSet::ITEM_FEATURE])
      answer = { "kind" => "file", "key" => key, "events" => [{ "tool_id" => "t9" }], "at" => 12, "running" => true }
      asked = nil
      allow(app).to receive(:bridge_get) { |_id, target| asked = target and [200, answer] }
      allow(app).to receive(:bridge_get_json)
      allow(Samagotchi::Session).to receive(:load).and_call_original

      expect(item(session, "file", key, "&now=1&latest=1")).to eq([200, answer])
      expect(URI.decode_www_form(asked.delete_prefix("working_set/item?")).to_h)
        .to eq("kind" => "file", "key" => key, "now" => "1", "latest" => "1")
      expect(app).not_to have_received(:bridge_get_json)
      expect(Samagotchi::Session).not_to have_received(:load)
    end

    it "falls back to the snapshot's messages for a worker without the feature or one without the route (404)" do
      session = saved_session([])
      snapshot = { "snapshot" => { "messages" => JSON.parse(JSON.generate(read_messages)), "current_turn" => nil },
                   "session_state_snapshot" => {} }
      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(snapshot)
      allow(app).to receive(:bridge_get).and_return([404, { "error" => "not_found" }])

      [[], [Samagotchi::WorkingSet::ITEM_FEATURE]].each do |features|
        allow(Samagotchi::WorkerLink).to receive(:live_features).and_return(features)
        expect(item(session, "file", path).last["events"]).to match([include("tool_id" => "t1", "text" => "one")]), features.inspect
      end
      expect(app).to have_received(:bridge_get).once
    end

    # A lagging snapshot answer would be drawn and never asked again (the
    # signature it was asked at is the open item's): a 502 marks the page's
    # ask failed, so it asks again on the next event.
    it "answers 502 when the worker with the feature times out or fails, never the snapshot" do
      session = saved_session([])
      allow(Samagotchi::WorkerLink).to receive(:live_features).and_return([Samagotchi::WorkingSet::ITEM_FEATURE])
      allow(app).to receive(:bridge_get_json)

      [[nil, nil], [500, { "error" => "bridge_error" }], [409, { "error" => "no_session" }]].each do |reply|
        allow(app).to receive(:bridge_get).and_return(reply)
        status, body = item(session, "file", path)
        expect([status, body["error"]]).to eq([502, "bridge_error"]), reply.inspect
      end
      expect(app).not_to have_received(:bridge_get_json)
    end

    it "answers the peek's events and counts only on ?latest=1 from the file too" do
      session = saved_session(read_messages)

      expect(item(session, "file", path, "&latest=1").last)
        .to include("counts" => { "read" => 1, "edit" => 0 }, "latest" => true, "events" => [include("tool_id" => "t1")])
    end

    it "reads the session file and asks no Bridge without a live worker" do
      session = saved_session(read_messages)
      allow(app).to receive(:bridge_get_json)
      allow(app).to receive(:bridge_get)

      expect(item(session, "file", path).last["events"]).to match([include("tool_id" => "t1")])
      expect(app).not_to have_received(:bridge_get_json)
      expect(app).not_to have_received(:bridge_get)
    end

    it "builds from an older live worker's messages even when it holds a precomputed set" do
      session = saved_session([])
      allow(Samagotchi::WorkerLink).to receive(:live_features).and_return([])
      drop = { "t1" => { "kind" => "drop", "note" => "", "by" => "user", "staged_at" => "x", "applied_at" => "x" } }
      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
        "snapshot" => { "messages" => JSON.parse(JSON.generate(read_messages(edits: drop))), "current_turn" => nil,
                        "idle_working_set" => { "items" => [], "at" => 3 } },
        "session_state_snapshot" => {}
      )

      expect(item(session, "file", path).last["events"]).to match([include("sent" => false, "dropped" => true)])
    end

    it "adds a memory's text now on ?now=1" do
      memory = File.join(Samagotchi::MemoryPaths.system_dir, "ws-spec-style.md")
      FileUtils.mkdir_p(File.dirname(memory))
      File.write(memory, "be brief\n")
      stat = File.stat(memory)
      stamp = { memories: { "style" => { path: memory, mtime_ns: (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec,
                                         size: stat.size } } }
      session = saved_session([{ role: "model", content: "", tool_calls: [{ id: "c1", name: "memory_read", arguments: { "name" => "style" } }] },
                               { role: "tool_response", content: "[memory_read]\nbe brief\n", tool_call_id: "c1",
                                 tool_ids: ["t1"], tool_stamps: [stamp] }])
      File.write(memory, "be very brief\n")

      expect(item(session, "memory", "style").last).not_to have_key("now")
      now = item(session, "memory", "style", "&now=1").last["now"]
      expect(now).to include("text" => "be very brief\n", "gone" => false)
      expect(now["diff"]["text"]).to include("+be very brief")
    ensure
      FileUtils.rm_f(memory) if memory
    end

    it "is 400 without a known kind or a key, 404 for an unknown session" do
      session = saved_session(read_messages)

      expect(item(session, "dir", path).first).to eq(400)
      expect(item(session, "file", " ").first).to eq(400)
      expect(call("/api/sessions/00000000-0000-4000-8000-000000000000/working_set/item?kind=file&key=x").first).to eq(404)
    end
  end

  # GET …/working_set/part?key=: a "From the start" part as chi sent it, a
  # slice of the saved head (WorkingSetPart), or case C's line.
  describe "a prompt part" do
    let(:config) { File.join(tmpdir, "cfg") }
    let(:model) { Samagotchi::SystemPrompt::ModelIdentity.new(ref: "box:m", host: "box", key: "m", fallback_key: "fb") }

    around { |example| with_config_home(config) { example.run } }

    before do
      allow(Samagotchi::BundleNeeds).to receive(:found?).and_call_original
      allow(Samagotchi::BundleNeeds).to receive(:found?).with("rg").and_return(false)
      FileUtils.mkdir_p(File.join(repo, ".git"))
      File.write(File.join(repo, "AGENTS.md"), "Widgets only.\n\n\n")
      write_memory("system", "identity.md", "I am chi.\n")
      write_memory("system", "identity.m.md", "Overlay for m.")
      write_memory("system", "style.md", "be brief\n")
      write_memory("system", "style.fb.md", "Fallback overlay.")
      write_memory("system", "model_notes_tips.md", "models: *\nNote body\n")
      write_memory("system", "model_notes_tips.m.md", "note overlay")
    end

    def write_memory(scope, name, text)
      dir = Samagotchi::MemoryPaths.scope_dir(scope, cwd: repo)
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, name), text)
    end

    def part_call(session, key) = call("/api/sessions/#{session.id}/working_set/part?key=#{URI.encode_www_form_component(key)}")

    # A session whose head and parts are a real build's (chat), saved; +cwd+:
    # the folder it was built and works in.
    def built_session(memories: %w[style], head: nil, cwd: repo)
      notes = -> { Dir.chdir(cwd) { Samagotchi::ModelNotes.for(name: "m", key: "m", fallback_key: "fb", warn: false) } }
      prompt = Samagotchi::SystemPrompt.new(profile: -> { Samagotchi::ModelProfile.gemma4 }, tools: -> { Samagotchi::Tools::Registry.new },
                                            session: -> {}, thinking: -> { :off }, model: -> { model }, model_notes: notes,
                                            memories: memories)
      @built = Dir.chdir(cwd) { prompt.built_for(chat: true) }
      saved_session([{ role: "system", content: head || @built.prompt }, { role: "user", content: "hi" }]).tap do |session|
        session.prompt_parts = @built.prompt_parts
        session.working_directory = cwd
        session.save(state_dir: state_dir)
      end
    end

    def keys = Samagotchi::PromptPart.keys(@built.prompt_parts)

    def part_of(kind) = @built.prompt_parts.find { |part| part.kind == kind }

    it "answers each part's slice of the saved head: its own text, chi's lead apart" do
      session = built_session
      status, body = part_call(session, "identity:identity@system")
      expect(status).to eq(200)
      expect(body["part"]).to include("kind" => "identity", "ref" => "identity", "scope" => "system")
      expect(body["sent"]).to eq("lead" => "System identity (auto-loaded, scope=system):\n",
                                 "text" => "I am chi.\n\n\n---\n\nModel-specific guidance (m):\nOverlay for m.")
      expect(part_call(session, keys[@built.prompt_parts.index(part_of("agents"))]).last["sent"]).to eq(
        "lead" => "Project specific description:\n", "text" => "Widgets only."
      )
      expect(part_call(session, "base:base prompt").last["sent"]).to include("lead" => "")
      expect(part_call(session, "session:session").first).to eq(404) # no session line in this build
      expect(part_call(session, "nope:x").first).to eq(404)
      expect(part_call(session, " ").first).to eq(400)
    end

    it "opens tools as their names and sizes, whatever the head" do
      session = built_session(head: "not the head")
      expect(part_call(session, keys.first).last).to include("tools" => [])
    end

    it "says the worker runs an older chi (live) or the prompt was an older chi's (no worker): parts without a place" do
      session = built_session
      session.prompt_parts = @built.prompt_parts.map { |part| Samagotchi::PromptPart.from_h(part.to_h.slice(:kind, :label, :chars, :tokens, :ref, :scope)) }
      session.save(state_dir: state_dir)
      expect(part_call(session, "identity:identity@system").last).to include("note" => Samagotchi::WorkingSetPart::WORDS[:older_chi])
      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
        "snapshot" => { "messages" => JSON.parse(JSON.generate(session.messages)), "current_turn" => nil },
        "session_state_snapshot" => { "prompt_parts" => session.prompt_parts.map(&:to_h) }
      )
      body = part_call(session, "identity:identity@system").last
      expect(body).to include("note" => Samagotchi::WorkingSetPart::WORDS[:older_worker], "reason" => "older_worker")
      expect(body).not_to have_key("sent")
    end

    it "gives a live worker of this chi the older chi's words, not a restart (a fresh worker: the file's parts until a turn)" do
      session = built_session
      session.prompt_parts = @built.prompt_parts.map { |part| Samagotchi::PromptPart.from_h(part.to_h.slice(:kind, :label, :chars, :tokens, :ref, :scope)) }
      session.save(state_dir: state_dir)
      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
        "snapshot" => { "messages" => JSON.parse(JSON.generate(session.messages)), "current_turn" => nil,
                        "chi_version" => Samagotchi::VERSION },
        "session_state_snapshot" => { "prompt_parts" => session.prompt_parts.map(&:to_h) }
      )
      expect(part_call(session, "identity:identity@system").last)
        .to include("note" => Samagotchi::WorkingSetPart::WORDS[:older_chi], "reason" => "older_chi")
      expect(Samagotchi::WorkingSetPart.older_worker?("0.1.0")).to be(true)
      expect(Samagotchi::WorkingSetPart.older_worker?(nil)).to be(true)
    end

    it "says chi builds its prompt at the first turn when messages[0] is not a system head" do
      session = built_session
      session.messages.shift
      session.save(state_dir: state_dir)
      expect(part_call(session, "identity:identity@system").last).to include("note" => Samagotchi::WorkingSetPart::WORDS[:no_prompt])
    end

    it "under a changed head: rebuilt while a turn runs (live), changed after it was sent (idle), with the source now" do
      session = built_session(head: "an older head")
      idle = part_call(session, "identity:identity@system").last
      expect(idle).to include("changed" => "idle", "note" => Samagotchi::WorkingSetPart::WORDS[:idle])
      expect(idle["now"]).to eq("text" => "I am chi.\n\n\n---\n\nModel-specific guidance (m):\nOverlay for m.", "gone" => false)
      expect(idle).not_to have_key("sent")

      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
        "snapshot" => { "messages" => JSON.parse(JSON.generate(session.messages)), "current_turn" => { "id" => "t" } },
        "session_state_snapshot" => { "prompt_parts" => session.prompt_parts.map(&:to_h) }
      )
      running = part_call(session, "identity:identity@system").last
      expect(running).to include("changed" => "running", "note" => Samagotchi::WorkingSetPart::WORDS[:running])
      # Base, an index: chi's own text, the line alone.
      expect(part_call(session, "base:base prompt").last).not_to have_key("now")
      expect(part_call(session, "indexes:system").last).not_to have_key("now")
    end

    it "re-fetches each kind to its build's digest: identity's overlay by model key, a bare preload by the fallback key, a note's overlay, AGENTS.md" do
      session = built_session(head: "an older head")
      %w[identity preloads notes agents].each do |kind|
        part = part_of(kind)
        now = part_call(session, keys[@built.prompt_parts.index(part)]).last["now"]
        expect(now).to include("gone" => false), kind
        expect(Samagotchi::PromptPart.digest_of(now["text"])).to eq(part.digest), kind
      end
      expect(part_of("preloads").scope).to eq("system") # a bare name the system scope answered
      expect(part_of("preloads").params).to include("requested_scope" => nil, "fallback_model_key" => "fb")
    end

    it "re-fetches the other shapes to their build's digest: a project/x preload, a project note, a scope's second note, " \
       "identity without an overlay, a two-file AGENTS chain" do
      File.delete(File.join(Samagotchi::MemoryPaths.system_dir, "identity.m.md"))
      write_memory("system", "model_notes_zed.md", "models: *\nSecond system note\n")
      write_memory("project", "model_notes_proj.md", "models: *\nProject note\n")
      write_memory("project", "pstyle.md", "project style\n")
      pkg = File.join(repo, "pkg").tap { |dir| FileUtils.mkdir_p(dir) }
      File.write(File.join(pkg, "AGENTS.md"), "Package rules.\n")
      session = built_session(memories: %w[project/pstyle], head: "an older head", cwd: pkg)
      parts = @built.prompt_parts
      notes = parts.select { |part| part.kind == "notes" }
      expect(notes.map { |part| [part.ref, part.scope] }).to include(%w[model_notes_tips system], %w[model_notes_zed system],
                                                                     %w[model_notes_proj project])
      expect(parts.count { |part| part.kind == "agents" }).to eq(2)
      expect(part_of("preloads")).to have_attributes(ref: "pstyle", scope: "project")
      expect(part_of("preloads").params).to include("requested_scope" => "project")
      checked = parts.select { |part| %w[identity preloads notes agents].include?(part.kind) }
      expect(checked.map(&:kind).tally).to eq("identity" => 1, "preloads" => 1, "notes" => 3, "agents" => 2)
      checked.each do |part|
        now = part_call(session, keys[parts.index(part)]).last["now"]
        expect(now).to include("gone" => false), part.ref
        expect(Samagotchi::PromptPart.digest_of(now["text"])).to eq(part.digest), part.ref
      end
      expect(Samagotchi::WorkingSetPart.states(parts, root: Samagotchi::MemoryPaths.system_dir, cwd: pkg)).to eq([])
    end

    # GET …/working_set's parts: which "From the start" parts are stale.
    def stale_keys(session)
      body = call("/api/sessions/#{session.id}/working_set").last
      body.key?("parts") ? body["parts"].map { |state| state.fetch("key") if state["state"] == "stale" } : []
    end

    it "says in the GET which prompt parts changed since they were sent: an edit, an overlay gone, a memory gone; none again" do
      session = built_session
      preload = keys[@built.prompt_parts.index(part_of("preloads"))]
      expect(call("/api/sessions/#{session.id}/working_set").last).not_to have_key("parts")

      File.write(File.join(Samagotchi::MemoryPaths.system_dir, "style.md"), "be terse\n")
      expect(stale_keys(session)).to eq([preload])
      File.write(File.join(Samagotchi::MemoryPaths.system_dir, "style.md"), "be brief\n")
      expect(stale_keys(session)).to eq([])

      File.delete(File.join(Samagotchi::MemoryPaths.system_dir, "identity.m.md"))
      File.delete(File.join(Samagotchi::MemoryPaths.system_dir, "style.md"))
      File.write(File.join(repo, "AGENTS.md"), "Gadgets too.\n")
      expect(stale_keys(session)).to contain_exactly("identity:identity@system", preload, keys[@built.prompt_parts.index(part_of("agents"))])
    end

    it "never says an index, an appended file or an older chi's part is stale" do
      extra = File.join(repo, "extra.md").tap { |file| File.write(file, "Extra.\n") }
      prompt = Samagotchi::SystemPrompt.new(profile: -> { Samagotchi::ModelProfile.gemma4 }, tools: -> { Samagotchi::Tools::Registry.new },
                                            session: -> {}, thinking: -> { :off }, model: -> { model }, memories: %w[style],
                                            appended_files: [extra])
      @built = Dir.chdir(repo) { prompt.built_for(chat: true) }
      expect(@built.prompt_parts.map(&:kind)).to include("indexes", "appended")
      session = saved_session([{ role: "system", content: @built.prompt }]).tap do |saved|
        saved.prompt_parts = @built.prompt_parts
        saved.save(state_dir: state_dir)
      end
      File.write(extra, "Changed.\n")
      write_memory("system", "fresh.md", "a new memory: the index changed\n")
      expect(stale_keys(session)).to eq([])

      File.write(File.join(Samagotchi::MemoryPaths.system_dir, "style.md"), "be terse\n")
      expect(stale_keys(session)).to eq([keys[@built.prompt_parts.index(part_of("preloads"))]])
      session.prompt_parts = @built.prompt_parts.map { |part| Samagotchi::PromptPart.from_h(part.to_h.slice(:kind, :label, :chars, :tokens, :ref, :scope)) }
      session.save(state_dir: state_dir)
      expect(stale_keys(session)).to eq([])
    end

    it "says stale on every branch of the GET: a live idle worker's set, a running turn's, an older worker's snapshot" do
      session = built_session
      File.write(File.join(Samagotchi::MemoryPaths.system_dir, "style.md"), "be terse\n")
      preload = keys[@built.prompt_parts.index(part_of("preloads"))]
      wire = JSON.parse(JSON.generate(session.prompt_parts.map(&:to_h)))
      set = { "items" => [], "at" => 3 }
      [{ "snapshot" => { "current_turn" => nil, "idle_working_set" => set }, "session_state_snapshot" => { "prompt_parts" => wire } },
       { "snapshot" => { "current_turn" => { "parts" => [] }, "working_set" => set }, "session_state_snapshot" => { "prompt_parts" => wire } },
       # An older worker (no idle set, no parts in its frame): the file's parts.
       { "snapshot" => { "messages" => [], "current_turn" => nil }, "session_state_snapshot" => {} }].each do |live|
        allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(live)
        expect(stale_keys(session)).to eq([preload]), live.inspect
      end
      # The live worker's parts are the truth: a snapshot whose parts are none says none.
      allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(
        "snapshot" => { "current_turn" => nil, "idle_working_set" => set }, "session_state_snapshot" => { "prompt_parts" => [] }
      )
      expect(stale_keys(session)).to eq([])
    end

    it "adds the source now and its diff from the sent text on &now=1: changed, unchanged, gone, scrubbed" do
      session = built_session
      preload = keys[@built.prompt_parts.index(part_of("preloads"))]
      now_call = ->(key) { call("/api/sessions/#{session.id}/working_set/part?key=#{URI.encode_www_form_component(key)}&now=1").last }
      expect(part_call(session, preload).last).not_to have_key("now")
      same = now_call.call(preload)
      expect(same["sent"]["text"]).to eq("be brief\n\n\n---\n\nModel-specific guidance (fb):\nFallback overlay.")
      expect(same["now"]).to include("text" => same["sent"]["text"], "gone" => false)
      expect(same["now"]["diff"]).to include("text" => "", "added" => 0, "removed" => 0, "new_file" => false)

      File.write(File.join(Samagotchi::MemoryPaths.system_dir, "style.md"), "be terse\n")
      changed = now_call.call(preload)
      expect(changed["now"]["text"]).to start_with("be terse\n")
      expect(changed["now"]["diff"]).to include("added" => 1, "removed" => 1)
      expect(changed["now"]["diff"]["text"]).to include("-be brief", "+be terse")
      expect(changed["now"]["diff"]["text"]).not_to include("No newline")

      File.binwrite(File.join(Samagotchi::MemoryPaths.system_dir, "style.md"), "bad \xFF byte\n")
      expect(now_call.call(preload)["now"]["text"]).to start_with("bad \uFFFD byte")

      File.delete(File.join(Samagotchi::MemoryPaths.system_dir, "style.md"))
      expect(now_call.call(preload)["now"]).to eq("text" => nil, "diff" => nil, "gone" => true)
      # Chi's own text, an index: nothing to fetch.
      expect(now_call.call("base:base prompt")).not_to have_key("now")
      expect(now_call.call("indexes:system")).not_to have_key("now")
    end

    it "keeps a changed head's answer on &now=1: the source now, no diff (nothing sent to diff against)" do
      session = built_session(head: "an older head")
      body = call("/api/sessions/#{session.id}/working_set/part?key=identity:identity@system&now=1").last
      expect(body).to include("changed" => "idle")
      expect(body["now"]).to eq("text" => "I am chi.\n\n\n---\n\nModel-specific guidance (m):\nOverlay for m.", "gone" => false)
    end

    it "says gone when the memory left, and reads nothing for crafted params outside chi web's memories" do
      session = built_session(head: "an older head")
      File.delete(File.join(Samagotchi::MemoryPaths.system_dir, "style.md"))
      expect(part_call(session, keys[@built.prompt_parts.index(part_of("preloads"))]).last["now"]).to eq("text" => nil, "gone" => true)

      outside = File.join(tmpdir, "elsewhere").tap { |dir| FileUtils.mkdir_p(dir) }
      File.write(File.join(outside, "identity.md"), "secret\n")
      File.write(File.join(outside, "AGENTS.md"), "secret\n")
      crafted = session.prompt_parts.map do |part|
        case part.kind
        when "identity" then part.with(params: part.params.merge("system_dir" => outside, "project_dir" => File.join(outside, "p")))
        when "agents" then part.with(params: { "path" => File.join(outside, "AGENTS.md") })
        when "appended" then part
        else part
        end
      end
      session.prompt_parts = crafted
      session.save(state_dir: state_dir)
      identity = part_call(session, "identity:identity@system").last
      expect(identity).to include("changed" => "idle")
      expect(identity).not_to have_key("now")
      agents = part_call(session, keys[@built.prompt_parts.index(part_of("agents"))]).last
      expect(agents).not_to have_key("now")
    end

    it "never fetches an appended file" do
      extra = File.join(repo, "extra.md").tap { |file| File.write(file, "Extra.\n") }
      prompt_files = Samagotchi::SystemPrompt.new(profile: -> { Samagotchi::ModelProfile.gemma4 }, tools: -> { Samagotchi::Tools::Registry.new },
                                                  session: -> {}, thinking: -> { :off }, appended_files: [extra])
      @built = Dir.chdir(repo) { prompt_files.built_for(chat: true) }
      session = saved_session([{ role: "system", content: "changed" }]).tap do |saved|
        saved.prompt_parts = @built.prompt_parts
        saved.save(state_dir: state_dir)
      end
      body = part_call(session, "appended:#{extra}").last
      expect(body).to include("changed" => "idle")
      expect(body).not_to have_key("now")
    end
  end
end
