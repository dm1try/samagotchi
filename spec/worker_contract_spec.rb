# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/session_manager"
require "samagotchi/bridge"
require "samagotchi/client_id"

# A worker runs the NEWEST installed chi, whoever spawns it (an older chi
# web, chi send, --attach, a delegating parent): what an older chi writes, a
# newer one reads, and sessions on different versions talk to each other.
# These pins fail when one of those shared names changes. Change them only
# additively, and keep reading the old form (SessionManager.worker_command).
RSpec.describe "Cross-version worker contract" do
  it "boots through run_session_loop(id, state_dir:)" do
    params = Samagotchi::SessionManager.method(:run_session_loop).parameters
    expect(params).to include(%i[req session_id], %i[key state_dir])
    expect(params.select { |kind, _| %i[req keyreq].include?(kind) }).to eq([%i[req session_id]])
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

  # continues: an older chi's worker keeps only the FIELDS it knows when it
  # saves, so a field once written must stay one.
  it "keeps the session.json fields ReplyWait, DelegateWait and session chains read, and the stop marker" do
    expect(Samagotchi::Session::FIELDS.keys)
      .to include("status", "last_prompt", "pending_question", "last_turn", "messages", "parent_id", "continues")
    expect(Samagotchi::Session::STOPPED_FILE).to eq("stopped")
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

  it "keeps the routes and client ids one session's worker uses on another's" do
    expect(Samagotchi::Bridge::ROUTES).to include(%w[POST relay/status] => :handle_relay_status)
    expect(Samagotchi::Bridge::ROUTES.keys).to include(%w[POST relay])
    expect(Samagotchi::ClientId::CLI_ANSWER).to eq("cli:answer")
    expect(Samagotchi::ClientId::RELAY_PREFIX).to eq("relay:")
  end
end
