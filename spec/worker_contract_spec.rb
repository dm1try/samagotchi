# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/session_manager"
require "samagotchi/worker_boot"
require "samagotchi/starting_marker"
require "samagotchi/bridge"
require "samagotchi/client_id"

# A worker runs the NEWEST installed chi, whoever spawns it (an older chi
# web, chi send, --attach, a delegating parent): what an older chi writes, a
# newer one reads, and sessions on different versions talk to each other.
# These pins fail when one of those shared names changes. Change them only
# additively, and keep reading the old form (SessionManager.worker_command).
RSpec.describe "Cross-version worker contract" do
  # Every boot string names SessionManager.run_session_loop today; the
  # WorkerBoot one is the entry the string switches to.
  { "SessionManager" => -> { Samagotchi::SessionManager }, "WorkerBoot" => -> { Samagotchi::WorkerBoot } }
    .each do |name, entry|
    it "boots through #{name}.run_session_loop(id, state_dir:)" do
      params = entry.call.method(:run_session_loop).parameters
      expect(params).to include(%i[req session_id], %i[key state_dir])
      expect(params.select { |kind, _| %i[req keyreq].include?(kind) }).to eq([%i[req session_id]])
    end
  end

  it "forwards SessionManager.run_session_loop to WorkerBoot.run_session_loop, args and result" do
    allow(Samagotchi::WorkerBoot).to receive(:run_session_loop).and_return(:idle_exit)

    result = Samagotchi::SessionManager.run_session_loop("abc", state_dir: "/s", owner_wait: 0.5,
                                                                idle_exit_minutes: 2, poll_interval: 0.01)

    expect(result).to eq(:idle_exit)
    expect(Samagotchi::WorkerBoot).to have_received(:run_session_loop)
      .with("abc", state_dir: "/s", owner_wait: 0.5, idle_exit_minutes: 2, poll_interval: 0.01)
  end

  it "takes the env keys a spawner sets" do
    expect(Samagotchi::Config::ENTRIES.find { |e| e.key == "log.file" }.env_key).to eq("SAMAGOTCHI_LOG_FILE")
    expect(Samagotchi::Config::ENTRIES.find { |e| e.key == "log.disable" }.env_key).to eq("SAMAGOTCHI_LOG_DISABLE")
    expect(Samagotchi::SessionManager::BOOT_FALLBACK_ENV).to eq("SAMAGOTCHI_BOOT_FALLBACK")
    expect(Samagotchi::SessionManager::WORKER_PROCESS_ENV).to eq("SAMAGOTCHI_WORKER_PROCESS")
    expect(Samagotchi::SessionManager::WORKER_DETACH_ENV).to eq("SAMAGOTCHI_WORKER_DETACH")
    # The spawner's state and config dirs (spawn_options sets them absolute).
    expect(Samagotchi::Paths.state_home(env: { "XDG_STATE_HOME" => "/spawner/state" })).to eq("/spawner/state")
    expect(Samagotchi::Paths.config_home(env: { "XDG_CONFIG_HOME" => "/spawner/config" })).to eq("/spawner/config")
  end

  # A continue's starting marker: an older worker clears one a newer
  # continue wrote, and an older spawner reads it.
  it "writes the starting marker an older chi reads and clears (starting: {pid, at})" do
    expect(Samagotchi::StartingMarker::FILE).to eq("starting")
    Dir.mktmpdir do |dir|
      Samagotchi::StartingMarker.mark("abc", state_dir: dir)
      path = File.join(Samagotchi::Session.session_dir("abc", state_dir: dir), "starting")
      expect(JSON.parse(File.read(path)).keys).to contain_exactly("pid", "at")
    end
  end

  it "reads the input/ files an older chi writes (INPUT_FORMAT 3)" do
    expect(Samagotchi::SessionInbox::INPUT_FORMAT).to eq(3)
    Dir.mktmpdir do |dir|
      path = Samagotchi::SessionInbox.write_input(dir, prompt: "hi", client_id: "cli:send", enqueued_id: "e1",
                                                       no_interrupt: true, images: [{ file: "a.png", name: "a" }])
      expect(JSON.parse(File.read(path)).keys).to contain_exactly("prompt", "client_id", "enqueued_id", "no_interrupt",
                                                                  "images")
      expect(Samagotchi::SessionInbox.read_input(path))
        .to eq(Samagotchi::SessionInbox::Input.new(prompt: "hi", origin: { client_id: "cli:send", enqueued_id: "e1" },
                                                   no_interrupt: true, images: [{ file: "a.png", name: "a" }]))
    end
  end

  # continues: a chi up to 0.130.0 keeps only the FIELDS it knows when it
  # saves (a newer one keeps the rest, Session#extra_fields), so a field once
  # written must stay one.
  it "keeps the session.json fields ReplyWait, DelegateWait and session chains read, and the stop marker" do
    expect(Samagotchi::Session::FIELDS.keys)
      .to include("status", "last_prompt", "pending_question", "last_turn", "messages", "parent_id", "continues")
    expect(Samagotchi::Session::STOPPED_FILE).to eq("stopped")
  end

  # A newer chi's fields survive this one waking or saving the session (the
  # full round-trip: spec/session_spec.rb).
  it "keeps the session.json keys it doesn't know when it saves (from the release after 0.130.0)" do
    Dir.mktmpdir do |dir|
      id = "11111111-2222-3333-4444-555555555555"
      path = File.join(dir, "#{id}.json")
      File.write(path, JSON.generate("id" => id, "mode" => "assist", "model_name" => "m", "working_directory" => dir,
                                     "created_at" => "2026-01-01T00:00:00Z", "updated_at" => "2026-01-01T00:00:00Z",
                                     "future_field" => { "a" => 1 }))
      session = Samagotchi::Session.load(id, state_dir: dir)
      session.last_prompt = "hi"
      session.save(state_dir: dir)
      expect(JSON.parse(File.read(path))).to include("future_field" => { "a" => 1 }, "last_prompt" => "hi")
    end
  end

  # A later chi reads written_by to tell which chi saved the file last.
  it "names the chi that saved a session file in written_by" do
    expect(Samagotchi::Session::FIELDS.keys).to include("written_by")
  end

  # A continue moves a live delegate only when its worker reads parent.json
  # (ChildMove asks the sidecar for "reparent").
  it "keeps the parent.json override and names it in the sidecar's features" do
    expect(Samagotchi::Session::PARENT_FILE).to eq("parent.json")
    expect(Samagotchi::Bridge::FEATURES).to include("reparent", "restart", "task_stop")
  end

  # chi answer, chi send --wait (no message) and delegate_result trust a
  # turn's enqueued_id only from a worker that names "turn_ids".
  it "names turn_ids in the sidecar's features" do
    expect(Samagotchi::Bridge::FEATURES).to include(Samagotchi::ReplyWait::TURN_IDS_FEATURE)
    expect(Samagotchi::ReplyWait::TURN_IDS_FEATURE).to eq("turn_ids")
  end

  # A wait (ReplyWait::Poll#follow_merge) reads which turn took a merged
  # input from input/merged/<id>; a chi before it reads input/settled/<id>
  # as the turn's worker_stopped end, so a merge writes nothing there.
  it "records a merge in input/merged/<enqueued_id> as {into, at}, and nothing under input/settled/" do
    Dir.mktmpdir do |dir|
      Samagotchi::SessionInbox.mark_merged(dir, "m1", into: "host-1")

      expect(Samagotchi::SessionInbox::MERGED_DIR).to eq("merged")
      record = JSON.parse(File.read(File.join(dir, "input", "merged", "m1")))
      expect(record.keys).to contain_exactly("into", "at")
      expect(record["into"]).to eq("host-1")
      expect(Time.iso8601(record["at"])).to be_a(Time)
      expect(Dir.exist?(File.join(dir, "input", Samagotchi::TurnCheckpoint::SETTLED_DIR))).to be(false)
      expect(Samagotchi::TurnCheckpoint.settled_turn(dir, "m1")).to be_nil
    end
  end

  # A worker writes a finished turn's drawing; chi web reads it (a newer
  # one, an older one's file). A line another version wrote is skipped.
  it "writes turn_drawings.jsonl lines with v: 1 and these keys, from the end event's kept_from/kept_to" do
    drawings = Samagotchi::Bridge::TurnDrawings
    expect(drawings::FILE).to eq("turn_drawings.jsonl")
    expect(drawings::VERSION).to eq(1)
    expect(drawings::Line.members).to eq(%i[v turn_id kind from to from_digest to_digest drawing end])
    Dir.mktmpdir do |dir|
      messages = [{ role: "system", content: "head" }, { role: "user", content: "hi" }, { role: "model", content: "ok" }]
      drawings.new(path: File.join(dir, drawings::FILE), messages: -> { messages })
              .append({ prompt: "hi", parts: [] }, { type: :turn_completed, turn_id: "t1", kept_from: 1, kept_to: 3 })
      line = JSON.parse(File.read(File.join(dir, drawings::FILE)))
      expect(line.keys).to eq(%w[v turn_id kind from to from_digest to_digest drawing end])
      expect(line).to include("v" => 1, "from" => 1, "to" => 3)
    end
  end

  it "keeps the routes and client ids one session's worker uses on another's" do
    expect(Samagotchi::Bridge::ROUTES).to include(%w[POST relay/status] => :handle_relay_status)
    expect(Samagotchi::Bridge::ROUTES.keys).to include(%w[POST relay])
    expect(Samagotchi::ClientId::CLI_ANSWER).to eq("cli:answer")
    expect(Samagotchi::ClientId::RELAY_PREFIX).to eq("relay:")
  end
end
