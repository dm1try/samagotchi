
# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_manager"
require "samagotchi/reminder_store"

RSpec.describe Samagotchi::SessionManager do
  let(:tmpdir) { Dir.mktmpdir("session-manager-spec") }

  after { FileUtils.rm_rf(tmpdir) }

  # A stand-in worker: another process holding the owner lock (needs the
  # example group's session and session_dir).
  def spawn_owner(ignore_term: false)
    lib = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      require "samagotchi/owner_lock"
      trap("TERM") {} if #{ignore_term}
      lock = Samagotchi::OwnerLock.acquire(ARGV[0], kind: "worker")
      sleep 30
    RUBY
    @owner_pid = Process.spawn(RbConfig.ruby, "-I", lib, "-e", script, session_dir)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until described_class.session_owner(session.id, state_dir: tmpdir)
      raise "owner never took the lock" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end

  after do
    if @owner_pid
      begin
        Process.kill("KILL", @owner_pid)
      rescue Errno::ESRCH
        nil
      end
      begin
        Process.wait(@owner_pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end

  describe ".list_sessions" do
    it "returns all sessions" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)

      sessions = described_class.list_sessions(state_dir: tmpdir)
      expect(sessions.length).to eq(1)
      expect(sessions.first.status).to eq(Samagotchi::Session::STATUS_IDLE)
    end
  end

  describe ".stop_session" do
    it "marks a session as stopped even when pid file does not exist" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)

      described_class.stop_session(session.id, state_dir: tmpdir)
      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_STOPPED)
    end

    context "with wait:" do
      let(:session) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
          s.save(state_dir: tmpdir)
        end
      end
      let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

      it "returns true once the owner has let go of the session" do
        spawn_owner

        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 5)).to be true
        expect(described_class.session_owner(session.id, state_dir: tmpdir)).to be_nil
      end

      it "returns false when the owner outlives the wait" do
        spawn_owner(ignore_term: true)

        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 0.3)).to be false
        expect(described_class.session_owner(session.id, state_dir: tmpdir)).not_to be_nil
      end

      it "returns true at once when nothing owns the session" do
        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 5)).to be true
      end
    end

    context "mid-turn" do
      let(:session) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
          s.status = Samagotchi::Session::STATUS_RUNNING
          s.save(state_dir: tmpdir)
        end
      end
      let(:bridge) { instance_double(Samagotchi::BridgeClient) }
      let(:calls) { [] }

      before do
        allow(Samagotchi::BridgeClient).to receive(:discover).and_return(bridge)
        allow(Process).to receive(:kill).and_call_original
      end

      it "cancels the running turn first, so its prompt is saved as a Cancel saves it, then stops" do
        allow(bridge).to receive(:cancel) do |reason:|
          calls << [:cancel, reason, Samagotchi::Session.load(session.id, state_dir: tmpdir).status]
          # The worker's Engine ends the turn and saves the session.
          Thread.new do
            sleep 0.2
            loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
            loaded.status = Samagotchi::Session::STATUS_IDLE
            loaded.save(state_dir: tmpdir)
          end
          Samagotchi::BridgeClient::Response.new(status: 202, body: nil)
        end

        described_class.stop_session(session.id, state_dir: tmpdir, wait: 1)

        expect(calls).to eq([[:cancel, "user", Samagotchi::Session::STATUS_RUNNING]])
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq(Samagotchi::Session::STATUS_STOPPED)
      end

      it "stops at once when there is no turn to cancel" do
        allow(bridge).to receive(:cancel).and_return(Samagotchi::BridgeClient::Response.new(status: 409, body: nil))

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        described_class.stop_session(session.id, state_dir: tmpdir, wait: 1)

        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.5
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq(Samagotchi::Session::STATUS_STOPPED)
      end
    end
  end

  describe ".empty_session?" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

    def empty?(default_model: "gemma4")
      described_class.empty_session?(session.id, state_dir: tmpdir, default_model: default_model)
    end

    def change(&block)
      block.call(session)
      session.save(state_dir: tmpdir)
    end

    before do
      %w[input output notes images].each { |sub| FileUtils.mkdir_p(File.join(session_dir, sub)) }
      %w[pid owner.lock bridge.json].each { |name| File.write(File.join(session_dir, name), "") }
      File.write(File.join(session_dir, "analytics.json"), JSON.generate("turns" => 0, "turn_records" => []))
      File.write(File.join(session_dir, "output", "1.txt"), "")
    end

    it "is true for a fresh session on the default model, its directory the worker's skeleton" do
      expect(empty?).to be true
    end

    it "is false with no session file" do
      FileUtils.rm_f(File.join(tmpdir, "#{session.id}.json"))

      expect(empty?).to be false
    end

    it "is still true when the only message is a turn note (a first turn that failed before any answer)" do
      change { |s| s.messages << Samagotchi::TurnNote.message("the previous turn failed before any answer") }

      expect(empty?).to be true
    end

    it "is false once a context note is in the conversation" do
      change { |s| s.messages << { role: "system", content: "[note]", kind: "note" } }

      expect(empty?).to be false
    end

    it "is true with only the system prompt saved, false with a context note" do
      change { |s| s.messages << { role: "system", content: "You are chi." } }
      expect(empty?).to be true

      change { |s| s.messages << { role: "system", kind: "note", content: "from slack" } }
      expect(empty?).to be false
    end

    it "is false with a conversation" do
      change { |s| s.messages << { role: "user", content: "hi" } }

      expect(empty?).to be false
    end

    # 0 messages, but turns that failed: a last_prompt and analytics turns.
    it "is false after a failed turn" do
      change { |s| s.last_prompt = "can you see this?" }

      expect(empty?).to be false
    end

    it "is false when analytics recorded a turn" do
      File.write(File.join(session_dir, "analytics.json"), JSON.generate("turns" => 1, "turn_records" => [{ "id" => "t1" }]))

      expect(empty?).to be false
    end

    it "is false with a first prompt waiting for the worker" do
      change { |s| s.first_preview = "hello" }

      expect(empty?).to be false
    end

    it "is false on a model other than the default (/model, --model)" do
      expect(empty?(default_model: "qwen36")).to be false
    end

    it "is false with no default model to compare with" do
      expect(empty?(default_model: nil)).to be false
    end

    it "is false with memory attached or a question pending" do
      change { |s| s.used_memory_names = ["notes"] }
      expect(empty?).to be false

      change do |s|
        s.used_memory_names = []
        s.pending_question = { question: "which?" }
      end
      expect(empty?).to be false
    end

    it "is false with queued input, a note or an image" do
      %w[input notes images].each do |sub|
        path = File.join(session_dir, sub, "1.json")
        File.write(path, "{}")
        expect(empty?).to be(false), sub
        FileUtils.rm_f(path)
      end
      expect(empty?).to be true
    end

    it "is false with anything else in its directory" do
      File.write(File.join(session_dir, "approvals.json"), "{}")

      expect(empty?).to be false
    end

    it "is false for an unknown or unreadable session" do
      File.write(File.join(tmpdir, "#{session.id}.json"), "{")

      expect(empty?).to be false
      expect(described_class.empty_session?("nope", state_dir: tmpdir, default_model: "gemma4")).to be false
    end
  end

  describe ".discard_empty?" do
    it "is on unless session.keep_empty is set" do
      expect(described_class.discard_empty?).to be true

      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.keep_empty").and_return(true)
      expect(described_class.discard_empty?).to be false
    end
  end

  describe ".delete_session" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:session_file) { File.join(tmpdir, "#{session.id}.json") }

    def fill_session_dir
      %w[input output notes images].each { |sub| FileUtils.mkdir_p(File.join(session_dir, sub)) }
      File.write(File.join(session_dir, "notes", "1.json"), "{}")
      File.write(File.join(session_dir, "images", "ab.png"), "png")
      File.write(File.join(session_dir, "output", "1.txt"), "answer")
    end

    it "removes the session file and its whole directory, and says what it removed" do
      fill_session_dir

      result = described_class.delete_session(session.id, state_dir: tmpdir)

      expect(result).to eq(id: session.id, removed: [session_file, session_dir], stopped: false)
      expect(File.exist?(session_file)).to be false
      expect(Dir.exist?(session_dir)).to be false
    end

    it "removes the plugins' state for the session (plugins/<bundle>/sessions/<id>.json or <id>/), not another's" do
      plugins = File.join(Samagotchi::Paths.state_dir, "plugins")
      own = File.join(plugins, "check-in", "sessions", "#{session.id}.json")
      own_dir = File.join(plugins, "other", "sessions", session.id)
      kept = File.join(plugins, "check-in", "sessions", "someone-else.json")
      [own, kept].each { |f| FileUtils.mkdir_p(File.dirname(f)) && File.write(f, "{}") }
      FileUtils.mkdir_p(own_dir)

      described_class.delete_session(session.id, state_dir: tmpdir)

      expect([File.exist?(own), Dir.exist?(own_dir), File.exist?(kept)]).to eq([false, false, true])
    ensure
      FileUtils.rm_rf(plugins)
    end

    it "takes a unique id prefix" do
      result = described_class.delete_session(session.id[0, 6], state_dir: tmpdir)

      expect(result[:id]).to eq(session.id)
      expect(File.exist?(session_file)).to be false
    end

    it "refuses an ambiguous prefix and removes nothing" do
      now = Time.now.utc.iso8601
      Samagotchi::Session.new(id: "#{session.id[0, 4]}-other", mode: "assist", model_name: "gemma4",
                              working_directory: "/tmp", messages: [], created_at: now, updated_at: now)
                         .save(state_dir: tmpdir)

      expect { described_class.delete_session(session.id[0, 4], state_dir: tmpdir) }
        .to raise_error(Samagotchi::Session::AmbiguousId)
      expect(File.exist?(session_file)).to be true
    end

    it "refuses an unknown id, and one that is not an id" do
      FileUtils.mkdir_p(File.join(tmpdir, "keep"))

      expect { described_class.delete_session("nope", state_dir: tmpdir) }
        .to raise_error(ArgumentError, "no session nope")
      expect { described_class.delete_session("../#{File.basename(tmpdir)}", state_dir: tmpdir) }
        .to raise_error(ArgumentError, /no session/)
      expect { described_class.delete_session("", state_dir: tmpdir) }.to raise_error(ArgumentError)
      expect(Dir.exist?(File.join(tmpdir, "keep"))).to be true
    end

    it "refuses while a worker owns the session, and removes nothing" do
      fill_session_dir
      spawn_owner

      expect { described_class.delete_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:worker_running) }
      expect(File.exist?(session_file)).to be true
      expect(described_class.session_owner(session.id, state_dir: tmpdir)).not_to be_nil
    end

    it "with stop: stops the worker first, then deletes" do
      fill_session_dir
      spawn_owner

      result = described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 5)

      expect(result).to include(id: session.id, stopped: true)
      expect(File.exist?(session_file)).to be false
      expect(Dir.exist?(session_dir)).to be false
    end

    it "with stop: removes nothing when the worker outlives the wait" do
      spawn_owner(ignore_term: true)

      expect { described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 0.3) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:still_stopping) }
      expect(Dir.exist?(session_dir)).to be true
      expect(File.exist?(session_file)).to be true
    end

    it "refuses a session a chi REPL owns, even with stop:" do
      lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
      allow(Process).to receive(:kill)

      expect { described_class.delete_session(session.id, state_dir: tmpdir, stop: true) }
        .to raise_error(described_class::OwnedByTUI)
      expect(Process).not_to have_received(:kill)
      expect(File.exist?(session_file)).to be true
    ensure
      lock&.release
    end

    it "removes a directory left without its session file" do
      FileUtils.mkdir_p(session_dir)
      FileUtils.rm_f(session_file)

      expect(described_class.delete_session(session.id, state_dir: tmpdir)[:removed]).to eq([session_dir])
    end
  end

  describe ".resume_session" do
    it "wakes an idle session by spawning a worker" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_IDLE
      session.save(state_dir: tmpdir)
      allow(Process).to receive(:spawn).and_return(20_002)

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
      # A live worker is not a running turn: the worker marks its turns.
      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_IDLE)
    end

    it "clears a stopped or stale running status when it wakes a worker" do
      [Samagotchi::Session::STATUS_STOPPED, Samagotchi::Session::STATUS_ERROR, Samagotchi::Session::STATUS_RUNNING].each do |status|
        session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        session.status = status
        session.save(state_dir: tmpdir)
        allow(Process).to receive(:spawn).and_return(20_002)

        described_class.resume_session(session.id, state_dir: tmpdir)

        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq(Samagotchi::Session::STATUS_IDLE)
      end
    end

    it "removes the stop marker before it spawns the worker" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
      marker_at_spawn = nil
      allow(Process).to receive(:spawn) do
        marker_at_spawn = Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)
        20_002
      end

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(marker_at_spawn).to be(false)
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq(Samagotchi::Session::STATUS_IDLE)
    end

    describe "a worker it spawned that is still starting (no owner lock yet)" do
      let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap { |s| s.save(state_dir: tmpdir) } }
      let(:waiter) { instance_double(Thread, alive?: true) }

      before do
        allow(Process).to receive(:spawn).and_return(20_002)
        allow(Process).to receive(:detach).and_return(waiter)
      end

      after { described_class.forget_spawns }

      it "is not spawned again by a second resume (deliver_turn's after a slow start)" do
        2.times { described_class.resume_session(session.id, state_dir: tmpdir) }
        expect(Process).to have_received(:spawn).once
      end

      it "is spawned again once that worker exited, or after a stop" do
        described_class.resume_session(session.id, state_dir: tmpdir)
        allow(waiter).to receive(:alive?).and_return(false)
        described_class.resume_session(session.id, state_dir: tmpdir)
        expect(Process).to have_received(:spawn).twice

        allow(waiter).to receive(:alive?).and_return(true)
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        described_class.resume_session(session.id, state_dir: tmpdir)
        expect(Process).to have_received(:spawn).exactly(3).times
      end

      it "is spawned again after the grace" do
        described_class.resume_session(session.id, state_dir: tmpdir)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        allow(Process).to receive(:clock_gettime).and_call_original
        allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC)
                                                 .and_return(now + described_class::WORKER_START_GRACE + 1)
        described_class.resume_session(session.id, state_dir: tmpdir)
        expect(Process).to have_received(:spawn).twice
      end
    end
  end

  describe ".spawn_session" do
    it "refuses a model qualified with a host config.yml doesn't have, before anything is saved or spawned" do
      allow(Process).to receive(:spawn).and_return(12_345)
      stub_const("ENV", ENV.to_h.merge("SAMAGOTCHI_HOSTS_JSON" => JSON.generate("main" => { "host" => "localhost", "port" => 8080 })))

      expect { described_class.spawn_session(prompt: "hi", model_name: "nosuch:org/model", state_dir: tmpdir) }
        .to raise_error(Samagotchi::ModelProfile::UnknownHost, /unknown host 'nosuch'.*configured hosts are main/)
      expect(Process).not_to have_received(:spawn)
      expect(Dir.glob(File.join(tmpdir, "sessions", "*"))).to be_empty
    end

    it "starts a session with no prompt idle, with nothing to run" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_IDLE)
      expect(loaded.last_prompt.to_s).to eq("")
      expect(Process).to have_received(:spawn)
    end

    it "stores the --memory and --mute lists on the session before the worker starts" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = described_class.spawn_session(prompt: nil, model_name: "gemma4", state_dir: tmpdir,
                                              memories: ["cli_usage"], muted_memories: ["gh-helper"])

      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.preloaded_memory_names).to eq(["cli_usage"])
      expect(loaded.muted_memory_names).to eq(["gh-helper"])
    end

    it "stores the parent session's id before the worker starts" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = described_class.spawn_session(prompt: "look", model_name: "gemma4", state_dir: tmpdir,
                                              parent_id: "parent-1234")

      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).parent_id).to eq("parent-1234")
      expect(Samagotchi::Session.load(described_class.spawn_session(prompt: nil, model_name: "gemma4", state_dir: tmpdir).id,
                                      state_dir: tmpdir).parent_id).to be_nil
    end

    it "starts from a seed conversation, idle, titled, with the seed's images copied" do
      allow(Process).to receive(:spawn).and_return(12_345)
      parent_dir = File.join(tmpdir, "parent")
      FileUtils.mkdir_p(File.join(parent_dir, "images"))
      File.binwrite(File.join(parent_dir, "images", "0123456789abcdef.png"), "PNG")
      seed = [
        { role: "user", content: "look", images: [{ file: "images/0123456789abcdef.png", name: "a.png" },
                                                  { file: "images/fedcba9876543210.png", name: "gone.png" }] },
        { role: "model", content: "a cat" }
      ]

      session = described_class.spawn_session(prompt: nil, model_name: "gemma4", state_dir: tmpdir, parent_id: "p1",
                                              messages: seed, images_from: parent_dir, title: "btw: what is it?")

      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_IDLE)
      expect(loaded.first_preview).to eq("btw: what is it?")
      expect(loaded.messages).to eq([
        { role: "user", content: "look\n[image gone.png was not copied]",
          images: [{ file: "images/0123456789abcdef.png", name: "a.png" }] },
        { role: "model", content: "a cat" }
      ])
      expect(session.seed_images_dropped).to eq(1)
      child_dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      expect(File.binread(File.join(child_dir, "images", "0123456789abcdef.png"))).to eq("PNG")
    end

    it "previews a seeded session without a title by its first user message" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = described_class.spawn_session(prompt: nil, model_name: "gemma4", state_dir: tmpdir,
                                              messages: [{ role: "user", content: "the first question" }])

      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).first_preview).to eq("the first question")
    end

    it "records the first prompt as the preview, before the worker takes it" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = described_class.spawn_session(prompt: "  fix the\n  bug " + ("x" * 90), model_name: "gemma4", state_dir: tmpdir)

      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.first_preview).to eq("fix the bug #{"x" * 68}…")
    end

    it "hands the worker an idle exit set on the command line" do
      Samagotchi::Config.set_cli_overrides("session.idle_exit_minutes" => "0.5")
      spawned_env = nil
      allow(Process).to receive(:spawn) do |*args, **_opts|
        spawned_env = args.first if args.first.is_a?(Hash)
        12_345
      end

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES" => "0.5")
    ensure
      Samagotchi::Config.set_cli_overrides({})
    end

    # Its default for this run (the worker's /model reset), marked as the
    # CLI's so its execute children don't inherit it (Builtins.parent_env).
    it "hands the worker a --model as its default, marked as the command line's" do
      spawned = []
      allow(Process).to receive(:spawn) do |*args, **_opts|
        spawned << (args.first.is_a?(Hash) ? args.first : {})
        12_345
      end

      Samagotchi::Config.set_cli_overrides("default.model" => "gemma4")
      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)
      Samagotchi::Config.set_cli_overrides({})
      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned[0]).to include("SAMAGOTCHI_DEFAULT_MODEL" => "gemma4", "SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI" => "1")
      expect(spawned[1].keys).not_to include("SAMAGOTCHI_DEFAULT_MODEL", "SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI")
    ensure
      Samagotchi::Config.set_cli_overrides({})
    end

    describe "the worker's debug log" do
      def spawned_env
        env = nil
        allow(Process).to receive(:spawn) do |*args, **_opts|
          env = args.first if args.first.is_a?(Hash)
          12_345
        end
        described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", working_directory: tmpdir, state_dir: tmpdir)
        env
      end

      after { Samagotchi::Config.set_cli_overrides({}) }

      it "is the spawner's log.file, made absolute against the spawner's directory" do
        Samagotchi::Config.set_cli_overrides("log.file" => "logs/chi.log")

        # In tmpdir: the spawn itself is logged there.
        Dir.chdir(tmpdir) do
          expect(spawned_env).to include("SAMAGOTCHI_LOG_FILE" => File.join(Dir.pwd, "logs", "chi.log"))
        end
      end

      it "is disabled when the spawner's log is" do
        Samagotchi::Config.set_cli_overrides("log.disable" => true)

        expect(spawned_env).to include("SAMAGOTCHI_LOG_DISABLE" => "true")
        expect(spawned_env).not_to have_key("SAMAGOTCHI_LOG_FILE")
      end

      it "passes on a --log-level flag" do
        Samagotchi::Config.set_cli_overrides("log.level" => "debug")

        expect(spawned_env).to include("SAMAGOTCHI_LOG_LEVEL" => "debug")
      end

      # The worker reads config.yml itself when it starts: an edit made
      # after this process loaded the file reaches it, with origin :file.
      it "leaves config.yml's settings out of the worker's env" do
        Dir.mktmpdir("chi-config") do |dir|
          FileUtils.mkdir_p(File.join(dir, "samagotchi"))
          File.write(File.join(dir, "samagotchi", "config.yml"),
                     "default:\n  model: gemma4\nlog:\n  level: warn\nsession:\n  idle_exit_minutes: 3\nthinking:\n  level: low\n")
          stub_const("ENV", ENV.to_h.merge("XDG_CONFIG_HOME" => dir))

          env = spawned_env
          expect(env.keys).not_to include("SAMAGOTCHI_LOG_LEVEL", "SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES",
                                          "SAMAGOTCHI_DEFAULT_MODEL", "SAMAGOTCHI_THINKING_LEVEL")
        end
      end
    end

    # The spawner's environment must not switch the worker's guardrails off
    # (a parent agent starting or waking a session).
    it "unsets every SAMAGOTCHI_GUARDRAILS_* variable for the worker" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |*args, **_opts|
        spawned_env = args.first if args.first.is_a?(Hash)
        12_345
      end
      stub_const("ENV", ENV.to_h.merge("SAMAGOTCHI_GUARDRAILS_ENABLED" => "false",
                                       "SAMAGOTCHI_GUARDRAILS_SMALL_MODELS" => "", "SAMAGOTCHI_GUARDRAILS_X" => "1"))

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("SAMAGOTCHI_GUARDRAILS_ENABLED" => nil, "SAMAGOTCHI_GUARDRAILS_SMALL_MODELS" => nil,
                                     "SAMAGOTCHI_GUARDRAILS_X" => nil)
    end

    it "reaps the worker when it exits, so a long-lived spawner (chi web) keeps no zombies" do
      allow(Process).to receive(:spawn).and_return(12_345)
      allow(Process).to receive(:detach)

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(Process).to have_received(:detach).with(12_345)
    end

    it "keeps the spawner's SAMAGOTCHI_INSTALLED_VERSION seam from the worker" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |env, *_args, **_opts|
        spawned_env = env
        12_345
      end

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("SAMAGOTCHI_INSTALLED_VERSION" => nil)
    end

    it "undoes Bundler's env for a gem-mode worker, which activates the newest chi itself" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |env, *_args, **_opts|
        spawned_env = env
        12_345
      end
      allow(Samagotchi::InstalledGem).to receive(:spec)
        .and_return(Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "9.9.9" })
      stub_const("ENV", ENV.to_h.merge("RUBYOPT" => "-W0 -rbundler/setup", "BUNDLE_GEMFILE" => "/p/Gemfile"))
      allow(Bundler).to receive(:unbundled_env).and_return(ENV.to_h.merge("RUBYOPT" => "-W0").except("BUNDLE_GEMFILE"))

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("RUBYOPT" => "-W0", "BUNDLE_GEMFILE" => nil)
    end

    it "leaves Bundler's env to a source checkout's worker (bundle exec bin/chi)" do
      spawned_env = nil
      allow(Process).to receive(:spawn) do |env, *_args, **_opts|
        spawned_env = env
        12_345
      end
      stub_const("ENV", ENV.to_h.merge("BUNDLE_GEMFILE" => "/p/Gemfile"))

      described_class.spawn_session(prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).not_to have_key("BUNDLE_GEMFILE")
    end

    it "spawns worker with explicit require for session manager" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      allow(Samagotchi::Session).to receive(:new_session).and_return(session)
      spawned_args = nil
      allow(Process).to receive(:spawn) do |*args|
        spawned_args = args
        12_345
      end

      described_class.spawn_session(prompt: "hello", mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
      args_str = spawned_args.map(&:to_s).join(" ")
      expect(args_str).to include("require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop")
      expect(spawned_args).to include(RbConfig.ruby)
      expect(spawned_args).to include("-I")

      lib_path_index = spawned_args.index("-I") + 1
      expect(spawned_args[lib_path_index]).to end_with("/lib")
      expect(File.directory?(spawned_args[lib_path_index])).to be true
    end

    describe "the worker command" do
      let(:boot) { "require 'samagotchi/session_manager'; Samagotchi::SessionManager.run_session_loop('abc', state_dir: \"/s\")" }

      it "is a plain -I lib from a source checkout (this suite runs from one, under Bundler's gemspec)" do
        expect(Samagotchi::InstalledGem.spec).to be_nil
        expect(described_class.worker_command("abc", state_dir: "/s"))
          .to eq([RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", boot])
      end

      it "activates the newest installed gem, falling back to the spawner's own version, without -I" do
        spec = Gem::Specification.new { |s| s.name = "samagotchi"; s.version = "9.9.9" }
        command = described_class.worker_command("abc", state_dir: "/s", gem_spec: spec)
        expect(command).to eq([RbConfig.ruby, "-e",
                               "begin; gem 'samagotchi', '>= 0.a'; rescue LoadError => e; " \
                               "ENV['SAMAGOTCHI_BOOT_FALLBACK'] = e.message; gem 'samagotchi', '= 9.9.9'; end; #{boot}"])
      end
    end

    it "starts the worker in its own process group, so a Ctrl-C on `chi web` does not reach it" do
      spawned_opts = nil
      allow(Process).to receive(:spawn) do |*args, **opts|
        spawned_opts = opts
        12_345
      end

      described_class.spawn_session(prompt: "hello", mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_opts).to include(pgroup: true)
    end
  end

  describe "the worker's directory" do
    def spawned_opts
      opts = nil
      allow(Process).to receive(:spawn) do |*_args, **o|
        opts = o
        12_345
      end
      yield
      opts
    end

    it "writes the spawn to the log, with the session's sid and the worker's pid" do
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Config.set_cli_overrides("log.file" => log)
      session = nil
      spawned_opts { session = described_class.spawn_session(prompt: nil, model_name: "gemma4", working_directory: tmpdir, state_dir: tmpdir) }

      record = File.open(log) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.event == "spawn" } }
      expect(record.to_h).to include(level: "INFO", tag: "worker", sid: session.id[0, 8], fields: { "child_pid" => "12345" })
    ensure
      Samagotchi::Config.set_cli_overrides({})
    end

    it "starts the worker in the session's directory, so its tools run there" do
      dir = Dir.mktmpdir("session-dir", tmpdir)

      opts = spawned_opts { described_class.spawn_session(prompt: nil, model_name: "gemma4", working_directory: dir, state_dir: tmpdir) }

      expect(opts).to include(chdir: dir)
    end

    it "falls back to the spawner's directory, with a log line, when the session's is gone" do
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Config.set_cli_overrides("log.file" => log)
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: File.join(tmpdir, "gone"))
      session.save(state_dir: tmpdir)

      opts = spawned_opts { described_class.resume_session(session.id, state_dir: tmpdir) }

      expect(opts).not_to have_key(:chdir)
      record = File.open(log) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.event == "cwd_gone" } }
      expect(record.to_h).to include(level: "WARN", tag: "worker", sid: session.id[0, 8])
      expect(record.fields).to eq("dir" => File.join(tmpdir, "gone"), "cwd" => Dir.pwd)
    ensure
      Samagotchi::Config.set_cli_overrides({})
    end
  end

  describe "single owner" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

    after { @lock&.release }

    it "does not spawn a second worker while one owns the session" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      allow(Process).to receive(:spawn)

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).not_to have_received(:spawn)
    end

    it "spawns a worker when the last owner is gone, even if its pid was reused" do
      Samagotchi::OwnerLock.acquire(session_dir, kind: "worker").release
      File.write(File.join(session_dir, "pid"), Process.pid.to_s)
      allow(Process).to receive(:spawn).and_return(20_003)

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
    end

    it "counts a session with only a pid file (no lock) as not owned, even when that pid is alive" do
      FileUtils.mkdir_p(session_dir)
      File.write(File.join(session_dir, "pid"), Process.pid.to_s)
      allow(Process).to receive(:spawn).and_return(20_004)

      expect(described_class.session_owner(session.id, state_dir: tmpdir)).to be_nil
      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Process).to have_received(:spawn)
    end

    it "refuses to resume, write input for, or stop a session the interactive TUI owns" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
      allow(Process).to receive(:spawn)
      allow(Process).to receive(:kill)

      expect { described_class.resume_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::OwnedByTUI)
      expect { described_class.stop_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::OwnedByTUI)
      expect(Process).not_to have_received(:spawn)
      expect(Process).not_to have_received(:kill)
      expect(described_class.session_owner(session.id, state_dir: tmpdir)).to have_attributes(kind: "tui")
    end

    it "lets only one of two contending workers run the session" do
      @lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "worker")
      expect(Samagotchi::Engine).not_to receive(:new)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir, owner_wait: 0.1)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "decides the worker's exit: 0 on a stop, without resuming for queued input or discarding; 1 on a crash" do
      described_class.write_turn_input(session.id, prompt: "queued", state_dir: tmpdir)
      allow(described_class).to receive(:resume_session)
      allow(described_class).to receive(:discardable?).and_return(true)
      allow_any_instance_of(Samagotchi::Worker).to receive(:run).and_return(:stopped)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
      expect(described_class).not_to have_received(:resume_session)
      expect(described_class).not_to have_received(:discardable?)
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil

      allow_any_instance_of(Samagotchi::Worker).to receive(:run).and_return(:crashed)
      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end

    it "does not run the initial prompt of a session stopped before the worker took it, nor its plugins' init tasks" do
      session.last_prompt = "hello"
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      expect(engine).not_to receive(:run_turn)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
      expect(engine).to have_received(:announce_load_events!)
      expect(engine).not_to have_received(:start_init_tasks!)
    end

    it "records the worker as owner, with its own pid, while it runs, and writes no pid file" do
      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      owner_seen = nil
      pid_seen = nil
      allow(Samagotchi::Engine).to receive(:new) do
        owner_seen = Samagotchi::OwnerLock.owner(session_dir)
        pid_seen = File.exist?(File.join(session_dir, "pid"))
        engine
      end
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        []
      end

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir, poll_interval: 0.01)
      }.to raise_error(SystemExit)

      expect(owner_seen).to have_attributes(kind: "worker", pid: Process.pid)
      expect(pid_seen).to be(false)
      # Released on the way out.
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil
    end
  end

  describe ".restart_session" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
                         .tap { |s| s.save(state_dir: tmpdir) }
    end
    let(:worker) { Samagotchi::OwnerLock::Owner.new(kind: "worker", pid: 1, started_at: nil) }
    let(:old_sidecar) do
      Samagotchi::WorkerSidecar.new(port: 4100, started_at: "t1", version: "0.18.1", features: ["restart"])
    end
    let(:client) { instance_double(Samagotchi::BridgeClient) }

    def response(status, body)
      Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(body))
    end

    before do
      allow(described_class).to receive(:session_owner).and_return(worker)
      allow(Samagotchi::BridgeClient).to receive(:new).with(session_id: session.id, port: 4100).and_return(client)
    end

    it "asks the worker for a restart and waits for its successor's Bridge" do
      fresh = old_sidecar.with(port: 4200, started_at: "t2", version: "0.19.0")
      allow(Samagotchi::WorkerSidecar).to receive(:live).and_return(old_sidecar, old_sidecar, nil, fresh)
      allow(client).to receive(:request_exit).and_return(response(200, status: "restarting"))

      result = described_class.restart_session(session.id, state_dir: tmpdir, wait: 2, client_id: "web:restart")

      expect(client).to have_received(:request_exit).with(client_id: "web:restart", restart: true)
      expect(result.to_h).to eq(session_id: session.id, from_version: "0.18.1", version: "0.19.0")
    end

    it "gives no version when the successor didn't come up within the wait" do
      allow(Samagotchi::WorkerSidecar).to receive(:live).and_return(old_sidecar)
      allow(client).to receive(:request_exit).and_return(response(200, status: "restarting"))

      expect(described_class.restart_session(session.id, state_dir: tmpdir, wait: 0.2).version).to be_nil
    end

    it "is refused with the worker's reason" do
      allow(Samagotchi::WorkerSidecar).to receive(:live).and_return(old_sidecar)
      allow(client).to receive(:request_exit).and_return(response(409, status: "held", reason: "reminders"))

      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused, "not now: it has reminders, which a restart would drop") { |e|
          expect(e.reason).to eq(:reminders)
        }
    end

    it "is refused for a worker from before restarts, which it never asks" do
      allow(Samagotchi::WorkerSidecar).to receive(:live).and_return(old_sidecar.with(features: []))
      allow(client).to receive(:request_exit)

      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused, /runs chi 0.18.1, which can't restart: chi sessions stop/)
      expect(client).not_to have_received(:request_exit)
    end

    it "is refused with no live worker, and raises OwnedByTUI for a REPL's session" do
      allow(described_class).to receive(:session_owner).and_return(nil)
      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused) { |e| expect(e.reason).to eq(:not_running) }

      allow(described_class).to receive(:session_owner).and_return(Samagotchi::OwnerLock::Owner.new(kind: "tui", pid: 1, started_at: nil))
      expect { described_class.restart_session(session.id, state_dir: tmpdir) }.to raise_error(described_class::OwnedByTUI)
    end
  end

  describe ".run_session_loop" do
    it "starts the next worker after a restart, once its lock is free, and never discards the session" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      worker = instance_double(Samagotchi::Worker, run: :restart, discard?: false)
      allow(Samagotchi::Worker).to receive(:new).and_return(worker)
      owner_at_resume = :unset
      allow(described_class).to receive(:resume_session) do |id, state_dir:|
        owner_at_resume = described_class.session_owner(id, state_dir: state_dir)
      end
      allow(described_class).to receive(:delete_session)

      expect(described_class.run_session_loop(session.id, state_dir: tmpdir)).to eq(:restart)
      expect(described_class).to have_received(:resume_session).with(session.id, state_dir: tmpdir)
      expect(owner_at_resume).to be_nil
      expect(described_class).not_to have_received(:delete_session)
    end

    it "logs a worker crash with its backtrace (its stderr is /dev/null) and re-raises" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Config.set_cli_overrides("log.file" => log)
      worker = instance_double(Samagotchi::Worker)
      allow(worker).to receive(:run).and_raise(NoMethodError, "undefined method 'x'")
      allow(Samagotchi::Worker).to receive(:new).and_return(worker)

      expect { described_class.run_session_loop(session.id, state_dir: tmpdir) }
        .to raise_error(NoMethodError)

      records = File.open(log) { |io| Samagotchi::LogLine.each_record(io).to_a }
      expect(records.map(&:event)).to eq(%w[start crashed])
      expect(records.last.to_h).to include(level: "ERROR", tag: "worker", sid: session.id[0, 8])
      expect(records.last.fields).to include("error" => "NoMethodError")
      expect(records.last.payload.lines.size).to be_between(1, 20)
    ensure
      Samagotchi::Config.set_cli_overrides({})
    end

    it "initializes Engine with supported keywords" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      expect(Samagotchi::Engine).to receive(:new)
        .with(hash_including(model_name: "gemma4"))
        .and_return(engine)

      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      # The worker always starts its Bridge, which subscribes a capture observer.
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "leaves the idle recap to the config (the web and attached UIs show :recap_ready)" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      expect(Samagotchi::Engine).to receive(:new) do |**kwargs|
        expect(kwargs).not_to have_key(:recap)
        engine
      end
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "hands the Engine its session before any turn, so a joining UI sees the history" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "reply" }]
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], start_idle: nil, stop_idle: nil, reminder_store: nil,
                                              turn_running?: false, last_activity_at: 0.0)
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      given = nil
      allow(engine).to receive(:session=) { |s| given = s }
      bridge_started = false
      allow(described_class).to receive(:start_bridge) do
        bridge_started = true
        expect(given).not_to be_nil
        nil
      end
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        []
      end

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir, poll_interval: 0.01)
      }.to raise_error(SystemExit)

      expect(bridge_started).to be(true)
      expect(given.id).to eq(session.id)
      expect(given.messages.map { |m| m[:content] || m["content"] }).to eq(%w[earlier reply])
    end

    it "wires a reminder callback that notes the due reminders for a reminder turn, with no input file" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_STOPPED
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      reminder_callback = nil
      allow(Samagotchi::Engine).to receive(:new) do |**kwargs|
        reminder_callback = kwargs.dig(:reminders, :callback)
        engine
      end
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)

      expect(engine).to receive(:note_due_reminders).with(["daily"])
      expect { reminder_callback.call(["daily"]) }.not_to raise_error
      input_dir = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), Samagotchi::SessionInbox::INPUT_DIR)
      expect(Dir.glob(File.join(input_dir, "*"))).to be_empty
    end

    it "atomically claims an input file for single-consumer processing" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      input_dir = File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR)
      FileUtils.mkdir_p(input_dir)

      input_file = File.join(input_dir, "20260101000000000000000.txt")
      File.write(input_file, "ping")

      claimed = Samagotchi::SessionInbox.claim_input_file(input_file)

      expect(File.exist?(input_file)).to be false
      expect(claimed).to end_with(".processing")
      expect(File.read(claimed)).to eq("ping")

      FileUtils.rm_f(claimed)
      expect(Dir.glob(File.join(input_dir, "*")).length).to eq(0)
    end

    it "processes prompts through Engine public background API" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.last_prompt = "hello"
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, messages_checkpoint: [])
      result = instance_double(Samagotchi::LLM::ModelResult, output: "hi", canceled?: false, resumable?: false)
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      # The worker always starts its Bridge, which subscribes a capture observer.
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)
      expect(engine).to receive(:run_turn)
        .with(instance_of(Samagotchi::Session), "hello", pending_input: kind_of(Proc), origin: nil, max_iterations: 100, images: []) do
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
          result
        end

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "does not replay the last prompt when resuming a session with history" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.messages = [{ role: "user", content: "earlier" }, { role: "model", content: "answer" }]
      session.last_prompt = "earlier"
      session.save(state_dir: tmpdir)

      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0)
      sub_handle = double("subscribe_handle")
      allow(sub_handle).to receive(:unsubscribe)
      allow(engine).to receive(:subscribe).and_return(sub_handle)
      expect(engine).not_to receive(:run_turn)
      # Stop on the first poll so the loop exits.
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        []
      end

      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir, poll_interval: 0.01)
      }.to raise_error(SystemExit)
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).last_prompt).to eq("earlier")
    end
  end

  describe "idle exit" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:sidecar) { File.join(session_dir, "bridge.json") }
    let(:reminders) { Samagotchi::ReminderStore.new }
    let(:engine) do
      instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil,
                                          reminder_store: reminders, turn_running?: false, last_activity_at: 0.0,
                                          messages_checkpoint: [], used_memory_names: [], write_recap_now: nil)
    end

    before do
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(engine).to receive(:synchronize_events) { |&block| block.call }
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    end

    def run_worker
      described_class.run_session_loop(session.id, state_dir: tmpdir, idle_exit_minutes: 0.002, poll_interval: 0.01)
    end

    def input_files
      Dir.glob(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR, "*.json"))
    end

    it "returns once nobody has used the worker for the timeout, freeing the session" do
      sidecar_seen = nil
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files).and_wrap_original do |original, *args|
        sidecar_seen ||= File.exist?(sidecar)
        original.call(*args)
      end

      expect(run_worker).to eq(:idle_exit)

      expect(sidecar_seen).to be(true)
      expect(File.exist?(sidecar)).to be(false)
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil
      expect(engine).to have_received(:stop_idle)
    end

    it "stays up while a reminder is registered" do
      reminders.register(name: "stretch", description: "Remind me to stretch", interval_minutes: 60)
      polls = 0
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files).and_wrap_original do |original, *args|
        polls += 1
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if polls == 60
        original.call(*args)
      end

      expect { run_worker }.to raise_error(SystemExit)
      expect(polls).to be >= 60
    end

    it "stays up for input that came in while it checked with the event log held" do
      calls = 0
      allow(engine).to receive(:synchronize_events) do |&block|
        calls += 1
        described_class.write_turn_input(session.id, prompt: "late", state_dir: tmpdir) if calls == 1
        block.call
      end
      allow(engine).to receive(:run_turn) do
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        nil
      end

      expect { run_worker }.to raise_error(SystemExit)
      expect(engine).to have_received(:run_turn).with(anything, "late", hash_including(:pending_input))
    end

    it "wakes a new worker for input queued after its last check" do
      # Written after the check, while this worker still holds the lock.
      allow(engine).to receive(:stop_idle) do
        described_class.write_turn_input(session.id, prompt: "late", state_dir: tmpdir)
      end
      allow(Process).to receive(:spawn).and_return(40_004)

      expect(run_worker).to eq(:idle_exit)

      expect(Process).to have_received(:spawn)
      expect(input_files.size).to eq(1)
    end

    it "wakes a new worker for input queued as it left on a client's request too" do
      allow_any_instance_of(Samagotchi::Worker).to receive(:run) do
        described_class.write_turn_input(session.id, prompt: "late", state_dir: tmpdir)
        :exit_requested
      end
      allow(Process).to receive(:spawn).and_return(40_005)

      expect(run_worker).to eq(:exit_requested)

      expect(Process).to have_received(:spawn)
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil
    end

    describe "an empty session" do
      let(:session) do
        model = Samagotchi::ModelProfile.required_model_name(nil)
        Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: "/tmp").tap do |s|
          s.save(state_dir: tmpdir)
        end
      end
      let(:session_file) { File.join(tmpdir, "#{session.id}.json") }

      it "is deleted once its worker left it" do
        expect(run_worker).to eq(:idle_exit)

        expect(File.exist?(session_file)).to be(false)
        expect(Dir.exist?(session_dir)).to be(false)
      end

      it "is deleted when it left on a client's request too" do
        allow_any_instance_of(Samagotchi::Worker).to receive(:discard?).and_return(true)
        allow_any_instance_of(Samagotchi::Worker).to receive(:default_model).and_return(session.model_name)
        allow_any_instance_of(Samagotchi::Worker).to receive(:run).and_return(:exit_requested)

        run_worker

        expect(File.exist?(session_file)).to be(false)
      end

      it "is kept with a conversation" do
        session.messages << { role: "user", content: "hi" }
        session.save(state_dir: tmpdir)

        run_worker

        expect(File.exist?(session_file)).to be(true)
      end

      it "is kept on another model (/model)" do
        session.model_name = "some/other-model"
        session.save(state_dir: tmpdir)

        run_worker

        expect(File.exist?(session_file)).to be(true)
      end

      it "is kept with memory the engine used before any turn saved it" do
        allow(engine).to receive(:used_memory_names).and_return(["notes"])

        run_worker

        expect(File.exist?(session_file)).to be(true)
      end

      it "is kept with session.keep_empty" do
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("session.keep_empty").and_return(true)

        run_worker

        expect(File.exist?(session_file)).to be(true)
      end

      it "is kept when a note came in after the worker looked" do
        allow(engine).to receive(:stop_idle) do
          Samagotchi::SessionInbox.write_note(session.id, text: "later", state_dir: tmpdir)
        end

        expect(run_worker).to eq(:idle_exit)

        expect(File.exist?(session_file)).to be(true)
      end

      it "is kept when another owner took it after the worker left" do
        allow(described_class).to receive(:session_owner).and_call_original
        allow(described_class).to receive(:session_owner).with(session.id, state_dir: tmpdir)
                                                         .and_return(Samagotchi::OwnerLock::Owner.new(kind: "worker", pid: 1, started_at: nil))

        run_worker

        expect(File.exist?(session_file)).to be(true)
      end
    end
  end

  describe ".deliver_turn" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:locks) { [] }

    after { locks.each(&:release) }

    def input_files
      Dir.glob(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR, "*"))
    end

    def own(kind)
      locks << Samagotchi::OwnerLock.acquire(session_dir, kind: kind)
    end

    it "posts through a live Bridge and writes no file" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient)
      allow(bridge).to receive(:post_turn).with(prompt: "hi", client_id: "cli:send").and_return(
        Samagotchi::BridgeClient::Response.new(status: 202, body: '{"status":"accepted","enqueued_id":"e1","session_id":"s"}')
      )

      result = described_class.deliver_turn(session.id, prompt: "hi", client_id: "cli:send", state_dir: tmpdir, bridge: -> { bridge })

      expect(result).to eq(status: :accepted, ack: { "status" => "accepted", "enqueued_id" => "e1", "session_id" => "s" })
      expect(input_files).to be_empty
    end

    it "falls back to the input file when the Bridge refuses the connection" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient)
      allow(bridge).to receive(:post_turn).and_raise(Errno::ECONNREFUSED)

      result = described_class.deliver_turn(session.id, prompt: "hi", client_id: "cli:send", state_dir: tmpdir, bridge: -> { bridge })

      expect(result).to match(status: :accepted, ack: { status: "accepted", enqueued_id: kind_of(String), session_id: session.id })
      expect(input_files.map { |path| JSON.parse(File.read(path)) })
        .to eq([{ "prompt" => "hi", "client_id" => "cli:send", "enqueued_id" => result[:ack][:enqueued_id] }])
    end

    it "queues the input file when nothing listens on the Bridge's port" do
      own("worker")
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      client = Samagotchi::BridgeClient.new(session_id: session.id, port: port, read_timeout: 0.3)

      result = described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { client })

      expect(result[:status]).to eq(:accepted)
      expect(input_files.size).to eq(1)
    end

    # The Bridge got to the request only after its deadline (a slow worker,
    # a clock step): the turn was dropped, so it is a timeout, and a file
    # would run it after all.
    it "reports a timeout and queues nothing when the Bridge dropped the turn as past its deadline" do
      own("worker")
      bridge = instance_double(Samagotchi::BridgeClient)
      reply = Samagotchi::BridgeClient::Response.new(status: 408, body: '{"error":"deadline_passed"}')
      allow(bridge).to receive(:post_turn).and_return(reply)

      result = described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { bridge })

      expect(result).to match(status: :timeout, ack: { "error" => "worker_timeout", "detail" => "the session's worker did not answer, so the message was not sent" })
      expect(input_files).to be_empty
    end

    it "reports a timeout and queues nothing when the Bridge takes the request but never answers" do
      own("worker")
      server = TCPServer.new("127.0.0.1", 0)
      accepted = []
      acceptor = Thread.new { loop { accepted << server.accept } }
      client = Samagotchi::BridgeClient.new(session_id: session.id, port: server.addr[1], read_timeout: 0.3)

      result = described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { client })

      expect(result).to match(status: :timeout, ack: { "error" => "worker_timeout", "detail" => "the session's worker did not answer, so the message was not sent" })
      expect(input_files).to be_empty
    ensure
      acceptor&.kill
      accepted&.each(&:close)
      server&.close
    end

    it "withdraws the file and raises OwnedByTUI when a TUI took the session after the write" do
      allow(Process).to receive(:spawn).and_return(20_002)
      bridge = lambda do
        own("tui")
        nil
      end

      expect do
        described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: bridge)
      end.to raise_error(described_class::OwnedByTUI)
      expect(input_files).to be_empty
    end

    it "wakes a worker for a session nobody owns" do
      allow(Process).to receive(:spawn).and_return(20_002)

      result = described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> {})

      expect(result[:status]).to eq(:accepted)
      # Once by the resume, once more since still nobody owns it after the write.
      expect(Process).to have_received(:spawn).twice
      expect(input_files.size).to eq(1)
    end

    it "raises OwnedByTUI up front for a REPL-owned session and queues nothing" do
      own("tui")

      expect do
        described_class.deliver_turn(session.id, prompt: "hi", state_dir: tmpdir, bridge: -> { raise "not reached" })
      end.to raise_error(described_class::OwnedByTUI)
      expect(input_files).to be_empty
    end
  end

  describe "structured input" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:input_dir) { File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR) }

    def write_sidecar(record)
      FileUtils.mkdir_p(session_dir)
      File.write(File.join(session_dir, "bridge.json"), JSON.generate(record))
    end

    it "writes a JSON input file carrying the sender's ids" do
      path = described_class.write_turn_input(session.id, prompt: "hi", client_id: "web:1", enqueued_id: "e1", state_dir: tmpdir)

      expect(path).to end_with(".json")
      expect(JSON.parse(File.read(path))).to eq("prompt" => "hi", "client_id" => "web:1", "enqueued_id" => "e1")
    end

    it "writes JSON whatever input format the sidecar advertises (no worker from before format 2 or 3 is left)" do
      [{}, { "input_format" => 2 }].each do |advertised|
        write_sidecar({ "port" => 1, "session_id" => session.id }.merge(advertised))

        path = described_class.write_turn_input(session.id, prompt: "hi", client_id: "web:1", state_dir: tmpdir)

        expect(JSON.parse(File.read(path))).to eq("prompt" => "hi", "client_id" => "web:1")
      end
    end

    def run_worker_with(engine)
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:reminder_store).and_return(nil)
      allow(engine).to receive_messages(turn_running?: false, last_activity_at: 0.0, messages_checkpoint: [])
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      expect {
        described_class.run_session_loop(session.id, state_dir: tmpdir)
      }.to raise_error(SystemExit)
    end

    it "runs queued turns with their origin, or none" do
      described_class.write_turn_input(session.id, prompt: "from web", client_id: "web:1", enqueued_id: "e1", state_dir: tmpdir)
      described_class.write_turn_input(session.id, prompt: "plain", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, origin:, **|
        runs << [prompt, origin]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if runs.size == 2
        instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false)
      end

      run_worker_with(engine)

      expect(runs).to eq([["from web", { client_id: "web:1", enqueued_id: "e1" }], ["plain", nil]])
    end

    it "runs a turn queued with no_interrupt under the raised iteration limit" do
      described_class.write_turn_input(session.id, prompt: "long", client_id: "tui:1", no_interrupt: true, state_dir: tmpdir)
      described_class.write_turn_input(session.id, prompt: "short", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, max_iterations:, **|
        runs << [prompt, max_iterations]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if runs.size == 2
        instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false)
      end

      run_worker_with(engine)

      expect(runs).to eq([["long", 1000], ["short", 100]])
    end

    it "marks the session running on disk while a turn runs, and stops before the next queued turn" do
      described_class.write_turn_input(session.id, prompt: "one", state_dir: tmpdir)
      described_class.write_turn_input(session.id, prompt: "two", state_dir: tmpdir)
      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      runs = []
      allow(engine).to receive(:run_turn) do |_session, prompt, **|
        runs << [prompt, Samagotchi::Session.load(session.id, state_dir: tmpdir).status]
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false)
      end

      run_worker_with(engine)

      expect(runs).to eq([%w[one running]])
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq("stopped")
      # Still queued for whoever resumes the session.
      expect(Dir.children(input_dir).map { |f| JSON.parse(File.read(File.join(input_dir, f)))["prompt"] }).to eq(["two"])
    end

    it "announces who sent input merged into a running turn" do
      engine = instance_double(Samagotchi::Engine, command_registry: Samagotchi::SessionCommands.builtin_registry, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, "interface=": nil, recap: nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, due_reminder_names: [], "session=": nil)
      announced = []
      allow(engine).to receive(:announce) { |event| announced << event }
      drained = nil
      described_class.write_turn_input(session.id, prompt: "first", state_dir: tmpdir)
      allow(engine).to receive(:run_turn) do |_session, _prompt, pending_input:, **|
        described_class.write_turn_input(session.id, prompt: "steer", client_id: "tui:1", enqueued_id: "e2", state_dir: tmpdir)
        drained = pending_input.call
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false)
      end

      run_worker_with(engine)

      expect(drained).to eq(["steer"])
      expect(announced).to eq([{ type: :input_merged, count: 1, origins: [{ client_id: "tui:1", enqueued_id: "e2" }] }])
    end
  end

  describe ".read_responses" do
    it "only returns outputs strictly newer than since_time" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      output_dir = File.join(session_dir, Samagotchi::SessionInbox::OUTPUT_DIR)
      FileUtils.mkdir_p(output_dir)

      old_file = File.join(output_dir, "old.txt")
      new_file = File.join(output_dir, "new.txt")
      File.write(old_file, "old")
      boundary = Time.now
      sleep(0.01)
      File.write(new_file, "new")

      responses = described_class.read_responses(session.id, since_time: boundary, state_dir: tmpdir)
      expect(responses).to eq(["new"])
    end
  end

  describe ".session_summaries" do
    let(:locks) { [] }

    after { locks.each(&:release) }

    def make(cwd: "/work/app", prompt: "hello", updated: "2026-09-24T10:00:00Z", status: nil, test_run: false, preview: "",
             parent_id: nil)
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd).tap do |s|
        s.last_prompt = prompt
        s.parent_id = parent_id
        s.first_preview = preview
        s.status = status if status
        s.test_run = test_run
        s.save(state_dir: tmpdir)
        # save stamps updated_at; set it after for a fixed order
        data = JSON.parse(File.read(File.join(tmpdir, "#{s.id}.json")))
        File.write(File.join(tmpdir, "#{s.id}.json"), JSON.generate(data.merge("updated_at" => updated)))
      end
    end

    def own(session, kind: "worker")
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: kind)
    end

    def ids(**opts) = described_class.session_summaries(state_dir: tmpdir, **opts).map { |s| s[:id] }

    it "sums a session up: short id, a one-line description, cwd, liveness and whether a turn runs" do
      session = make(cwd: "/work/app", prompt: "fix   the\nlogin page", status: Samagotchi::Session::STATUS_RUNNING)
      own(session)

      summary = described_class.session_summaries(state_dir: tmpdir).first

      expect(summary).to include(id: session.id, short_id: session.id[0, 8], desc: "app · fix the login page",
                                 cwd: "/work/app", updated_at: "2026-09-24T10:00:00Z", live: true, busy: true)
    end

    it "carries the parent link, and .children_of lists a parent's children newest first" do
      parent = make(prompt: "plan", updated: "2026-09-24T09:00:00Z")
      older = make(prompt: "first task", updated: "2026-09-24T10:00:00Z", parent_id: parent.id)
      newer = make(prompt: "second task", updated: "2026-09-24T11:00:00Z", parent_id: parent.id,
                   status: Samagotchi::Session::STATUS_RUNNING)
      own(newer)

      rows = described_class.session_summaries(state_dir: tmpdir).to_h { |s| [s[:id], s] }
      expect(rows[parent.id]).to include(parent_id: nil, parent_short_id: nil)
      expect(rows[older.id]).to include(parent_id: parent.id, parent_short_id: parent.id[0, 8])

      children = described_class.children_of(parent.id, state_dir: tmpdir)
      expect(children.map { |s| s[:id] }).to eq([newer.id, older.id])
      expect(children.count { |s| s[:busy] }).to eq(1)
      expect(described_class.children_of(nil, state_dir: tmpdir)).to eq([])
      expect(described_class.children_of(older.id, state_dir: tmpdir)).to eq([])
    end

    it "cuts a long description to 60 characters and falls back to the first preview" do
      long = make(prompt: "x" * 100)
      preview = make(prompt: "", preview: "from the preview", updated: "2026-09-23T10:00:00Z")

      by_id = described_class.session_summaries(state_dir: tmpdir).to_h { |s| [s[:id], s[:desc]] }

      expect(by_id[long.id].length).to eq(60)
      expect(by_id[long.id]).to end_with("…")
      expect(by_id[preview.id]).to eq("app · from the preview")
    end

    it "drops the quote markers of a quoted or annotated message from the description" do
      quoted = make(prompt: "> answer:\n> the build failed\n>\n> > nested\n\nsame bug?")

      summary = described_class.session_summaries(state_dir: tmpdir).find { |s| s[:id] == quoted.id }

      expect(summary[:desc]).to eq("app · answer: the build failed nested same bug?")
      expect(summary[:preview]).to eq("answer: the build failed nested same bug?")
    end

    it ".worker_live? is true only while a worker holds the session, not a REPL" do
      worker = make
      repl = make
      none = make
      own(worker)
      own(repl, kind: "tui")

      expect(described_class.worker_live?(worker.id, state_dir: tmpdir)).to be(true)
      expect(described_class.worker_live?(repl.id, state_dir: tmpdir)).to be(false)
      expect(described_class.worker_live?(none.id, state_dir: tmpdir)).to be(false)
    end

    it "live: only sessions a worker owns now, not a REPL's and not a stale running status" do
      worker = make(updated: "2026-09-24T10:00:00Z")
      repl = make(updated: "2026-09-24T11:00:00Z")
      stale = make(updated: "2026-09-24T12:00:00Z", status: Samagotchi::Session::STATUS_RUNNING)
      own(worker)
      own(repl, kind: "tui")

      expect(ids(live: true)).to eq([worker.id])
      expect(ids).to eq([stale.id, repl.id, worker.id])
      expect(described_class.session_summaries(state_dir: tmpdir).find { |s| s[:id] == stale.id })
        .to include(live: false, busy: false)
    end

    it "filters before it takes the limit" do
      live_one = make(updated: "2026-09-24T09:00:00Z")
      make(updated: "2026-09-24T10:00:00Z")
      make(updated: "2026-09-24T11:00:00Z")
      own(live_one)

      expect(ids(live: true, limit: 1)).to eq([live_one.id])
      expect(ids(limit: 2).size).to eq(2)
    end

    it "cwd: the folder or below it, not a sibling that shares its prefix" do
      top = make(cwd: "/work/app", updated: "2026-09-24T12:00:00Z")
      below = make(cwd: "/work/app/web", updated: "2026-09-24T11:00:00Z")
      make(cwd: "/work/apple", updated: "2026-09-24T10:00:00Z")

      expect(ids(cwd: "/work/app")).to eq([top.id, below.id])
      expect(ids(cwd: "/work/app/")).to eq([top.id, below.id])
    end

    it "leaves out test runs on request, and a given session (the asking one)" do
      mine = make(updated: "2026-09-24T12:00:00Z")
      test = make(test_run: true, updated: "2026-09-24T11:00:00Z")
      other = make(updated: "2026-09-24T10:00:00Z")

      expect(ids).to include(test.id)
      expect(ids(include_tests: false, exclude: mine.id)).to eq([other.id])
    end
  end
end
