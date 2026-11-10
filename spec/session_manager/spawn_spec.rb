# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

  describe ".live_spawn_pids" do
    it "returns the unique pids of live worker starters" do
      live = double("live waiter", pid: 123, alive?: true)
      dead = double("dead waiter", pid: 456, alive?: false)
      described_class.send(:note_starter, live)
      described_class.send(:note_starter, dead)
      described_class.send(:note_starter, live)

      expect(described_class.live_spawn_pids).to eq([123])
    end
  end

  # Every spawn marks the session starting (StartingMarker) until its
  # worker holds the owner lock: the writer's pid before the spawn, the
  # starter's (Process.spawn's child, which lives until then) after.
  describe "the starting marker of a spawn" do
    def marker(id)
      JSON.parse(File.read(File.join(Samagotchi::Session.session_dir(id, state_dir: tmpdir), "starting")))
    rescue Errno::ENOENT
      nil
    end

    def fresh?(id) = Samagotchi::StartingMarker.fresh?(id, state_dir: tmpdir)

    after do
      if @starter
        Process.kill("KILL", @starter)
        Process.wait(@starter)
      end
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    # A stand-in starter: a real child that runs until the example ends.
    def spawn_starter(seen = nil)
      allow(Process).to receive(:spawn).and_wrap_original do |original, *|
        seen&.call
        @starter = original.call("sleep", "30")
      end
    end

    it "is written before a new session's worker spawns and names its starter after" do
      at_spawn = nil
      spawn_starter(-> { at_spawn = Dir.glob(File.join(tmpdir, "*", "starting")).map { |f| JSON.parse(File.read(f))["pid"] } })

      session = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir)

      expect(at_spawn).to eq([Process.pid])
      expect(marker(session.id)).to include("pid" => @starter)
      expect(fresh?(session.id)).to be(true)
    end

    it "is written for a resume too, naming its starter" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      spawn_starter

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(marker(session.id)).to include("pid" => @starter)
      expect(fresh?(session.id)).to be(true)
    end

    it "holds nothing once the starter is gone (a spawn that failed to boot)" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      allow(Process).to receive(:spawn).and_wrap_original do |original, *|
        original.call("true").tap { |pid| Process.wait(pid) }
      end

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(fresh?(session.id)).to be(false)
    end

    it "is removed when the spawn itself raises" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      allow(Process).to receive(:spawn).and_raise(Errno::ENOENT, "chi")

      expect { described_class.resume_session(session.id, state_dir: tmpdir) }.to raise_error(Errno::ENOENT)
      expect(marker(session.id)).to be_nil
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

    # H7: the worker owns the file; a resume (any process, no lock) writing
    # its stale copy would overwrite a worker that saved meanwhile. The
    # worker resets a status no turn is behind (run_session_loop_spec.rb).
    it "writes nothing to the session file, whatever its status" do
      [Samagotchi::Session::STATUS_STOPPED, Samagotchi::Session::STATUS_ERROR, Samagotchi::Session::STATUS_RUNNING].each do |status|
        session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
        session.status = status
        session.save(state_dir: tmpdir)
        path = File.join(tmpdir, "#{session.id}.json")
        before = File.read(path)
        allow(Process).to receive(:spawn).and_return(20_002)

        described_class.resume_session(session.id, state_dir: tmpdir)

        expect(File.read(path)).to eq(before)
      end
    end

    it "doesn't overwrite a worker that saved between its load and its spawn" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      allow(Samagotchi::Session).to receive(:clear_stopped).and_wrap_original do |original, *args, **kwargs|
        # A worker (another resume's) took the session and saved a turn.
        Samagotchi::Session.load(session.id, state_dir: tmpdir).tap { |s| s.title = "the worker's" }.save(state_dir: tmpdir)
        original.call(*args, **kwargs)
      end
      allow(Process).to receive(:spawn).and_return(20_002)

      described_class.resume_session(session.id, state_dir: tmpdir)

      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).title).to eq("the worker's")
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
    end

    # The starting marker is the one cross-process starting state: a resume
    # from this process or any other (chi web, a `chi send`, a child's ring)
    # holds off while a starter runs (no owner lock yet).
    describe "a worker being started (no owner lock yet)" do
      let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap { |s| s.save(state_dir: tmpdir) } }
      let(:starters) { [] }

      before do
        allow(Process).to receive(:spawn).and_wrap_original do |original, *|
          original.call("sleep", "30").tap { |pid| starters << pid }
        end
      end

      after do
        starters.each do |pid|
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          nil
        end
      end

      # Killed and reaped (by the spawn's Process.detach waiter).
      def kill_starters
        starters.each do |pid|
          Process.kill("KILL", pid)
          wait_for("starter #{pid} to be gone") { !Samagotchi::StartingMarker.process_alive?(pid) }
        end
      end

      it "is not spawned again by a second resume (deliver_turn's after a slow start)" do
        2.times { described_class.resume_session(session.id, state_dir: tmpdir) }
        expect(Process).to have_received(:spawn).once
      end

      it "is not spawned again for another process's start" do
        other = IO.popen(%w[sleep 30])
        Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir, pid: other.pid)

        described_class.resume_session(session.id, state_dir: tmpdir)
        expect(Process).not_to have_received(:spawn)
      ensure
        if other
          Process.kill("KILL", other.pid)
          other.close
        end
      end

      it "is spawned again once that starter exited, or after a stop" do
        described_class.resume_session(session.id, state_dir: tmpdir)
        kill_starters
        described_class.resume_session(session.id, state_dir: tmpdir)
        expect(Process).to have_received(:spawn).twice

        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        described_class.resume_session(session.id, state_dir: tmpdir)
        expect(Process).to have_received(:spawn).exactly(3).times
      end

      # The plan's two shells: a stop, then two sends at once. The stop
      # cancels a start from before it, not one a resume made after it.
      it "is spawned once by two resumes after a stop, and again over a start from before the stop" do
        Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)
        sleep(0.01) # sleep-ok: the stop's mtime comes after the start's at
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        # Both see the stop (presence read), then race for the start.
        allow(Samagotchi::Session).to receive(:clear_stopped)

        2.times { described_class.resume_session(session.id, state_dir: tmpdir) }

        expect(Process).to have_received(:spawn).once
      end

      # The stop carries its own at, on the starting marker's clock: a
      # coarse or skewed file mtime doesn't make a start from before the stop
      # read as after it.
      it "takes over a start from before the stop by the stop's own time, not its file's mtime" do
        Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)
        sleep(0.01) # sleep-ok: the stop's at comes after the start's
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
        stop_file = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), "stopped")
        File.utime(Time.now - 10, Time.now - 10, stop_file)

        described_class.resume_session(session.id, state_dir: tmpdir)

        expect(Process).to have_received(:spawn).once
      end

      it "falls back to the mtime of an older chi's empty stop file" do
        Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)
        stop_file = File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), "stopped")
        File.write(stop_file, "")
        File.utime(Time.now + 10, Time.now + 10, stop_file)

        described_class.resume_session(session.id, state_dir: tmpdir)

        expect(Process).to have_received(:spawn).once
      end

      it "drops its claim when the spawn fails before Process.spawn (the command, the options)" do
        allow(described_class).to receive(:worker_command).and_raise(ArgumentError, "no chi")

        expect { described_class.resume_session(session.id, state_dir: tmpdir) }.to raise_error(ArgumentError)
        expect(File.exist?(File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), "starting"))).to be(false)
      end

      it "is spawned again once the marker is stale" do
        described_class.resume_session(session.id, state_dir: tmpdir)
        File.write(File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), "starting"),
                   JSON.generate({ "pid" => starters.first, "at" => (Time.now - 120).iso8601(3) }))
        described_class.resume_session(session.id, state_dir: tmpdir)
        expect(Process).to have_received(:spawn).twice
      end

      # Its marker is claimed (StartingMarker.claim), then the owner read
      # again: a worker that took the lock in between (and cleared the
      # marker an earlier start wrote) keeps the session.
      it "spawns nothing and drops its claim when a worker took the lock meanwhile" do
        owner = Samagotchi::OwnerLock::Owner.new(pid: 1, kind: "worker", started_at: nil)
        allow(described_class).to receive(:session_owner).and_return(nil, owner)

        described_class.resume_session(session.id, state_dir: tmpdir)

        expect(Process).not_to have_received(:spawn)
        expect(Samagotchi::StartingMarker.fresh?(session.id, state_dir: tmpdir)).to be(false)
      end
    end
  end

  describe ".spawn_session" do
    it "requires callers to name the first prompt's sender" do
      expect { described_class.spawn_session(prompt: nil) }.to raise_error(ArgumentError, /client_id/)
    end

    it "refuses a model qualified with a host config.yml doesn't have, before anything is saved or spawned" do
      allow(Process).to receive(:spawn).and_return(12_345)
      stub_hosts_config("main" => { "host" => "localhost", "port" => 8080 })

      expect { spawn_session_for_spec(described_class, prompt: "hi", model_name: "nosuch:org/model", state_dir: tmpdir) }
        .to raise_error(Samagotchi::ModelProfile::UnknownHost, /unknown host 'nosuch'.*configured hosts are main/)
      expect(Process).not_to have_received(:spawn)
      expect(Dir.glob(File.join(tmpdir, "sessions", "*"))).to be_empty
    end

    # Every creation surface (chi, chi send --new, chi web, delegate, a
    # continue or a fork) refuses through this one check (Toolkit.check_new!).
    describe "a toolkit on a config kit whose groups: is invalid" do
      before do
        allow(Process).to receive(:spawn).and_return(12_345)
        allow(Samagotchi::Toolkit).to receive(:config_kits)
          .and_return("typo" => { "base" => "lean", "groups" => { "chrome" => true } },
                      "web" => { "base" => "lean", "groups" => ["chrome"] }, "plain" => { "base" => "lean" })
      end

      let(:refusal) do
        "toolkit.kits.typo: groups must be a list of group names or globs; fix config.yml to start a session on toolkit typo"
      end

      def spawn(toolkit = nil)
        spawn_session_for_spec(described_class, prompt: "hi", model_name: "m", state_dir: tmpdir,
                                      setup: Samagotchi::SessionSetup.new(toolkit: toolkit && Samagotchi::Toolkit.new(name: toolkit)))
      end

      it "refuses it, named or as toolkit.default, before anything is saved or spawned" do
        expect { spawn("typo") }.to raise_error(Samagotchi::Toolkit::Refused, refusal)
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("toolkit.default").and_return("typo")
        expect { spawn }.to raise_error(Samagotchi::Toolkit::Refused, refusal)
        expect(Process).not_to have_received(:spawn)
        expect(Dir.glob(File.join(tmpdir, "sessions", "*"))).to be_empty
      end

      it "starts one on a kit with a valid list or no groups:" do
        expect(spawn("web")).to have_attributes(toolkit: Samagotchi::Toolkit.new(name: "web"), toolkit_origin: "chosen")
        expect(spawn("plain")).to have_attributes(toolkit: Samagotchi::Toolkit.new(name: "plain"), toolkit_origin: "chosen")
      end

      it "marks a configured toolkit as the default" do
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("toolkit.default").and_return("web")

        expect(spawn).to have_attributes(toolkit: Samagotchi::Toolkit.new(name: "web"), toolkit_origin: "default")
      end
    end

    # A host's saved model list (ModelListStore: what `chi models` last
    # listed) names an id it doesn't have; the session starts anyway.
    describe "an unknown model id, with a saved list for the host" do
      before do
        require "samagotchi/model_list_store"
        require "samagotchi/host_registry"
        stub_hosts_config("main" => { "host" => "localhost", "port" => 8080 })
        Samagotchi::ModelListStore.save("main", %w[gemma-small qwen3])
        allow(Process).to receive(:spawn).and_return(12_345)
        # A miss re-lists the host once (ModelProfile.model_warning). No host
        # is up here: the re-list answers nothing, so the warning comes from
        # the saved list (spec/model_check_spec.rb covers the re-list).
        allow_any_instance_of(Samagotchi::HostRegistry).to receive(:list_models).and_return(nil)
      end

      it "starts it with a warning on the session, with a did-you-mean" do
        session = spawn_session_for_spec(described_class, prompt: "hi", model_name: "main:gemma-smal", state_dir: tmpdir)

        expect(session.model_warning).to eq("host 'main' doesn't list model 'gemma-smal' (did you mean: gemma-small?); " \
                                            "started it anyway; `chi models` lists what the hosts serve")
        expect(Process).to have_received(:spawn)
      end

      it "starts the session for an id the list has" do
        session = spawn_session_for_spec(described_class, prompt: nil, model_name: "main:gemma-small", state_dir: tmpdir)

        expect(Process).to have_received(:spawn)
        expect(session.model_warning).to be_nil
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).model_name).to eq("main:gemma-small")
      end

      it "checks the host the ref names, whatever the configured default is" do
        session = spawn_session_for_spec(described_class, prompt: nil, model_name: "main:nosuch", state_dir: tmpdir)
        expect(session.model_warning).to start_with("host 'main' doesn't list model 'nosuch'")
      end

      it "checks nothing for an id with no host in front of it (routing picks the host)" do
        expect { spawn_session_for_spec(described_class, prompt: nil, model_name: "anything-at-all", state_dir: tmpdir) }
          .not_to raise_error
        expect(Process).to have_received(:spawn)
      end

      it "checks nothing for a stale list (a week old)" do
        Samagotchi::ModelListStore.save("main", %w[gemma-small], at: Time.now.to_i - Samagotchi::ModelListStore::TTL_SECONDS - 60)

        expect { spawn_session_for_spec(described_class, prompt: nil, model_name: "main:nosuch", state_dir: tmpdir) }
          .not_to raise_error
        expect(Process).to have_received(:spawn)
      end

      it "starts the session anyway when no list is saved for its host" do
        FileUtils.rm_f(Samagotchi::ModelListStore.path)

        expect { spawn_session_for_spec(described_class, prompt: nil, model_name: "main:nosuch", state_dir: tmpdir) }
          .not_to raise_error
        expect(Process).to have_received(:spawn)
      end
    end

    it "starts a session with no prompt idle, with nothing to run" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = spawn_session_for_spec(described_class, prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_IDLE)
      expect(loaded.last_prompt.to_s).to eq("")
      expect(Process).to have_received(:spawn)
    end

    it "gives the prompt a session starts with the turn id a sent message would have" do
      allow(Process).to receive(:spawn).and_return(12_345)

      started = spawn_session_for_spec(described_class, prompt: "look", model_name: "gemma4", state_dir: tmpdir)
      idle = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir)

      expect(Samagotchi::Session.load(started.id, state_dir: tmpdir).first_turn_id)
        .to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
      expect(started.first_turn_id).to eq(Samagotchi::Session.load(started.id, state_dir: tmpdir).first_turn_id)
      expect(Samagotchi::Session.load(idle.id, state_dir: tmpdir).first_turn_id).to be_nil
    end

    # Who sent the first prompt (a delegating parent, a schedule's chain
    # link): its turn carries that origin, so the intake treats it as theirs.
    it "keeps the first prompt's sender beside its turn id; none for an idle session or a person's" do
      allow(Process).to receive(:spawn).and_return(12_345)

      sent = spawn_session_for_spec(described_class, prompt: "look", model_name: "gemma4", client_id: "delegate:1234abcd", state_dir: tmpdir)
      typed = spawn_session_for_spec(described_class, prompt: "look", model_name: "gemma4", state_dir: tmpdir)
      idle = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", client_id: "delegate:1234abcd", state_dir: tmpdir)

      expect(Samagotchi::Session.load(sent.id, state_dir: tmpdir).first_turn_client_id).to eq("delegate:1234abcd")
      expect(Samagotchi::Session.load(typed.id, state_dir: tmpdir).first_turn_client_id).to be_nil
      expect(Samagotchi::Session.load(idle.id, state_dir: tmpdir).first_turn_client_id).to be_nil
    end

    describe "the toolkit, stored as named when the session is created" do
      before do
        allow(Process).to receive(:spawn).and_return(12_345)
        allow(Samagotchi::Config).to receive(:get).and_call_original
      end

      def stored(session) = Samagotchi::Session.load(session.id, state_dir: tmpdir).toolkit

      it "is full with nothing configured" do
        session = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir)
        expect(stored(session)).to eq(Samagotchi::Toolkit.new(name: "full"))
      end

      it "is toolkit.default, or toolkit.child for a delegate child without a setup toolkit" do
        allow(Samagotchi::Config).to receive(:get).with("toolkit.default").and_return("lean")
        allow(Samagotchi::Config).to receive(:get).with("toolkit.child").and_return("my-child")

        plain = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir)
        child = spawn_session_for_spec(described_class, prompt: "look", model_name: "gemma4", state_dir: tmpdir, delegate: true,
                                              parent_id: "parent-1234")
        expect(stored(plain)).to eq(Samagotchi::Toolkit.new(name: "lean"))
        expect(stored(child)).to eq(Samagotchi::Toolkit.new(name: "my-child"))
      end

      it "is the delegate call's for a delegate child whose setup names one" do
        allow(Samagotchi::Config).to receive(:get).with("toolkit.child").and_return("my-child")
        child = spawn_session_for_spec(described_class, prompt: "look", model_name: "gemma4", state_dir: tmpdir, delegate: true,
                                              parent_id: "parent-1234",
                                              setup: Samagotchi::SessionSetup.new(toolkit: Samagotchi::Toolkit.new(name: "coding")))
        expect(stored(child)).to eq(Samagotchi::Toolkit.new(name: "coding"))
      end

      it "is the setup's own when it has one" do
        allow(Samagotchi::Config).to receive(:get).with("toolkit.default").and_return("lean")
        toolkit = Samagotchi::Toolkit.new(name: "coordinator", add: ["web_fetch"])
        session = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir,
                                                setup: Samagotchi::SessionSetup.new(toolkit: toolkit))
        expect(stored(session)).to eq(toolkit)
      end
    end

    it "stores the --memory and --mute lists on the session before the worker starts" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir,
                                              setup: Samagotchi::SessionSetup.new(preloaded_memory_names: ["cli_usage"],
                                                                                  muted_memory_names: ["gh-helper"]))

      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.preloaded_memory_names).to eq(["cli_usage"])
      expect(loaded.muted_memory_names).to eq(["gh-helper"])
    end

    it "stores the parent session's id before the worker starts" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = spawn_session_for_spec(described_class, prompt: "look", model_name: "gemma4", state_dir: tmpdir,
                                              parent_id: "parent-1234")

      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).parent_id).to eq("parent-1234")
      expect(Samagotchi::Session.load(spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir).id,
                                      state_dir: tmpdir).parent_id).to be_nil
    end

    it "runs before_spawn with the saved session and its note queued, before the worker spawns" do
      seen = []
      allow(Process).to receive(:spawn) { seen << :spawn and 12_345 }

      session = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir, note: "hello",
                                              before_spawn: lambda { |s|
                                                dir = Samagotchi::Session.session_dir(s.id, state_dir: tmpdir)
                                                seen << [Samagotchi::Session.exist?(s.id, state_dir: tmpdir),
                                                         Samagotchi::SessionInbox.find_new_note_files(dir).size]
                                              })

      expect(seen).to eq([[true, 1], :spawn])
      expect(session).to be_a(Samagotchi::Session)
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

      session = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir, parent_id: "p1",
                                              messages: seed, images_from: parent_dir, preview: "btw: what is it?")

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

    it "saves the session's own title before its worker starts, beside the preview" do
      seen = []
      allow(Process).to receive(:spawn) do
        seen << Dir.glob(File.join(tmpdir, "*.json")).map { |path| JSON.parse(File.read(path)).values_at("title", "first_preview") }
        12_345
      end

      session = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir, title: "Coordinator",
                                              preview: "hey chi")

      expect(seen).to eq([[["Coordinator", "hey chi"]]])
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).display_title).to eq("Coordinator")
    end

    it "previews a seeded session without a title by its first user message" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = spawn_session_for_spec(described_class, prompt: nil, model_name: "gemma4", state_dir: tmpdir,
                                              messages: [{ role: "user", content: "the first question" }])

      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).first_preview).to eq("the first question")
    end

    it "records the first prompt as the preview, before the worker takes it" do
      allow(Process).to receive(:spawn).and_return(12_345)

      session = spawn_session_for_spec(described_class, prompt: "  fix the\n  bug " + ("x" * 90), model_name: "gemma4", state_dir: tmpdir)

      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.first_preview).to eq("fix the bug #{"x" * 68}…")
    end

    it "hands the worker an idle exit set on the command line" do
      Samagotchi::Config.reload!(cli_overrides: { "session.idle_exit_minutes" => "0.5" })
      spawned_env = nil
      allow(Process).to receive(:spawn) do |*args, **_opts|
        spawned_env = args.first if args.first.is_a?(Hash)
        12_345
      end

      spawn_session_for_spec(described_class, prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned_env).to include("SAMAGOTCHI_SESSION_IDLE_EXIT_MINUTES" => "0.5")
    ensure
      Samagotchi::Config.reload!(cli_overrides: {})
    end

    # Its default for this run (the worker's /model reset), marked as the
    # CLI's so its execute children don't inherit it (Builtins.parent_env).
    it "hands the worker a --model as its default, marked as the command line's" do
      spawned = []
      allow(Process).to receive(:spawn) do |*args, **_opts|
        spawned << (args.first.is_a?(Hash) ? args.first : {})
        12_345
      end

      Samagotchi::Config.reload!(cli_overrides: { "default.model" => "gemma4" })
      spawn_session_for_spec(described_class, prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)
      Samagotchi::Config.reload!(cli_overrides: {})
      spawn_session_for_spec(described_class, prompt: nil, mode: "assist", model_name: "gemma4", state_dir: tmpdir)

      expect(spawned[0]).to include("SAMAGOTCHI_DEFAULT_MODEL" => "gemma4", "SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI" => "1")
      expect(spawned[1].keys).not_to include("SAMAGOTCHI_DEFAULT_MODEL", "SAMAGOTCHI_DEFAULT_MODEL_FROM_CLI")
    ensure
      Samagotchi::Config.reload!(cli_overrides: {})
    end
  end
end
