# frozen_string_literal: true

require "spec_helper"
require "support/worker_fixtures"
require "samagotchi/worker_link"
require "tmpdir"
require "net/http"
require "json"
require "support/test_kernel"
require "support/failing_saves"
require "support/worker_loop_rounds"
require "support/bridge_auth"

require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/bridge_client"
require "samagotchi/worker"

RSpec.describe Samagotchi::Worker do
  include BridgeAuth

  include WorkerLoopRounds
  include WorkerFixtures

  def cmd(**fields) = Samagotchi::QueuedCommand.new(**fields)

  describe Samagotchi::Worker::Waker do
    let(:waker) { described_class.new }

    it "returns at once when woken, and false after the timeout when not" do
      waker.wake
      expect(waker.wait(5)).to be(true)

      started = mono
      expect(waker.wait(0.05)).to be(false)
      expect(mono - started).to be >= 0.05
    end

    it "drains every wake at once, so the loop doesn't spin" do
      3.times { waker.wake }
      expect(waker.wait(1)).to be(true)
      expect(waker.wait(0.05)).to be(false)
    end

    it "keeps a wake that comes after the drain" do
      waker.wake
      waker.wait(1)
      waker.wake
      expect(waker.wait(0.05)).to be(true)
    end

    it "wakes a waiting thread" do
      # true means woken, not timed out; the bound sits well under the 10 s
      # timeout so a loaded CI runner doesn't flake it.
      woken = Thread.new { waker.wait(10) }
      # Asleep in the wait, not about to enter it.
      wait_for("the thread to sleep in the wait") { woken.status == "sleep" }
      started = mono
      waker.wake
      expect(woken.value).to be(true)
      expect(mono - started).to be < 5
    end
  end

  describe "#run" do
    around do |example|
      original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      WebMock.allow_net_connect! if defined?(WebMock)
      example.run
    ensure
      WebMock.disable_net_connect! if defined?(WebMock)
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
    end

    let(:tmpdir) { Dir.mktmpdir("worker-spec") }
    let!(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let!(:engine) do
      Samagotchi::Engine.new(client: test_client,
                             kernel: test_kernel)
    end
    let(:turns) { Queue.new }
    let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }

    before do
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
      allow(Samagotchi::Engine).to receive(:new) do |**kwargs|
        @reminder_callback = kwargs.dig(:reminders, :callback)
        engine
      end
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
        turns << [prompt, mono, kwargs]
        result
      end
    end

    after do
      @thread&.kill
      @thread&.join(2)
      FileUtils.rm_rf(tmpdir)
    end

    # Runs the worker on a thread; what #run returns is the thread's value.
    def start_worker(poll_interval: 5, idle_exit_minutes: 0, **signal_args)
      worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                   idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval, **signal_args)
      @worker = worker
      hold_worker(session_dir) if worker_locks.empty?
      count_loop_rounds(worker)
      @thread = Thread.new { worker.run }
      @thread.report_on_exception = false
      wait_for("the worker's sidecar") { File.exist?(sidecar) }
      # Let the loop reach its wait (or end): at most what a turn the
      # example holds open would let it.
      wait_until(timeout: 0.5) { !@thread.alive? || loop_waiting?(@thread) } # wait-ok: at most what a turn held open lets it
    end

    # Whether the worker's loop sleeps on its Waker (nothing to do).
    def loop_waiting?(thread) = thread.backtrace.to_a.any? { |frame| frame.include?("Waker#wait") }

    def sidecar
      File.join(session_dir, Samagotchi::WorkerSidecar::FILE)
    end

    def post_turn(prompt)
      port = JSON.parse(File.read(sidecar))["port"]
      Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/turn"),
                     JSON.generate(session_id: session.id, prompt: prompt),
                     "Content-Type" => "application/json", **bridge_auth(sidecar))
    end

    def next_turn(timeout: 5)
      pop!(turns, "the next turn", timeout: timeout)
    end

    it "announces changed worker-start settings, but not live settings or a return to the startup value" do
      previous_config_home = ENV["XDG_CONFIG_HOME"]
      config_home = File.join(tmpdir, "config")
      config_dir = File.join(config_home, "samagotchi")
      FileUtils.mkdir_p(config_dir)
      config_path = File.join(config_dir, "config.yml")
      ENV["XDG_CONFIG_HOME"] = config_home
      File.write(config_path, "server:\n  port: 8080\nturn:\n  max_iterations: 10\n")
      Samagotchi::ConfigFile.clear_yaml_cache!
      events = []
      engine.subscribe(observer: ->(event) { events << event })

      start_worker
      File.write(config_path, "server:\n  port: 8081\nturn:\n  max_iterations: 20\n")
      File.utime(Time.now + 5, Time.now + 5, config_path)
      Samagotchi::Config.get("server.port")
      wait_for("the config change notice") { events.any? { |event| event[:hook] == "config" } }
      expect(events.select { |event| event[:hook] == "config" }.map { |event| event[:text] })
        .to eq(["server.port changed — applies after a worker restart"])

      File.write(config_path, "server:\n  port: 8080\nturn:\n  max_iterations: 20\n")
      File.utime(Time.now + 10, Time.now + 10, config_path)
      Samagotchi::Config.get("server.port")
      expect(events.select { |event| event[:hook] == "config" }.map { |event| event[:text] })
        .to eq(["server.port changed — applies after a worker restart"])
    ensure
      ENV["XDG_CONFIG_HOME"] = previous_config_home
      Samagotchi::ConfigFile.clear_yaml_cache!
    end

    it "builds its Engine from the session's preloaded and muted memory lists" do
      session.preloaded_memory_names = ["cli_usage"]
      session.muted_memory_names = ["gh-helper"]
      session.save(state_dir: tmpdir)
      kwargs = nil
      allow(Samagotchi::Engine).to receive(:new) do |**given|
        kwargs = given
        engine
      end
      start_worker
      expect(kwargs).to include(memories: ["cli_usage"], muted_memories: ["gh-helper"])
    end

    it "builds its Engine with the session's appended prompt files" do
      session.appended_prompt_files = ["/r/extra.md"]
      session.save(state_dir: tmpdir)
      kwargs = nil
      allow(Samagotchi::Engine).to receive(:new) do |**given|
        kwargs = given
        engine
      end
      start_worker
      expect(kwargs).to include(appended_prompt_files: ["/r/extra.md"])
    end

    it "drops a question a dead worker saved (its turn is gone) and saves, before its Engine sees the session" do
      session.pending_question = { id: "q1", question: "Which?", options: %w[a b] }
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.save(state_dir: tmpdir)

      start_worker

      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).pending_question).to be_nil
      expect(engine.session.pending_question).to be_nil
      expect(engine.pending_question).to be_nil
    end

    it "settles a turn an earlier worker died in (interrupted_turn): its note, idle, canceled, saved before the Bridge serves" do
      session.messages = [{ role: "user", content: "task" }, { role: "tool_response", content: "[execute]\nstep1" }]
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.interrupted_turn = { "id" => "t1", "started_at" => "2026-10-12T10:00:00.000Z", "at" => "2026-10-12T10:00:20.000Z",
                                   "iteration" => 2 }
      session.save(state_dir: tmpdir)

      start_worker

      saved = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(saved.messages.map { |m| m[:content] }.first(2)).to eq(["task", "[execute]\nstep1"])
      expect(saved.messages.last[:content]).to include("cancelled (worker-stopped) after 20s")
      expect(saved).to have_attributes(status: "idle", interrupted_turn: nil)
      expect(saved.last_turn).to be_nil
      expect(engine.session.messages.last[:content]).to include("worker-stopped")
    end

    it "records a settled queued turn's end under its id in the session dir, for that turn's wait" do
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.interrupted_turn = { "id" => "t1", "started_at" => "2026-10-12T10:00:00.000Z", "iteration" => 1, "enqueued_id" => "q1" }
      session.save(state_dir: tmpdir)

      start_worker

      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      expect(Samagotchi::TurnCheckpoint.settled_turn(dir, "q1")).to have_attributes(outcome: "canceled", cancel_reason: "worker_stopped")
    end

    it "prunes week-old removed and settled tombstones as it starts, keeping newer ones" do
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      old_time = Time.now - Samagotchi::SessionInbox::TOMBSTONE_MAX_AGE - 60
      paths = { old: %w[removed/r-old settled/s-old], new: %w[removed/r-new settled/s-new] }.transform_values do |names|
        names.map do |name|
          path = File.join(dir, Samagotchi::SessionInbox::INPUT_DIR, name)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, "")
          path
        end
      end
      paths[:old].each { |path| File.utime(old_time, old_time, path) }

      start_worker

      expect(paths[:old].map { |path| File.exist?(path) }).to eq([false, false])
      expect(paths[:new].map { |path| File.exist?(path) }).to eq([true, true])
    end

    it "tells its Engine it is a worker, so approvals wait for an attached UI" do
      start_worker
      expect(engine.interface).to eq(:worker)
      ctx = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: engine.send(:plugin_host))
      expect(ctx.frontend).to eq(:worker)
    end

    # The fallback tick is a minute away, so a turn that starts within a few
    # seconds was woken, not ticked; a tight wall-clock bound flaked on a
    # loaded CI runner (0.43 s on Ruby 4.0).
    it "starts a turn posted to its Bridge at once, not on the next tick" do
      start_worker(poll_interval: 60)

      posted_at = mono
      expect(post_turn("PING").code).to eq("202")

      prompt, started_at = next_turn
      expect(prompt).to eq("PING")
      expect(started_at - posted_at).to be < 5
    end

    it "picks up an input file written without a wake on the fallback tick" do
      start_worker(poll_interval: 0.02)

      Samagotchi::SessionManager.write_turn_input(session.id, prompt: "from another process", state_dir: tmpdir)

      expect(next_turn&.first).to eq("from another process")
    end

    it "runs a due reminder at once, as a continue turn with no user message (as the REPL)" do
      allow(engine).to receive(:reminders_due?).and_return(true)
      start_worker(poll_interval: 60)

      called_at = mono
      @reminder_callback.call(["stretch"])

      prompt, started_at, kwargs = next_turn
      expect(prompt).to be_nil
      expect(kwargs).to include(continue: true, origin: Samagotchi::TurnOrigin.new(client_id: "system:reminder"))
      expect(started_at - called_at).to be < 5
      expect(Dir.children(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))).to be_empty
      expect(engine.due_reminder_names).to be_empty
    end

    it "runs no reminder turn when a prompt's turn already took the due reminders (a stale latch)" do
      allow(engine).to receive(:reminders_due?).and_return(false)
      start_worker(poll_interval: 5)

      @reminder_callback.call(["stretch"])

      loop_rounds
      expect(turns).to be_empty
      expect(engine.due_reminder_names).to be_empty
    end

    # Disk full or a permission error on a save between turns: what it
    # saves is in memory (the next save writes it), so the worker goes on.
    describe "a failing save (Worker#save_or_log)" do
      include_context "failing session saves"

      it "keeps running when the post-turn save fails, and runs the next queued prompt" do
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          turns << [prompt, mono, kwargs]
          saves_fail!
          result
        end
        start_worker(poll_interval: 5)

        post_turn("one")
        expect(next_turn&.first).to eq("one")

        wait_for("the post-turn save to fail") { !failed_saves.empty? }
        expect(failed_saves).to eq([:turn])
        expect(@thread).to be_alive

        saves_fail!(false)
        post_turn("two")
        expect(next_turn&.first).to eq("two")
        expect(@thread).to be_alive
      end

      it "starts when dropping a dead question can't be saved; the next save writes the drop" do
        session.pending_question = { id: "q1", question: "Which?", options: %w[a b] }
        session.save(state_dir: tmpdir)
        saves_fail!

        start_worker(poll_interval: 5)

        expect(failed_saves).to eq([:dead_question])
        expect(engine.session.pending_question).to be_nil
        expect(@thread).to be_alive

        saves_fail!(false)
        post_turn("one")
        expect(next_turn&.first).to eq("one")
        wait_for("the dropped question to be saved") { Samagotchi::Session.load(session.id, state_dir: tmpdir).pending_question.nil? }
      end

      it "stays up when taking its first prompt can't be saved" do
        session.messages = []
        session.last_prompt = "first"
        session.save(state_dir: tmpdir)
        saves_fail!

        start_worker(poll_interval: 5)

        # The turn's own saves fail too: the one before it keeps it from
        # beginning (logged as turn_not_begun), the worker stays up.
        wait_for("the turn's save to fail") { failed_saves.include?(:turn) }
        expect(failed_saves.first).to eq(:initial_prompt)
        expect(@thread).to be_alive

        saves_fail!(false)
        post_turn("two")
        expect(next_turn&.first).to eq("two")
        # Taken: a later worker won't run it again.
        wait_for("the taken first prompt to be saved") { Samagotchi::Session.load(session.id, state_dir: tmpdir).last_prompt == "" }
      end
    end

    it "names a turn's reply after its input's enqueued_id, so a wait for that turn finds it" do
      answered = instance_double(Samagotchi::LLM::ModelResult, output: "the answer", canceled?: false, resumable?: false)
      # Idle again as the Engine leaves it, or the wait gives the session
      # its settle time (ReplyWait::SETTLE_SECONDS) to go idle.
      allow(engine).to receive(:run_turn) do |turn_session, *|
        turn_session.status = Samagotchi::Session::STATUS_IDLE
        answered
      end
      start_worker

      ack = JSON.parse(post_turn("hi").body)
      result = Samagotchi::ReplyWait.call(session.id, state_dir: tmpdir, cursor: nil, timeout: 2, poll_interval: 0.02,
                                                      turn: ack["enqueued_id"])
      expect(result.to_h).to include(status: :done, text: "the answer")
      expect(result.file).to end_with("-#{ack["enqueued_id"]}.txt")
    end

    # The prompt a session was created with is not an input file, but its
    # turn has the id spawn_session gave it, so a wait can name it (chi send
    # --new --wait, chi web's create).
    it "runs the first prompt as a turn with the id the session was created with" do
      session.last_prompt = "the first thing"
      session.first_turn_id = "first-1"
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.save(state_dir: tmpdir)
      answered = instance_double(Samagotchi::LLM::ModelResult, output: "the answer", canceled?: false, resumable?: false)
      allow(engine).to receive(:run_turn) do |turn_session, *|
        turn_session.status = Samagotchi::Session::STATUS_IDLE
        answered
      end
      start_worker

      result = Samagotchi::ReplyWait.call(session.id, state_dir: tmpdir, cursor: nil, timeout: 2, poll_interval: 0.02,
                                                      turn: "first-1", queued: true)
      expect(result.to_h).to include(status: :done, text: "the answer")
      expect(result.file).to end_with("-first-1.txt")
    end

    it "records a turn that failed before the Engine began it as last_turn, so a wait ends with no_reply" do
      allow(engine).to receive(:run_turn).and_raise(RuntimeError, "boom before the turn")
      start_worker
      baseline = Samagotchi::ReplyWait.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))

      post_turn("hi")
      wait_for("the failed turn's note, idle") do
        s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        s.status == "idle" && Samagotchi::TurnNote.trailing_index(s.messages)
      end

      saved = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(saved.last_turn.to_file).to include("outcome" => "failed", "origin" => "client")
      result = Samagotchi::ReplyWait.call(session.id, state_dir: tmpdir, cursor: nil, timeout: 1, poll_interval: 0.02,
                                                      baseline: baseline)
      expect(result.to_h).to include(status: :no_reply, outcome: "failed")
    end

    describe "an archived session (ArchiveStore)" do
      def archived? = Samagotchi::ArchiveStore.archived?(session_dir)

      before { Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir) }

      %w[web:tab1 tui:4242 cli:send].each do |client_id|
        it "comes back to the lists on a prompt from #{client_id}" do
          start_worker(poll_interval: 0.02)
          Samagotchi::SessionManager.write_turn_input(session.id, prompt: "hi", client_id: client_id, state_dir: tmpdir)

          expect(next_turn&.first).to eq("hi")
          expect(archived?).to be(false)
        end
      end

      %w[delegate:1234abcd plugin].each do |client_id|
        it "stays archived on a turn from #{client_id}" do
          start_worker(poll_interval: 0.02)
          Samagotchi::SessionManager.write_turn_input(session.id, prompt: "task", client_id: client_id, state_dir: tmpdir)

          expect(next_turn&.first).to eq("task")
          expect(archived?).to be(true)
        end
      end

      it "stays archived on a reminder turn" do
        allow(engine).to receive(:reminders_due?).and_return(true)
        start_worker(poll_interval: 5)
        @reminder_callback.call(["stretch"])

        expect(next_turn&.first).to be_nil
        expect(archived?).to be(true)
      end

      it "comes back when the user steers into a delegate's turn" do
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          Samagotchi::SessionManager.write_turn_input(session.id, prompt: "also this", client_id: "web:tab1", state_dir: tmpdir)
          turns << [prompt, mono, kwargs[:pending_input].call]
          result
        end
        start_worker(poll_interval: 0.02)
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "task", client_id: "delegate:1234abcd", state_dir: tmpdir)

        expect(next_turn&.last).to eq([Samagotchi::Steer::Line.new(text: "also this", source: nil)])
        expect(archived?).to be(false)
      end
    end

    describe "#pending_input_drain" do
      it "keeps each merged line's sender as a Steer::Line source, and the merge saves it" do
        senders = ["cli:send", "delegate:abcd1234", "web:x", "plugin", nil]
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          senders.each_with_index do |client_id, index|
            Samagotchi::SessionInbox.write_input(session_dir, prompt: "line #{index}", client_id: client_id)
          end
          turns << [prompt, mono, kwargs[:pending_input].call]
          result
        end
        start_worker(poll_interval: 0.02)
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "task", client_id: "web:x", state_dir: tmpdir)

        lines = next_turn&.last
        expect(lines.map(&:source)).to eq(["chi_send", "parent_agent", nil, "plugin_send", nil])
        expect(lines.map(&:text)).to eq(["line 0", "line 1", "line 2", "line 3", "line 4"])

        conversation = []
        Samagotchi::Steer.inject!(conversation, -> { lines.first(1) }, iteration: 1, emit: ->(_) {}, cancel_controller: nil)
        expect(conversation).to eq([{ role: "user", kind: "input", source: "chi_send", content: "line 0", at: message_at }])
      end

      it "skips a queued line without stopping at it: a later line merges, the queued one runs after as its own turn" do
        merged = Queue.new
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          if prompt == "task"
            Samagotchi::SessionInbox.write_input(session_dir, prompt: "later one", client_id: "web:x", delivery: "queue", now: next_stamp)
            Samagotchi::SessionInbox.write_input(session_dir, prompt: "later two", client_id: "cli:send", delivery: "queue", now: next_stamp)
            Samagotchi::SessionInbox.write_input(session_dir, prompt: "now please", client_id: "web:x", now: next_stamp)
            merged << kwargs[:pending_input].call
          end
          turns << [prompt, mono]
          result
        end
        start_worker(poll_interval: 0.02)
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "task", client_id: "web:x", state_dir: tmpdir)

        expect(pop!(merged, "the turn's merge").map(&:text)).to eq(["now please"])
        expect(Array.new(3) { next_turn&.first }).to eq(["task", "later one", "later two"])
      end

      it "never puts a skipped queued line into the checkpoint" do
        merging = []
        allow_any_instance_of(Samagotchi::TurnCheckpoint).to receive(:boundary).and_wrap_original do |original, conversation, **kwargs|
          merging << kwargs[:merging].map(&:text)
          original.call(conversation, **kwargs)
        end
        merged = Queue.new
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          if prompt == "task"
            Samagotchi::SessionInbox.write_input(session_dir, prompt: "queued", delivery: "queue", now: next_stamp)
            Samagotchi::SessionInbox.write_input(session_dir, prompt: "steer", now: next_stamp)
            merged << kwargs[:pending_input].call
          end
          turns << [prompt, mono]
          result
        end
        start_worker(poll_interval: 0.02)
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "task", state_dir: tmpdir)

        expect(pop!(merged, "the turn's merge").map(&:text)).to eq(["steer"])
        expect(merging).to include(["steer"])
        expect(merging.flatten).not_to include("queued")
        expect(Array.new(2) { next_turn&.first }).to eq(%w[task queued])
      end

      # A reminder turn that is the worker's first turn: no prompt turn set
      # up the merge list before it, and the drain must still hand the line
      # over (it claims and deletes the input file first).
      it "merges a line into a reminder turn that is the worker's first turn" do
        allow(engine).to receive(:reminders_due?).and_return(true)
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          Samagotchi::SessionInbox.write_input(session_dir, prompt: "steer me", client_id: "web:x")
          turns << [prompt, mono, kwargs[:pending_input].call]
          result
        end
        start_worker(poll_interval: 60)
        @reminder_callback.call(["stretch"])

        expect(next_turn&.last).to eq([Samagotchi::Steer::Line.new(text: "steer me", source: nil)])
      end
    end

    it "runs a turn posted while another runs right after it" do
      release = Queue.new
      allow(engine).to receive(:run_turn) do |_session, prompt, **|
        turns << [prompt, mono]
        release.pop if prompt == "one"
        result
      end
      start_worker(poll_interval: 5)

      post_turn("one")
      expect(next_turn&.first).to eq("one")
      post_turn("two")
      released_at = mono
      release << true

      prompt, started_at = next_turn
      expect(prompt).to eq("two")
      # Well under the 5 s poll: the queued turn starts on release, not on the
      # next poll (0.3 s flaked on a loaded CI runner at 0.3007 s).
      expect(started_at - released_at).to be < 2.0
    end

    it "logs what ended it when a turn's input fails past its own handling (then marks the session)" do
      log = File.join(tmpdir, "chi.log")
      Samagotchi::Log.configure(path: log)
      allow_any_instance_of(described_class).to receive(:run_input_file).and_raise(JSON::GeneratorError, "source sequence is illegal/malformed utf-8")
      start_worker(poll_interval: 0.05)

      post_turn("one")

      expect(join!(@thread, "the worker").value).to eq(:crashed)
      record = File.open(log) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.event == "crashed" } }
      expect(record.to_h).to include(level: "ERROR", tag: "worker")
      expect(record.fields).to include("error" => "JSON::GeneratorError")
      expect(record.payload).to match(/worker\.rb:\d+:in [`'](Samagotchi::Worker#)?run(_loop)?'/) # 3.3: `run_loop', 3.4+: 'Samagotchi::Worker#run_loop'
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq("error")
    end

    it "still exits on a stop marked on disk" do
      start_worker(poll_interval: 0.05)

      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      expect(join!(@thread, "the worker").value).to eq(:stopped)
    end

    it "still leaves when idle" do
      start_worker(poll_interval: 0.05, idle_exit_minutes: 0.002)

      expect(join!(@thread, "the worker").value).to eq(:idle_exit)
      expect(File.exist?(sidecar)).to be(false)
    end

    # The check and the closed intake are one step of the event log; the
    # Bridge's stop (it waits up to a second for requests it is answering)
    # comes after the log is let go, so a request waiting on it isn't held.
    it "stops its Bridge outside the event log as it idle-exits" do
      held = []
      allow_any_instance_of(Samagotchi::Bridge).to receive(:stop).and_wrap_original do |original, *args|
        held << engine.instance_variable_get(:@session_observer).instance_variable_get(:@mutex).mon_owned?
        original.call(*args)
      end
      start_worker(poll_interval: 0.05, idle_exit_minutes: 0.002)

      expect(join!(@thread, "the worker").value).to eq(:idle_exit)
      expect(held).not_to be_empty
      expect(held).to all(be(false))
    end

    # A recap tick emits under the event log, which #leave_idle holds as it
    # stops the idle jobs: a stop that joined would wait out
    # IdleScheduler::STOP_JOIN_SECONDS and then kill the tick mid-emit. Not
    # joined, the tick's emit goes through once the log is let go.
    it "stops the idle jobs as it idle-exits without waiting for a tick that needs the event log" do
      entered = Queue.new
      go = Queue.new
      emitted = Queue.new
      events = engine
      job = Object.new
      job.define_singleton_method(:tick) do
        entered << true
        SpecWaiting.pop!(go, "the worker to stop the idle jobs", timeout: 30)
        events.synchronize_events { emitted << :recap }
      end
      scheduler = Samagotchi::IdleScheduler.new(engine: engine, jobs: [job], interval: 60)
      engine.instance_variable_set(:@idle_scheduler, scheduler)
      allow(engine).to receive(:stop_idle).and_wrap_original do |original, **kwargs|
        go << true
        original.call(**kwargs)
      end
      scheduler.start
      ticking = scheduler.instance_variable_get(:@thread)
      pop!(entered, "the recap tick")

      start_worker(poll_interval: 0.05, idle_exit_minutes: 0.002)

      expect(join!(@thread, "the worker's idle exit").value).to eq(:idle_exit)
      expect(pop!(emitted, "the tick's emit, after the worker let the event log go")).to eq(:recap)
      # The teardown's Engine#shutdown joined it.
      expect(ticking).not_to be_alive
    ensure
      go << true
    end

    it "shuts its Engine down as it idle-exits: the plugins' services stop" do
      stopped = []
      services = engine.instance_variable_get(:@services)
      services.add(Samagotchi::Plugin::Service.new("b:srv") { |svc| svc.on_stop { stopped << :srv } }).value
      start_worker(poll_interval: 0.05, idle_exit_minutes: 0.002)

      expect(join!(@thread, "the worker").value).to eq(:idle_exit)
      expect(stopped).to eq([:srv])
    end

    it "shuts its Engine down when it crashes" do
      allow(engine).to receive(:shutdown).and_call_original
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files).and_raise(RuntimeError, "boom")
      worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                   idle_exit_minutes: 0, poll_interval: 5)
      expect(worker.run).to eq(:crashed)
      expect(engine).to have_received(:shutdown)
    end

    it "writes a recap as it idle-exits" do
      session.model_name = "Qwen3-14B"
      session.save(state_dir: tmpdir)
      allow(engine).to receive(:write_recap_now)
      start_worker(poll_interval: 0.05, idle_exit_minutes: 0.002)

      expect(join!(@thread, "the worker").value).to eq(:idle_exit)
      expect(engine).to have_received(:write_recap_now)
    end

    # WorkerSignals fired by hand: the rspec process traps nothing.
    describe "a signal (TERM, HUP, INT)" do
      let(:kernel) { engine.instance_variable_get(:@kernel) }
      let(:events) { Queue.new }
      let(:in_turn) { Queue.new }
      let(:release) { Queue.new }
      let(:exits) { [] }
      let(:signals) { Samagotchi::WorkerSignals.new(hard_exit: -> { exits << :hard_exit }) }
      let(:steps) do
        [{ role: "model", content: "", tool_calls: [{ id: "c1", name: "execute", arguments: {} }] },
         { role: "tool_response", content: "[execute]\nstep1", tool_call_id: "c1" }]
      end

      before do
        allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
        allow(engine).to receive(:run_turn).and_call_original
        # One tool step, then the turn runs until it is canceled (or, for
        # "stubborn", until released: a tool that ignores the cancel).
        allow(kernel).to receive(:run) do |messages, cancel_controller:, **kwargs|
          prompt = messages.last[:content]
          turns << [prompt, mono, kwargs]
          conversation = messages + steps
          in_turn << prompt
          if prompt == "stubborn"
            release.pop
          elsif prompt == "answered"
            next Samagotchi::LLM::ModelResult.new(text: "ANSWER", conversation: conversation + [{ role: "model", content: "ANSWER" }],
                                                  exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
          else
            SpecWaiting.wait_for("the turn to be canceled", timeout: 30) { cancel_controller.cancelled? }
          end
          Samagotchi::LLM::ModelResult.new(text: "", conversation: conversation, exhausted: false, pending_tool_calls: false,
                                           tool_activity: [], canceled: true, cancellation_reason: cancel_controller.reason)
        end
        engine.subscribe(observer: ->(event) { events << event })
      end

      def seen_events
        list = []
        list << events.pop until events.empty?
        list
      end

      def saved = Samagotchi::Session.load(session.id, state_dir: tmpdir)

      # What the worker's thread died of (RSpec's raise_error never rescues
      # a SignalException).
      # The after hook's join would raise it again: the thread is done with.
      def death_of(thread)
        join!(thread, "the worker")
        nil
      rescue SignalException => e
        @thread = nil
        e
      end

      it "stops the running turn as a Stop with reason signal, saves its work and leaves with :signal" do
        start_worker(poll_interval: 5, signals: signals)
        post_turn("long task")
        expect(pop!(in_turn, "the turn")).to eq("long task")

        signals.fire("TERM")

        expect(join!(@thread, "the worker").value).to eq(:signal)
        canceled = seen_events.find { |e| e[:type] == :turn_canceled }
        expect(canceled).to include(cancellation_reason: :signal)
        contents = saved.messages.map { |m| m[:content] }
        expect(contents).to include("long task", "[execute]\nstep1")
        expect(contents.last).to include("the previous turn was cancelled (signal")
        expect(saved.status).to eq("idle")
        expect(saved.last_turn).to have_attributes(outcome: "canceled", cancel_reason: "signal")
        expect(exits).to be_empty
      end

      it "leaves at once when idle" do
        start_worker(poll_interval: 60, signals: signals)

        signals.fire("HUP")

        expect(join!(@thread, "the worker").value).to eq(:signal)
        expect(turns).to be_empty
      end

      it "takes no new work once signalled: the next queued prompt stays in the inbox" do
        start_worker(poll_interval: 5, signals: signals)
        post_turn("first")
        expect(pop!(in_turn, "the turn")).to eq("first")
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "second", state_dir: tmpdir,
                                                                no_interrupt: true)

        signals.fire("TERM")

        expect(join!(@thread, "the worker").value).to eq(:signal)
        expect(turns.size).to eq(1)
        expect(Samagotchi::SessionInbox.find_new_input_files(session_dir).size).to eq(1)
      end

      it "leaves with :stopped when the session was stopped too (chi sessions stop), its turn saved" do
        start_worker(poll_interval: 5, signals: signals)
        post_turn("long task")
        expect(pop!(in_turn, "the turn")).to eq("long task")
        Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

        signals.fire("TERM")

        expect(join!(@thread, "the worker").value).to eq(:stopped)
        expect(saved.messages.map { |m| m[:content] }).to include("[execute]\nstep1")
        expect(saved.status).to eq("stopped")
      end

      it "cuts a turn that hasn't ended within the grace: saves the session, raises the signal in the loop, then the hard exit" do
        start_worker(poll_interval: 5, signals: signals, signal_grace: [0.3, 0.1, 0.2])
        post_turn("stubborn")
        expect(pop!(in_turn, "the turn")).to eq("stubborn")

        signals.fire("TERM")

        expect(death_of(@thread)&.signm).to eq("SIGTERM")
        wait_for("the hard exit", timeout: 2) { exits == [:hard_exit] }
        # Saved as it was: running, with the turn's checkpoint (here, before
        # any boundary: the prompt, marked at iteration 0).
        expect(saved.status).to eq("running")
        expect(saved.messages.last).to include(role: "user", content: "stubborn")
        expect(saved.interrupted_turn).to have_attributes(iteration: 0)
      end

      it "lets a turn that ended run its after_turn hooks past the grace (no cancel), its display kept" do
        engine.instance_variable_get(:@hooks).register(:after_turn) do |event|
          in_turn << :hook
          sleep 0.3 # sleep-ok: a slow hook, past the 0.1 s grace
          event[:present].call { |text| "#{text} (shown)" }
        end
        # The worker's own end of the turn, past the hooks, outlasts a
        # SIGNAL_RETRY: the turn no longer runs, the loop hasn't left yet.
        allow(Samagotchi::SessionInbox).to receive(:write_output).and_wrap_original do |original, *args, **options|
          sleep 0.15 # sleep-ok: the worker's slow end of the turn, past a SIGNAL_RETRY
          original.call(*args, **options)
        end
        start_worker(poll_interval: 5, signals: signals, signal_grace: [0.1, 0.1, 5])
        post_turn("answered")
        expect(pop!(in_turn, "the turn")).to eq("answered")
        expect(pop!(in_turn, "the after_turn hook")).to eq(:hook)

        signals.fire("TERM")

        expect(death_of(@thread)).to be_nil
        expect(@thread.value).to eq(:signal) if @thread
        expect(seen_events.map { |e| e[:type] }).not_to include(:turn_canceled)
        expect(saved.messages.last).to include(content: "ANSWER", display: "ANSWER (shown)")
        expect(exits).to be_empty
      end

      it "never raises into the worker's start: a grace that runs out before the loop starts waits for it" do
        allow(engine).to receive(:start_idle) do
          signals.fire("TERM")
          sleep 0.15 # sleep-ok: a slow start, past the 0.05 + 0.05 s graces
        end
        worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir, idle_exit_minutes: 0,
                                     poll_interval: 5, signals: signals, signal_grace: [0.05, 0.05, 5])
        @thread = Thread.new { worker.run }
        @thread.report_on_exception = false

        expect(death_of(@thread)).to be_nil
        expect(@thread.value).to eq(:signal)
        expect(exits).to be_empty
      end

      it "runs its teardown whole even when the signal is raised meanwhile (it comes after)" do
        torn = []
        allow(engine).to receive(:shutdown) do
          run_thread = Thread.current
          Thread.new { run_thread.raise(SignalException.new("TERM")) }.join
          sleep 0.05 # sleep-ok: the teardown still runs as the raise is due
          torn << :engine
        end
        start_worker(poll_interval: 5, signals: signals)

        signals.fire("TERM")

        expect(death_of(@thread)&.signm).to eq("SIGTERM")
        expect(torn).to eq([:engine])
        expect(File.exist?(sidecar)).to be(false) # the Bridge stopped after it
      end

      it "marks its owner lock leaving before its teardown stops the Bridge, so a closed port never reads Live" do
        lock = hold_worker(session_dir)
        start_worker(poll_interval: 5, signals: signals, owner_lock: lock)
        seen = []
        allow(@worker.instance_variable_get(:@bridge)).to receive(:stop).and_wrap_original do |original, *args|
          seen << Samagotchi::OwnerLock.owner(session_dir)&.leaving?
          original.call(*args)
        end

        signals.fire("TERM")

        expect(join!(@thread, "the worker").value).to eq(:signal)
        expect(seen.first).to be(true)
        expect(Samagotchi::OwnerLock.owner(session_dir)).to be_leaving
      end

      it "brings the hard exit for a signal that comes after the loop left" do
        start_worker(poll_interval: 5, signals: signals, signal_grace: [3, 0.5, 0.1])
        signals.fire("TERM")
        expect(join!(@thread, "the worker").value).to eq(:signal)
        expect(exits).to be_empty

        signals.fire("TERM")

        wait_for("the hard exit", timeout: 2) { exits == [:hard_exit] }
      end

      it "saves one at a time: the grace's save waits for the worker's own" do
        start_worker(poll_interval: 5, signals: signals, signal_grace: [0.2, 0.1, 5])
        post_turn("stubborn")
        expect(pop!(in_turn, "the turn")).to eq("stubborn")
        inside = 0
        most = 0
        lock = Mutex.new
        # Inside Session#save's lock: the session file's writes overlap
        # only if two saves run at once.
        session_file = "#{engine.session.id}.json"
        allow(Samagotchi::AtomicFile).to receive(:write).and_wrap_original do |original, path, *args, **kwargs|
          next original.call(path, *args, **kwargs) unless File.basename(path) == session_file

          lock.synchronize { most = [most, inside += 1].max }
          sleep 0.2 # sleep-ok: a slow save, so two at once would overlap
          original.call(path, *args, **kwargs).tap { lock.synchronize { inside -= 1 } }
        end
        worker_save = Thread.new { @worker.send(:save_session) }

        signals.fire("TERM")

        expect(death_of(@thread)).to be_a(SignalException)
        join!(worker_save, "the worker's own save")
        expect(most).to eq(1)
      end

      it "skips most of the grace on a second signal" do
        start_worker(poll_interval: 5, signals: signals, signal_grace: [30, 0.1, 0.1])
        post_turn("stubborn")
        expect(pop!(in_turn, "the turn")).to eq("stubborn")

        signals.fire("TERM")
        signals.fire("TERM")

        expect(death_of(@thread)).to be_a(SignalException)
      end
    end

    describe "the running turn's checkpoint (TurnCheckpoint)" do
      let(:kernel) { engine.instance_variable_get(:@kernel) }
      let(:in_turn) { Queue.new }
      let(:release) { Queue.new }
      let(:earlier) { [{ role: "system", content: "sys" }, { role: "user", content: "earlier", display_refs: [{ "kind" => "file" }] }, { role: "model", content: "ok" }] }

      def step(n) = [{ role: "model", content: "", tool_calls: [{ id: "c#{n}", name: "execute", arguments: {} }] },
                     { role: "tool_response", content: "[execute]\nstep#{n}", tool_call_id: "c#{n}" }]

      before do
        stub_const("Samagotchi::TurnCheckpoint::INTERVAL", 0)
        allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
        allow(engine).to receive(:run_turn).and_call_original
        # A loop: its conversation registered on the kernel, a boundary
        # (the drain) before each step, then it waits to be released.
        allow(kernel).to receive(:run) do |messages, pending_input:, **|
          conversation = messages.map(&:dup)
          kernel.llm_context_turn = Samagotchi::LLMContextForget::Turn.new(conversation: conversation, context: nil, emit: nil)
          [1, 2].each do |n|
            Samagotchi::SessionInbox.write_input(session_dir, prompt: "steer me", client_id: "web:x") if n == @steer_at
            Samagotchi::Steer.inject!(conversation, pending_input, iteration: n, emit: ->(_) {}, cancel_controller: nil)
            conversation.concat(step(n))
          end
          Samagotchi::Steer.inject!(conversation, pending_input, iteration: 3, emit: ->(_) {}, cancel_controller: nil)
          in_turn << true
          release.pop
          conversation << { role: "model", content: "DONE" }
          Samagotchi::LLM::ModelResult.new(text: "DONE", conversation: conversation, exhausted: false, pending_tool_calls: false,
                                           tool_activity: [], canceled: false)
        end
        session.messages = earlier
        session.save(state_dir: tmpdir)
      end

      def on_disk = JSON.parse(File.read(Samagotchi::Session.session_file(session.id, state_dir: tmpdir)))

      it "keeps the turn so far on disk with an interrupted_turn mark, and the real messages once it ends" do
        start_worker(poll_interval: 5)
        enqueued_id = JSON.parse(post_turn("long task").body)["enqueued_id"]
        expect(pop!(in_turn, "the turn")).to be(true)

        # What a KILL now would leave: the prompt and both steps, marked.
        file = on_disk
        expect(file["status"]).to eq("running")
        expect(file["messages"].map { |m| m["content"] }.drop(1).grep_v(/\A\[SYSTEM: /))
          .to eq(["earlier", "ok", "long task", "", "[execute]\nstep1", "", "[execute]\nstep2"])
        expect(file["messages"][1]["display_refs"]).to eq([{ "kind" => "file" }])
        # It names the input the turn runs (ReplyWait.own_turn).
        expect(file["interrupted_turn"]).to include("iteration" => 3, "started_at" => a_kind_of(String), "at" => a_kind_of(String),
                                                    "enqueued_id" => enqueued_id)
        # The session in memory is untouched (the Bridge's snapshot shows
        # the turn in progress, not in the messages).
        expect(engine.session.messages.map { |m| m[:content] }).not_to include("long task")
        # Another save in the turn (a question asked: QuestionDesk) writes the checkpoint too.
        engine.session.save(state_dir: tmpdir)
        expect(on_disk["interrupted_turn"]).to include("iteration" => 3)
        expect(on_disk["messages"].map { |m| m["content"] }).to include("[execute]\nstep2")

        release << true
        wait_for("the ended turn to be saved, idle") { on_disk["status"] == "idle" && on_disk["messages"].last["content"] == "DONE" }
        expect(on_disk["interrupted_turn"]).to be_nil
        expect(engine.session.turn_checkpoint).to be_nil
      end

      it "saves the turn's metrics so far with the checkpoint (as a killed turn's), its own end's after" do
        start_worker(poll_interval: 5)
        post_turn("long task")
        expect(pop!(in_turn, "the turn")).to be(true)

        analytics = -> { JSON.parse(File.read(File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), "analytics.json"))) }
        expect(analytics.call["turn_records"].map { |r| r.slice("status", "cancellation_reason") })
          .to eq([{ "status" => "canceled", "cancellation_reason" => "worker_stopped" }])

        release << true
        wait_for("the session to be saved idle") { on_disk["status"] == "idle" }
        wait_for("the completed turn's metrics") { analytics.call["turn_records"].map { |r| r["status"] } == ["completed"] }
      end

      it "writes at the first boundary, then when due, or at once for a merged line (its input file is gone)" do
        stub_const("Samagotchi::TurnCheckpoint::INTERVAL", 3600)
        @steer_at = 2
        start_worker(poll_interval: 5)
        post_turn("long task")
        expect(pop!(in_turn, "the turn")).to be(true)

        # Boundary 1 wrote (the prompt), boundary 2 merged a line (written
        # with it), boundary 3 was not due.
        contents = on_disk["messages"].map { |m| m["content"] }
        expect(contents).to include("long task", "[execute]\nstep1", "steer me")
        expect(contents).not_to include("[execute]\nstep2")
        expect(on_disk["interrupted_turn"]).to include("iteration" => 2)

        release << true
        wait_for("the session to be saved idle") { on_disk["status"] == "idle" }
      end
    end

    describe "an exit request (POST /exit)" do
      def post_exit(client_id: "tui:1", stop: false)
        port = JSON.parse(File.read(sidecar))["port"]
        body = { client_id: client_id }
        body[:stop] = "all" if stop
        res = Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/exit"),
                             JSON.generate(body), "Content-Type" => "application/json", **bridge_auth(sidecar))
        [res.code.to_i, JSON.parse(res.body)]
      end

      after { Array(@streams).each(&:close) }

      it "leaves at once when nothing keeps it, even with idle exit off, and the session isn't stopped" do
        start_worker(poll_interval: 5, idle_exit_minutes: 0)

        expect(post_exit.first).to eq(200)
        expect(join!(@thread, "the worker").value).to eq(:exit_requested)
        expect(File.exist?(sidecar)).to be(false)
        expect(engine).to have_received(:stop_idle)
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).not_to eq(Samagotchi::Session::STATUS_STOPPED)
      end

      it "says the session is discarded when nothing happened in it, and leaves it for deleting" do
        allow(engine).to receive(:write_recap_now)
        start_worker(poll_interval: 5, idle_exit_minutes: 0)

        expect(post_exit.last).to include("discard" => true)
        expect(join!(@thread, "the worker").value).to eq(:exit_requested)
        expect(@worker.discard?).to be(true)
        expect(engine).not_to have_received(:write_recap_now)
      end

      it "writes a recap as it leaves, after closing the Bridge and stopping the idle jobs" do
        session.model_name = "Qwen3-14B"
        session.save(state_dir: tmpdir)
        order = []
        allow(engine).to receive(:stop_idle) { order << :stop_idle }
        allow(engine).to receive(:write_recap_now) { order << [:recap, File.exist?(sidecar)] }
        start_worker(poll_interval: 5, idle_exit_minutes: 0)

        expect(post_exit.first).to eq(200)
        expect(join!(@thread, "the worker").value).to eq(:exit_requested)
        expect(order).to eq([:stop_idle, [:recap, false]])
      end

      it "writes no recap for an exit that deletes the session (/exit --delete)" do
        session.model_name = "Qwen3-14B"
        session.save(state_dir: tmpdir)
        allow(engine).to receive(:write_recap_now)
        start_worker(poll_interval: 5, idle_exit_minutes: 0)
        port = JSON.parse(File.read(sidecar))["port"]
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/exit"),
                       JSON.generate(client_id: "tui:1", delete: true), "Content-Type" => "application/json", **bridge_auth(sidecar))

        expect(join!(@thread, "the worker").value).to eq(:exit_requested)
        expect(engine).not_to have_received(:write_recap_now)
      end

      it "says it keeps a session on another model" do
        session.model_name = "Qwen3-14B"
        session.save(state_dir: tmpdir)
        start_worker(poll_interval: 5, idle_exit_minutes: 0)

        expect(post_exit.last).to include("discard" => false)
        join!(@thread, "the worker")
        expect(@worker.discard?).to be(false)
      end

      it "stays up while a turn runs" do
        start_worker(poll_interval: 0.05)
        allow(engine).to receive(:turn_running?).and_return(true)

        expect(post_exit).to eq([409, { "status" => "held", "reason" => "turn_running", "session_id" => session.id }])
        loop_rounds
        expect(@thread).to be_alive
      end

      def follow(client_id: nil)
        stream = Samagotchi::WorkerLink.client(session.id, session_dir: session_dir).follow(client_id: client_id) { |_| nil }
        (@streams ||= []) << stream
        stream
      end

      def open_streams = @worker.instance_variable_get(:@bridge).open_streams

      it "leaves while the asker's own stream is open" do
        start_worker(poll_interval: 0.05)
        follow(client_id: "tui:1")
        wait_for("the asker's stream") { open_streams == 1 }

        expect(post_exit.first).to eq(200)
        expect(join!(@thread, "the worker").value).to eq(:exit_requested)
      end

      it "stays up while another client holds a stream" do
        start_worker(poll_interval: 0.05)
        follow(client_id: "tui:1")
        follow # a web tab
        wait_for("both streams") { open_streams == 2 }

        expect(post_exit.last).to include("reason" => "client_connected")
        loop_rounds
        expect(@thread).to be_alive
      end

      def child(id, state: "running")
        Samagotchi::ChildrenStatus::Child.new(id: id, short_id: id[0, 8], title: "Fix the composer", state: state,
                                              waiting: nil, live: true, delegate: true, cwd: tmpdir, branch: nil,
                                              last_reply: nil, last_reply_at: nil, reported: false,
                                              updated_at: Time.now.iso8601, archived: false)
      end

      describe "the exit ask" do
        def child_stub(stopped)
          allow(Samagotchi::ChildrenStatus).to receive(:of).and_return([child("c1c1c1c1-1111")])
          allow(Samagotchi::SessionManager).to receive(:stop_session) { |id, **| stopped << id }
        end

        it "lists what the user can stop when only that holds the worker, and stays up" do
          engine.reminder_store.register(name: "api_health", description: "check the API", interval_minutes: 20)
          child_stub([])
          start_worker(poll_interval: 0.05)

          status, body = post_exit

          expect(status).to eq(409)
          expect(body["reason"]).to eq("reminders")
          expect(body["holds"]).to eq([{ "kind" => "reminders",
                                         "items" => [{ "id" => "api_health", "label" => "api_health",
                                                       "detail" => "every 20m" }] },
                                       { "kind" => "delegates",
                                         "items" => [{ "id" => "c1c1c1c1-1111", "label" => "Fix the composer",
                                                       "detail" => "running a turn" }] }])
          loop_rounds
          expect(@thread).to be_alive
        end

        it "stops them all and leaves when the body says so, reporting what it stopped" do
          engine.reminder_store.register(name: "api_health", description: "check the API", interval_minutes: 20)
          stopped = []
          child_stub(stopped)
          start_worker(poll_interval: 0.05)

          status, body = post_exit(stop: true)

          expect(status).to eq(200)
          expect(body["stopped"]).to eq({ "reminders" => ["api_health"], "tasks" => [],
                                          "delegates" => ["c1c1c1c1"] })
          expect(stopped).to eq(["c1c1c1c1-1111"])
          expect(engine.reminder_store.reminders).to be_empty
          expect(join!(@thread, "the worker").value).to eq(:exit_requested)
          expect(File.exist?(File.join(session_dir, Samagotchi::ReminderCarry::FILE))).to be(false)
        end

        it "refuses the stop-all when something the user can't stop appeared meanwhile" do
          engine.reminder_store.register(name: "api_health", description: "check the API", interval_minutes: 20)
          start_worker(poll_interval: 0.05)
          allow(engine).to receive(:turn_running?).and_return(true)

          status, body = post_exit(stop: true)

          expect(status).to eq(409)
          expect(body["reason"]).to eq("turn_running")
          expect(body).not_to include("holds")
          loop_rounds
          expect(@thread).to be_alive
        end

        it "asks when a delegate running is all that is left, and stops it on the answer" do
          stopped = []
          allow(Samagotchi::ChildrenStatus).to receive(:of).and_return([child("c1c1c1c1-1111")])
          allow(Samagotchi::SessionManager).to receive(:stop_session) { |id, **| stopped << id }
          start_worker(poll_interval: 0.05)

          status, body = post_exit

          expect(status).to eq(409)
          expect(body["reason"]).to eq("delegates")
          expect(body["holds"]).to eq([{ "kind" => "delegates",
                                         "items" => [{ "id" => "c1c1c1c1-1111", "label" => "Fix the composer",
                                                       "detail" => "running a turn" }] }])
          loop_rounds
          expect(@thread).to be_alive

          status, body = post_exit(stop: true)

          expect(status).to eq(200)
          expect(body["stopped"]).to eq({ "reminders" => [], "tasks" => [], "delegates" => ["c1c1c1c1"] })
          expect(stopped).to eq(["c1c1c1c1-1111"])
          expect(join!(@thread, "the worker").value).to eq(:exit_requested)
        end

        it "does not ask for a delete exit: a delegate alone leaves, as before" do
          allow(Samagotchi::ChildrenStatus).to receive(:of).and_return([child("c1c1c1c1-1111")])
          start_worker(poll_interval: 0.05)
          port = JSON.parse(File.read(sidecar))["port"]
          res = Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/exit"),
                               JSON.generate(client_id: "tui:1", delete: true), "Content-Type" => "application/json", **bridge_auth(sidecar))

          expect(res.code.to_i).to eq(200)
          expect(join!(@thread, "the worker").value).to eq(:exit_requested)
        end
      end

      describe "with restart: true" do
        def post_restart
          port = JSON.parse(File.read(sidecar))["port"]
          res = Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/exit"),
                               JSON.generate(client_id: "web:1", restart: true), "Content-Type" => "application/json", **bridge_auth(sidecar))
          [res.code.to_i, JSON.parse(res.body)]
        end

        it "leaves as :restart while other clients' streams are open, keeping even an empty session, with no recap" do
          allow(engine).to receive(:write_recap_now)
          start_worker(poll_interval: 0.05)
          follow(client_id: "tui:1")
          follow # a web tab
          wait_for("both streams") { open_streams == 2 }

          expect(post_restart).to eq([200, { "status" => "restarting", "session_id" => session.id }])
          expect(join!(@thread, "the worker").value).to eq(:restart)
          expect(@worker.discard?).to be(false)
          expect(engine).not_to have_received(:write_recap_now)
        end

        def carry_file = File.join(session_dir, Samagotchi::ReminderCarry::FILE)

        it "carries its reminders to the next worker: written as it leaves, restored and deleted as that one starts" do
          engine.reminder_store.register(name: "api_health", description: "check the API", interval_minutes: 20)
          id = engine.reminder_store.reminders["api_health"][:id]
          start_worker(poll_interval: 0.05)

          expect(post_restart.first).to eq(200)
          expect(join!(@thread, "the worker").value).to eq(:restart)
          carried = JSON.parse(File.read(carry_file))
          expect(carried).to include("session_id" => session.id)
          expect(carried["reminders"].map { |r| r.slice("id", "name", "interval_minutes") })
            .to eq([{ "id" => id, "name" => "api_health", "interval_minutes" => 20 }])

          allow(Samagotchi::Engine).to receive(:new).and_call_original
          successor = Samagotchi::Engine.new(client: test_client, kernel: test_kernel)
          allow(successor).to receive(:start_idle)
          allow(successor).to receive(:stop_idle)
          allow(Samagotchi::Engine).to receive(:new).and_return(successor)
          start_worker(poll_interval: 0.05)

          wait_for("the successor's reminders") { successor.reminder_store.any? }
          expect(successor.reminder_store.reminders["api_health"]).to include(id: id, interval_minutes: 20,
                                                                              description: "check the API")
          expect(File.exist?(carry_file)).to be(false)
        end

        it "writes no hand-off when a stop lands between the request and the leave" do
          engine.reminder_store.register(name: "api_health", description: "check the API", interval_minutes: 20)
          start_worker(poll_interval: 0.05)
          policy = @worker.instance_variable_get(:@idle_exit)
          looks = 0
          allow(policy).to receive(:hold_for_restart) do
            looks += 1
            # The leave's look, under the lock: the stop's marker is down by now.
            Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir) if looks == 2
            nil
          end

          expect(post_restart.first).to eq(200)
          expect(join!(@thread, "the worker").value).to eq(:restart)
          expect(File.exist?(carry_file)).to be(false)
        end

        it "takes a later exit request as the one already leaving, so a stop-all can't undo the restart" do
          engine.reminder_store.register(name: "api_health", description: "check the API", interval_minutes: 20)
          start_worker(poll_interval: 0.05)
          policy = @worker.instance_variable_get(:@idle_exit)
          worker = @worker
          looks = 0
          allow(policy).to receive(:hold_for_restart) do
            looks += 1
            # A stop-all that came in after the restart was taken, before the leave.
            worker.send(:exit_request, "tui:1", stop: true) if looks == 2
            nil
          end

          expect(post_restart.first).to eq(200)
          expect(join!(@thread, "the worker").value).to eq(:restart)
          expect(engine.reminder_store.reminders.keys).to eq(["api_health"])
          expect(JSON.parse(File.read(carry_file))["reminders"].map { |r| r["name"] }).to eq(["api_health"])
        end

        it "stays up with its reminders when the hand-off can't be written" do
          engine.reminder_store.register(name: "api_health", description: "check the API", interval_minutes: 20)
          allow(Samagotchi::ReminderCarry).to receive(:write).and_raise(Errno::ENOSPC)
          start_worker(poll_interval: 0.05)

          expect(post_restart.first).to eq(200)
          loop_rounds
          expect(@thread).to be_alive
          expect(engine.reminder_store.reminders.keys).to eq(["api_health"])
        end

        it "restores nothing into a stopped session's worker, and deletes the hand-off" do
          File.write(carry_file, JSON.generate("session_id" => session.id, "written_at" => Time.now.utc.iso8601(3),
                                               "reminders" => [{ "id" => "a1", "name" => "late", "description" => "d",
                                                                 "interval_minutes" => 5,
                                                                 "next_fire_at" => Time.now.utc.iso8601(3) }]))
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
          hold_worker(session_dir)
          worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                       idle_exit_minutes: 0, poll_interval: 0.05)
          @thread = Thread.new { worker.run }

          expect(join!(@thread, "the worker").value).to eq(:stopped)
          expect(File.exist?(carry_file)).to be(false)
          expect(engine.reminder_store.any?).to be(false)
        end

        it "restores nothing from another session's hand-off, or one too old, and deletes it" do
          [{ "session_id" => "99999999-2222-3333-4444-555555555555", "written_at" => Time.now.utc.iso8601(3) },
           { "session_id" => session.id, "written_at" => (Time.now - 3600).utc.iso8601(3) }].each do |head|
            File.write(carry_file, JSON.generate(head.merge("reminders" => [
              { "id" => "a1", "name" => "stale", "description" => "d", "interval_minutes" => 5,
                "next_fire_at" => Time.now.utc.iso8601(3) }
            ])))
            start_worker(poll_interval: 0.05)
            expect(File.exist?(carry_file)).to be(false)
            expect(engine.reminder_store.any?).to be(false)
            expect(post_restart.first).to eq(200)
            join!(@thread, "the worker")
          end
        end

        it "stays up while a question waits, and checks again as it leaves" do
          start_worker(poll_interval: 0.05)
          allow(engine).to receive(:pending_question).and_return({ id: "q1" })
          expect(post_restart.last).to include("status" => "held", "reason" => "question_pending")
          loop_rounds
          expect(@thread).to be_alive

          allow(engine).to receive(:pending_question).and_return(nil)
          policy = @worker.instance_variable_get(:@idle_exit)
          allow(policy).to receive(:hold_for_restart).and_return(nil, :input_queued)
          expect(post_restart.first).to eq(200)
          loop_rounds
          expect(@thread).to be_alive # held at the second look, as it left
        end
      end

      it "answers :starting before the idle-exit policy exists" do
        worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir)
        expect(worker.send(:exit_request, "tui:1")).to eq(Samagotchi::WorkerIdleExit::Hold.new(reason: :starting))
      end
    end

    describe "a failed turn" do
      let(:kernel) { engine.instance_variable_get(:@kernel) }
      let(:events) { Queue.new }
      let(:earlier) { [{ role: "system", content: "sys" }, { role: "user", content: "earlier" }, { role: "model", content: "ok" }] }

      before do
        allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
        allow(engine).to receive(:run_turn).and_call_original
        # The Engine keeps the failed prompt in the session (and saves it);
        # the worker must take it out again.
        allow(kernel).to receive(:run) do |messages, **|
          prompt = messages.last[:content]
          turns << [prompt, mono]
          SpecWaiting.pop!(@boom_gate, "the example to queue the next prompt", timeout: 30) if @boom_gate && prompt == "boom"
          if %w[steps overflow].include?(prompt)
            # Two tool steps, then the host refuses the next request (402,
            # or a 400 context overflow).
            steps = [{ role: "model", content: "", tool_calls: [{ id: "c1", name: "execute", arguments: {} }] },
                     { role: "tool_response", content: "[execute]\nstep1", tool_call_id: "c1" },
                     { role: "model", content: "", tool_calls: [{ id: "c2", name: "execute", arguments: {} }] },
                     { role: "tool_response", content: "[execute]\nstep2", tool_call_id: "c2" }]
            error = if prompt == "overflow"
                      Samagotchi::LLM::BadRequest.new("main: HTTP 400: exceeds the context", host: "main", status: 400,
                                                                                             context_overflow: true)
                    else
                      Samagotchi::LLM::OutOfCredits.new("main: HTTP 402: Insufficient credits", host: "main", status: 402)
                    end
            raise Samagotchi::LLM::FailedTurn.attach(error, messages.map(&:dup) + steps)
          end
          raise Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500) unless prompt == "fine"

          Samagotchi::LLM::ModelResult.new(text: "FINE", conversation: messages + [{ role: "model", content: "FINE" }],
                                           exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
        end
        session.messages = earlier
        session.save(state_dir: tmpdir)
        engine.subscribe(observer: ->(event) { events << event })
      end

      def drain_events
        list = []
        list << events.pop until events.empty?
        list
      end

      def saved_messages
        Samagotchi::Session.load(session.id, state_dir: tmpdir).messages.map { |m| m[:content] }
      end

      def conversation = engine.messages_checkpoint.map { |m| m[:content] }

      it "keeps the worker up, puts the conversation back and gives the prompt back to its sender" do
        start_worker(poll_interval: 5)

        post_turn("boom")
        expect(next_turn&.first).to eq("boom")
        seen = []
        wait_for("the prompt_restored event") { (seen += drain_events).any? { |e| e[:type] == :prompt_restored } }

        types = seen.map { |e| e[:type] }
        expect(types.index(:turn_failed)).to be < types.index(:prompt_restored)
        restored = seen.find { |e| e[:type] == :prompt_restored }
        expect(restored).to include(prompt: "boom")
        expect(restored[:origin]).to include(:enqueued_id)
        expect(conversation.first(3)).to eq(%w[sys earlier ok])
        expect(conversation.last).to include("failed before any answer").and include("went back to the user")
        expect(conversation.length).to eq(4)
        wait_for("the failed prompt taken out of the session") { saved_messages.first(3) == %w[sys earlier ok] && saved_messages.length == 4 }
        expect(@thread).to be_alive

        post_turn("fine")
        expect(next_turn&.first).to eq("fine")
        wait_for("the fine turn to be saved") { saved_messages.drop(1).grep_v(/\A\[SYSTEM: /) == %w[earlier ok fine FINE] }
        expect(saved_messages[3]).to start_with("[SYSTEM: the previous turn failed")
      end

      it "keeps a turn that failed after tool steps: saved with its steps, no prompt handed back, !rollback still erases it" do
        start_worker(poll_interval: 5)

        post_turn("steps")
        expect(next_turn&.first).to eq("steps")
        seen = []
        wait_for("the turn_failed event") { (seen += drain_events).any? { |e| e[:type] == :turn_failed } }
        expect(seen.find { |e| e[:type] == :turn_failed }).to include(error_kind: :credits, kept_steps: 2)
        # The system head is the Engine's own prompt now (the turn's).
        kept = ["earlier", "ok", "steps", "", "[execute]\nstep1", "", "[execute]\nstep2"]
        wait_for("the failed turn's steps kept") { saved_messages.drop(1).first(7) == kept && saved_messages.length == 9 }
        expect(saved_messages.last).to eq("[SYSTEM: the previous turn failed after 2 tool steps: out of credits on host main: " \
                                          "HTTP 402: Insufficient credits; add credits, then send again. Its work so far " \
                                          "(tool calls, file changes) stays; the user's last message is not answered yet.]")
        expect(conversation.length).to eq(9)
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).last_turn.to_file).to include("outcome" => "failed", "kept_steps" => 2)
        expect(@thread).to be_alive

        # The next prompt continues from the kept steps.
        post_turn("fine")
        expect(next_turn&.first).to eq("fine")
        wait_for("the fine turn to be saved") { saved_messages.last == "FINE" }
        expect(saved_messages.drop(1).grep_v(/\A\[SYSTEM: /)).to eq(kept + %w[fine FINE])
        expect(seen + drain_events).to(satisfy { |events| events.none? { |e| e[:type] == :prompt_restored } })
      end

      it "rolls back a context overflow after tool steps and gives its prompt back, as before" do
        start_worker(poll_interval: 5)

        post_turn("overflow")
        expect(next_turn&.first).to eq("overflow")
        seen = []
        wait_for("the prompt_restored event") { (seen += drain_events).any? { |e| e[:type] == :prompt_restored } }
        expect(seen.find { |e| e[:type] == :turn_failed }).not_to have_key(:kept_steps)
        expect(seen.find { |e| e[:type] == :prompt_restored }).to include(prompt: "overflow")
        wait_for("the failed prompt taken out of the session") { saved_messages.first(3) == %w[sys earlier ok] && saved_messages.length == 4 }
        expect(saved_messages.last).to include("failed before any answer: the conversation is too long")
          .and include("went back to the user")
      end

      it "lets !rollback erase a kept failed turn" do
        start_worker(poll_interval: 5)

        post_turn("steps")
        wait_for("the failed turn's steps kept") { saved_messages.length == 9 }
        port = JSON.parse(File.read(sidecar))["port"]
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/command"),
                       JSON.generate(line: "!rollback", client_id: "web:1"), "Content-Type" => "application/json", **bridge_auth(sidecar))

        eventually { expect(saved_messages.drop(1)).to eq(%w[earlier ok]) }
      end

      it "rolls back with the event log held, so a snapshot sees the failed turn or its restore, not half of it" do
        held = []
        allow(engine).to receive(:rollback_to).and_wrap_original do |original, checkpoint|
          held << engine.instance_variable_get(:@session_observer).instance_variable_get(:@mutex).mon_owned?
          original.call(checkpoint)
        end
        start_worker(poll_interval: 5)

        post_turn("boom")

        wait_for("the checkpoint's save") { held.any? }
        expect(held).to eq([true])
      end

      it "runs a prompt queued behind the failed one" do
        @boom_gate = Queue.new
        start_worker(poll_interval: 5)

        post_turn("boom")
        expect(next_turn&.first).to eq("boom")
        post_turn("fine")
        @boom_gate << true

        expect(next_turn&.first).to eq("fine")
        wait_for("the queued fine turn to be saved") { saved_messages.drop(1).grep_v(/\A\[SYSTEM: /) == %w[earlier ok fine FINE] }
      end

      it "survives a failed initial prompt too" do
        session.messages = []
        session.last_prompt = "boom"
        session.save(state_dir: tmpdir)

        start_worker(poll_interval: 5)

        expect(next_turn&.first).to eq("boom")
        seen = []
        wait_for("the prompt_restored event") { (seen += drain_events).any? { |e| e[:type] == :prompt_restored } }
        expect(seen.find { |e| e[:type] == :prompt_restored }).to include(prompt: "boom", origin: nil)
        expect(@thread).to be_alive
        wait_for("the failed initial prompt's note") { saved_messages.length == 1 && saved_messages.first.start_with?("[SYSTEM: the previous turn failed") }
      end
    end

    describe "a session file's parent_answers that isn't a level" do
      let(:seen) { [] }

      before { engine.subscribe(observer: ->(event) { seen << event }) }

      def warnings = seen.select { |e| e[:type] == :guardrail_warning && e[:label] == "parent_answers" }

      it "warns once as the worker loads it: hard applies" do
        session.parent_answers = "sofft"
        session.save(state_dir: tmpdir)
        start_worker(poll_interval: 5)

        expect(warnings.map { |e| e[:message] })
          .to eq(["parent_answers \"sofft\" in session #{session.id} isn't hard/standard/soft; hard applies"])
        post_turn("hello")
        wait_for("a turn") { !turns.empty? }
        expect(warnings.size).to eq(1)
      end

      it "says nothing for a level or none" do
        session.parent_answers = "soft"
        session.save(state_dir: tmpdir)
        start_worker(poll_interval: 5)

        expect(warnings).to be_empty
      end
    end

    describe "a turn that runs out of iterations" do
      let(:kernel) { engine.instance_variable_get(:@kernel) }
      let(:events) { Queue.new }
      let(:seen) { [] }

      before do
        allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
        allow(engine).to receive(:run_turn).and_call_original
        allow(kernel).to receive(:run) do |messages, **|
          prompt = messages.last[:content]
          turns << [prompt, mono]
          if prompt == "long task"
            Samagotchi::LLM::ModelResult.new(
              text: "", conversation: messages + [{ role: "model", content: "calling ls" }, { role: "tool_response", content: "a b" }],
              exhausted: true, pending_tool_calls: true, canceled: false,
              tool_activity: [{ tool: "execute", status: "ok", params: 'command="ls"' }]
            )
          else
            Samagotchi::LLM::ModelResult.new(text: "OK", conversation: messages + [{ role: "model", content: "OK" }],
                                             exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
          end
        end
        engine.subscribe(observer: ->(event) { events << event })
      end

      def saw?(type)
        seen << events.pop until events.empty?
        seen.any? { |e| e[:type] == type }
      end

      def saved_messages
        Samagotchi::Session.load(session.id, state_dir: tmpdir).messages.drop(1).map { |m| m[:content] }
      end

      def bridge_snapshot
        port = JSON.parse(File.read(sidecar))["port"]
        JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{port}/session/#{session.id}/snapshot"), bridge_auth(sidecar)))["snapshot"]
      end

      it "offers to continue it, from its tool results (no [No response] placeholder)" do
        start_worker(poll_interval: 5)

        post_turn("long task")

        wait_for("the continue offer") { saw?(:continue_offered) }
        offered = seen.find { |e| e[:type] == :continue_offered }
        expect(offered[:context]).to eq(original_prompt: "long task", tool_trace: ['execute status=ok params=command="ls"'],
                                        last_model_intent: "calling ls")
        expect(offered[:no_interrupt]).to be(false)
        expect(bridge_snapshot["continue_offer"]).to include("context" => include("original_prompt" => "long task"))
        wait_for("the turn to be saved") { saved_messages == ["long task", "calling ls", "a b"] }
      end

      it "holds a parent agent's /continue yes (cli:answer) to guardrails.parent_answers: hard refuses it, a person's goes" do
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("guardrails.parent_answers").and_return("hard")
        start_worker(poll_interval: 5)
        post_turn("long task")
        wait_for("the continue offer") { saw?(:continue_offered) }

        port = JSON.parse(File.read(sidecar))["port"]
        post = lambda do |client_id|
          Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/command"),
                         JSON.generate(line: "/continue yes", client_id: client_id), "Content-Type" => "application/json", **bridge_auth(sidecar))
        end
        post.call("cli:answer")
        wait_for("the /continue command to run") { seen.any? { |e| e[:type] == :command_ran } if saw?(:command_ran) }
        ran = seen.find { |e| e[:type] == :command_ran }
        expect(ran).to include(status: "error")
        expect(ran[:output]).to include("a parent agent may only stop this turn here (guardrails.parent_answers: hard)")
        expect(saw?(:continue_resolved)).to be(false)
        expect(bridge_snapshot["continue_offer"]).not_to be_nil

        post.call("web:1")
        wait_for("the continue_resolved event") { saw?(:continue_resolved) }
        expect(seen.find { |e| e[:type] == :continue_resolved }).to include(decision: "resume", client_id: "web:1")
      end

      it "drops the offer when a new prompt is taken, keeping the partial turn (D2)" do
        start_worker(poll_interval: 5)
        post_turn("long task")
        wait_for("the continue offer") { saw?(:continue_offered) }

        port = JSON.parse(File.read(sidecar))["port"]
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/turn"),
                       JSON.generate(session_id: session.id, prompt: "something else", client_id: "web:1"),
                       "Content-Type" => "application/json", **bridge_auth(sidecar))

        wait_for("the second turn to complete") { saw?(:turn_completed) && seen.count { |e| e[:type] == :turn_completed } == 2 }
        types = seen.map { |e| e[:type] }
        resolved = seen.find { |e| e[:type] == :continue_resolved }
        expect(resolved).to include(decision: "dropped", client_id: "web:1")
        expect(types.index(:continue_resolved)).to be < types.rindex(:turn_started)
        expect(bridge_snapshot["continue_offer"]).to be_nil
        wait_for("the continued turn to be saved") { saved_messages == ["long task", "calling ls", "a b", "something else", "OK"] }
      end

      it "drops the offer when a reminder turn runs, so a later no can't roll the reminder's exchange back" do
        start_worker(poll_interval: 5)
        post_turn("long task")
        wait_for("the continue offer") { saw?(:continue_offered) }

        allow(engine).to receive(:reminders_due?).and_return(true)
        @reminder_callback.call(["stretch"])

        wait_for("the second turn to complete") { seen.count { |e| e[:type] == :turn_completed } == 2 if saw?(:turn_completed) }
        types = seen.map { |e| e[:type] }
        expect(seen.find { |e| e[:type] == :continue_resolved }).to include(decision: "dropped", client_id: "system:reminder")
        expect(types.index(:continue_resolved)).to be < types.rindex(:turn_started)
        expect(bridge_snapshot["continue_offer"]).to be_nil
        expect(@worker.instance_variable_get(:@turn_flow).awaiting_continue?).to be(false)
        # A !rollback sent the moment the reminder's turn_completed arrives,
        # as a UI would: the worker runs it on its loop, after the reminder
        # turn closed the rollback window (calling TurnFlow#rollback! from
        # here raced that close).
        port = JSON.parse(File.read(sidecar))["port"]
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/command"),
                       JSON.generate(line: "!rollback", client_id: "web:1"), "Content-Type" => "application/json", **bridge_auth(sidecar))
        wait_for("the command to run") { saw?(:command_ran) }
        expect(seen.find { |e| e[:type] == :command_ran }).to include(line: "!rollback", output: "nothing to rollback")
      end
    end

    describe "commands (POST /session/:id/command)" do
      let(:kernel) { engine.instance_variable_get(:@kernel) }
      let(:events) { Queue.new }
      let(:seen) { [] }
      let(:release) { Queue.new }

      before do
        allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
        allow(engine).to receive(:run_turn).and_call_original
        allow(kernel).to receive(:run) do |messages, **kwargs|
          prompt = messages.last[:role] == "user" ? messages.last[:content] : :continue
          turns << [prompt, mono, kwargs]
          case prompt
          when "slow"
            release.pop
            kwargs[:pending_input]&.call # an iteration boundary
          when "slow, no boundary", "slow, then canceled"
            release.pop
          end
          if prompt == "long task"
            Samagotchi::LLM::ModelResult.new(text: "", conversation: messages + [{ role: "tool_response", content: "r1" }],
                                             exhausted: true, pending_tool_calls: true, tool_activity: [], canceled: false)
          elsif ["cancel me", "slow, then canceled"].include?(prompt)
            Samagotchi::LLM::ModelResult.new(text: "", conversation: messages + [{ role: "model", content: "Partial\n[interrupted]" }],
                                             exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: true,
                                             cancellation_reason: :manual)
          else
            Samagotchi::LLM::ModelResult.new(text: "OK", conversation: messages + [{ role: "model", content: "OK" }],
                                             exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
          end
        end
        engine.subscribe(observer: ->(event) { events << event })
      end

      def port = JSON.parse(File.read(sidecar))["port"]

      def post_command(line, client_id: "tui:9", session_id: session.id, card: nil)
        body = { line: line, client_id: client_id }
        body[:card] = card unless card.nil?
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session_id}/command"),
                       JSON.generate(body), "Content-Type" => "application/json", **bridge_auth(sidecar))
      end

      def events_seen
        seen << events.pop until events.empty?
        seen
      end

      def ran(command_id, timeout: 5)
        wait_for("command #{command_id} to run", timeout: timeout) do
          events_seen.any? { |e| e[:type] == :command_ran && e[:command_id] == command_id }
        end
        seen.find { |e| e[:type] == :command_ran && e[:command_id] == command_id }
      end

      def saved_messages
        Samagotchi::Session.load(session.id, state_dir: tmpdir).messages.drop(1).map { |m| m[:content] }
      end

      it "runs a command on the worker and tells every UI: command_queued at once, then command_ran" do
        start_worker(poll_interval: 5)

        reply = post_command("/model")

        expect(reply.code).to eq("202")
        command_id = JSON.parse(reply.body)["command_id"]
        done = ran(command_id)
        expect(done).to include(client_id: "tui:9", line: "/model", status: "ok", changed: [], model_name: "Gemma-4B-it",
                                output: "runtime model: Gemma-4B-it (profile=gemma4, name)")
        queued = seen.find { |e| e[:type] == :command_queued }
        expect(queued).to include(command_id: command_id, client_id: "tui:9", line: "/model")
        expect(queued[:event_seq]).to be < done[:event_seq]
      end

      # P3: tightening from anyone; loosening only from a user at a UI (a
      # web tab, a chi TUI), never chi send, chi answer's marker, a
      # delegate's follow-up, a plugin or an unmarked input.
      it "lets only a user at a UI loosen /parent-answers; anyone tightens; the session file keeps it" do
        session.parent_answers = "hard"
        session.save(state_dir: tmpdir)
        start_worker(poll_interval: 5)
        stored = -> { Samagotchi::Session.load(session.id, state_dir: tmpdir).parent_answers }

        ["cli:send", "cli:answer", "delegate:abcd1234", "plugin", nil].each do |client_id|
          done = ran(JSON.parse(post_command("/parent-answers soft", client_id: client_id).body)["command_id"])
          expect(done).to include(status: "error"), client_id.inspect
          expect(done[:output]).to include("loosening parent_answers is the user's"), client_id.inspect
        end
        # The same line as a message (chi send -m, /queue TEXT): the Bridge runs it as the command, with its client.
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/turn"),
                       JSON.generate(session_id: session.id, prompt: "/parent-answers soft", client_id: "cli:answer"),
                       "Content-Type" => "application/json", **bridge_auth(sidecar))
        wait_for("the sixth command_ran") { events_seen.count { |e| e[:type] == :command_ran } >= 6 }
        expect(seen.select { |e| e[:type] == :command_ran }.last).to include(status: "error")
        expect(stored.call).to eq("hard")

        done = ran(JSON.parse(post_command("/parent-answers standard", client_id: "web:1").body)["command_id"])
        expect(done).to include(status: "ok", changed: ["parent_answers"])
        wait_for("parent_answers standard to be saved") { stored.call == "standard" }
        done = ran(JSON.parse(post_command("/parent-answers hard", client_id: "cli:send").body)["command_id"])
        expect(done).to include(status: "ok", changed: ["parent_answers"])
        wait_for("parent_answers hard to be saved") { stored.call == "hard" }
        done = ran(JSON.parse(post_command("/parent-answers default", client_id: "tui:9").body)["command_id"])
        expect(done).to include(status: "ok")
        wait_for("parent_answers to be cleared") { stored.call.nil? }
      end

      it "runs /llm-context: the session keeps its own values, and the command_ran carries what the next turn runs under" do
        start_worker(poll_interval: 5)

        done = ran(JSON.parse(post_command("/llm-context strategy stale budget 64k").body)["command_id"])

        expect(done).to include(status: "ok", changed: ["llm_context"])
        expect(done[:llm_context]).to include(strategy: "stale", strategy_source: "session", budget_tokens: 64_000,
                                              own: { "strategy" => ["stale"], "budget_tokens" => 64_000 })
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).llm_context)
          .to eq(Samagotchi::LLMContextOverride.new(strategy: [:stale], budget_tokens: 64_000))
        shown = ran(JSON.parse(post_command("/llm-context").body)["command_id"])
        expect(shown).not_to have_key(:llm_context)
        # A /model switch may change it (the model's own llm_context_strategy): the chip follows.
        switched = ran(JSON.parse(post_command("/model clear").body)["command_id"])
        expect(switched).to include(changed: ["model"])
        expect(switched[:llm_context]).to include(strategy: "stale", strategy_source: "session")
        expect(shown[:output]).to start_with("llm context: stale (the session)")
      end

      it "runs /thinking: the session keeps its own level, and the command_ran carries the level the next turn runs at" do
        start_worker(poll_interval: 5)

        done = ran(JSON.parse(post_command("/thinking low").body)["command_id"])

        expect(done).to include(status: "ok", changed: ["thinking"])
        expect(done[:thinking]).to eq(level: "low", source: "session", own: "low")
        expect(done[:output]).to start_with("thinking: low (session)\nFrom the next turn's start")
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).thinking).to eq(:low)
        shown = ran(JSON.parse(post_command("/thinking").body)["command_id"])
        expect(shown).not_to have_key(:thinking)
        expect(shown[:output]).to eq("thinking: low (session)")
        switched = ran(JSON.parse(post_command("/model clear").body)["command_id"])
        expect(switched[:thinking]).to include(level: "low", source: "session")
      end

      it "runs /toolkit: saved in the session, and the command_ran carries the chip's summary (nil on full)" do
        start_worker(poll_interval: 5)

        done = ran(JSON.parse(post_command("/toolkit lean").body)["command_id"])

        expect(done).to include(status: "ok", changed: ["toolkit"])
        expect(done[:toolkit]).to include(name: "lean", label: "lean", fallback: nil)
        expect(done[:toolkit][:left_out]).to include("delegate", "list_sessions")
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).toolkit).to eq(Samagotchi::Toolkit.new(name: "lean"))
        shown = ran(JSON.parse(post_command("/toolkit").body)["command_id"])
        expect(shown).not_to have_key(:toolkit)
        back = ran(JSON.parse(post_command("/toolkit full").body)["command_id"])
        expect(back).to have_key(:toolkit)
        expect(back[:toolkit]).to be_nil
      end

      it "runs /reasoning-history: the session keeps its own level, and the command_ran carries the level (nil on a native host)" do
        start_worker(poll_interval: 5)

        done = ran(JSON.parse(post_command("/reasoning-history all").body)["command_id"])

        expect(done).to include(status: "ok", changed: ["reasoning_history"])
        # This spec's model runs on the native loop, which ignores the level: the web hides its chip.
        expect(done).to have_key(:reasoning_history)
        expect(done[:reasoning_history]).to be_nil
        expect(done[:output]).to start_with("reasoning history: all (session)")
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).reasoning_history).to eq(:all)
        shown = ran(JSON.parse(post_command("/reasoning-history").body)["command_id"])
        expect(shown).not_to have_key(:reasoning_history)

        allow(engine).to receive(:reasoning_history_explained)
          .and_return(Samagotchi::SettingExplained.new(level: :all, source: "session", own: :all))
        switched = ran(JSON.parse(post_command("/model clear").body)["command_id"])
        expect(switched[:reasoning_history]).to eq(level: "all", source: "session", own: "all")
      end

      it "runs a plugin command, and the cards it shows follow its command_ran (as its output)" do
        engine.command_registry.register("/hi", "greet", source: "b") do |_args|
          engine.show_card(source: "b", title: "Hi card")
          "hi"
        end
        start_worker(poll_interval: 5)

        command_id = JSON.parse(post_command("/hi").body)["command_id"]
        done = ran(command_id)
        wait_for("the command's card") { events_seen.any? { |e| e[:type] == :card } }
        card = seen.find { |e| e[:type] == :card }
        expect(done).to include(status: "ok", output: "hi")
        expect(card).to include(title: "Hi card", in_turn: false)
        expect(card[:event_seq]).to eq(done[:event_seq] + 1)
      end

      it "marks a card's action card: true on its command_queued and command_ran (the UIs show no echo)" do
        start_worker(poll_interval: 5)

        command_id = JSON.parse(post_command("/model", card: true).body)["command_id"]
        done = ran(command_id)
        queued = seen.find { |e| e[:type] == :command_queued && e[:command_id] == command_id }
        expect([queued[:card], done[:card]]).to eq([true, true])
        plain = ran(JSON.parse(post_command("/model", card: "yes").body)["command_id"])
        expect(plain).not_to have_key(:card)
      end

      # chi send --new -m "/model x", the web start page's first message.
      it "runs a session command given as the first prompt as the command; the session is idle after it" do
        session.messages = []
        session.last_prompt = "/model Qwen3-14B"
        session.status = Samagotchi::Session::STATUS_RUNNING
        session.save(state_dir: tmpdir)

        start_worker(poll_interval: 5)

        wait_for("the command to run") { events_seen.any? { |e| e[:type] == :command_ran } }
        done = seen.find { |e| e[:type] == :command_ran }
        expect(done).to include(line: "/model Qwen3-14B", status: "ok", model_name: "Qwen3-14B", client_id: nil)
        expect(turns).to be_empty
        saved = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        expect([saved.model_name, saved.status, saved.last_prompt]).to eq(["Qwen3-14B", Samagotchi::Session::STATUS_IDLE, ""])
      end

      describe "a failing save" do
        include_context "failing session saves"

        it "stays up when a first-prompt command's saves fail" do
          session.messages = []
          session.last_prompt = "/model Qwen3-14B"
          session.status = Samagotchi::Session::STATUS_RUNNING
          session.save(state_dir: tmpdir)
          saves_fail!

          start_worker(poll_interval: 5)

          wait_for("the command to run") { events_seen.any? { |e| e[:type] == :command_ran } }
          expect(seen.find { |e| e[:type] == :command_ran }).to include(line: "/model Qwen3-14B", model_name: "Qwen3-14B")
          expect(failed_saves).to include(:initial_prompt, :initial_command)
          expect(@thread).to be_alive

          saves_fail!(false)
          expect(ran(JSON.parse(post_command("/model").body)["command_id"])).to include(status: "ok")
        end

        it "stays up when the save after a command fails" do
          start_worker(poll_interval: 5)
          saves_fail!

          done = ran(JSON.parse(post_command("/model Qwen3-14B").body)["command_id"])

          expect(done).to include(model_name: "Qwen3-14B")
          wait_for("the command's save to fail") { failed_saves.include?(:command) }
          expect(@thread).to be_alive

          saves_fail!(false)
          post_turn("after")
          wait_for("the after turn to be saved") { saved_messages.include?("after") }
          expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).model_name).to eq("Qwen3-14B")
        end
      end

      # A message queued as a file while no worker was up (chi send).
      it "runs a session command from an input file as the command, for its sender" do
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "/model Qwen3-14B", client_id: "cli:send",
                                                                enqueued_id: "e1", state_dir: tmpdir)
        start_worker(poll_interval: 5)

        wait_for("the command to run") { events_seen.any? { |e| e[:type] == :command_ran } }
        expect(seen.find { |e| e[:type] == :command_ran }).to include(line: "/model Qwen3-14B", client_id: "cli:send",
                                                                      status: "ok")
        expect(turns).to be_empty
      end

      it "ends a wait for a command delivered through an input file" do
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "/model Qwen3-14B", client_id: "cli:send",
                                                                enqueued_id: "e1", state_dir: tmpdir)
        start_worker(poll_interval: 5)
        wait_for("the command to run") { events_seen.any? { |e| e[:type] == :command_ran } }
        expect(turns).to be_empty

        result = Samagotchi::ReplyWait.call(session.id, state_dir: tmpdir, cursor: nil, timeout: 0.1,
                                             poll_interval: 0.01, turn: "e1")

        expect([result.status, result.outcome]).to eq([:no_reply, "completed"])
      end

      it "runs a command an input file carries before the next file's turn, not busy" do
        ["one", "/model Qwen3-14B", "two"].each do |prompt|
          Samagotchi::SessionInbox.write_input(session_dir, prompt: prompt, client_id: "cli:send", now: next_stamp)
        end
        start_worker(poll_interval: 5)

        expect(next_turn&.first).to eq("one")
        expect(next_turn&.first).to eq("two")
        done = nil
        wait_for("the command to run") { done = events_seen.find { |e| e[:type] == :command_ran } }
        expect(done).to include(line: "/model Qwen3-14B", status: "ok")
        started_two = seen.index { |e| e[:type] == :turn_started && e[:prompt] == "two" }
        expect(seen.index(done)).to be < started_two
      end

      it "refuses lines that aren't commands, and other sessions" do
        start_worker(poll_interval: 5)

        expect(post_command("hello").code).to eq("400")
        expect(post_command("/stats").code).to eq("400")
        expect(post_command("/model", session_id: "other").code).to eq("404")
      end

      it "switches the model, saves it on the session and reports it" do
        start_worker(poll_interval: 5)

        done = ran(JSON.parse(post_command("/model Qwen3-14B").body)["command_id"])

        expect(done).to include(status: "ok", changed: ["model"], model_name: "Qwen3-14B")
        expect(engine.effective_model_name).to eq("Qwen3-14B")
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).model_name).to eq("Qwen3-14B")
        expect(engine.session_state_snapshot[:model_name]).to eq("Qwen3-14B")
      end

      it "runs !cmd in the worker and keeps its output for the next turn" do
        allow(Samagotchi::Tools::Execute).to receive(:call).with("echo hi", env: {}, on_timeout: :kill).and_return("hi\n")
        start_worker(poll_interval: 5)

        done = ran(JSON.parse(post_command("!echo hi").body)["command_id"])

        expect(done).to include(status: "ok", output: "hi\n", changed: ["messages"])
        saved = -> { Samagotchi::Session.load(session.id, state_dir: tmpdir).messages.map { |m| m[:content] } }
        wait_for("the shell command's output to be saved") { saved.call == ["!(echo hi)\nhi\n"] }
      end

      it "rolls a cancelled turn back with !rollback" do
        start_worker(poll_interval: 5)
        post_turn("cancel me")
        wait_for("the turn_canceled event") { events_seen.any? { |e| e[:type] == :turn_canceled } }

        done = ran(JSON.parse(post_command("!rollback").body)["command_id"])

        expect(done).to include(output: "salvaged turn discarded; restored pre-turn state", changed: ["messages"])
        wait_for("the canceled turn taken out of the session") { saved_messages.empty? }
      end

      it "refuses !rollback and /continue while a turn runs: at the turn's next iteration boundary" do
        start_worker(poll_interval: 5)
        post_turn("slow")
        expect(next_turn&.first).to eq("slow")

        rollback = JSON.parse(post_command("!rollback").body)["command_id"]
        continue = JSON.parse(post_command("/continue").body)["command_id"]
        release << true

        expect(ran(rollback)).to include(status: "busy", output: "busy: Ctrl-C the turn first, then !rollback")
        expect(ran(continue)).to include(status: "busy", output: "busy: wait for the turn to end")
        expect(ran(continue)).not_to have_key(:queued)
        # The released turn's end may still be on its way (a slow runner).
        wait_for("the turn_completed event") { events_seen.any? { |e| e[:type] == :turn_completed } }
        types = seen.map { |e| e[:type] }
        expect(types.index(:command_ran)).to be < types.index(:turn_completed)
        expect(seen.find { |e| e[:type] == :command_queued && e[:line] == "!rollback" }).not_to have_key(:waits)
      end

      # The turn-end warm-up (Engine#warm_up_next_turn) would prefill a
      # prompt the queued change throws away (all of it on Gemma).
      it "counts a command queued mid-turn (/thinking low) as a next turn waiting: no warm-up then" do
        start_worker(poll_interval: 5)
        expect(engine.next_turn_waiting.call).to be(false)
        post_turn("slow, no boundary")
        expect(next_turn&.first).to eq("slow, no boundary")

        # --yes: on this native Gemma, with a reply in the session, the change would ask first.
        command_id = JSON.parse(post_command("/thinking low --yes").body)["command_id"]
        wait_for("the queued command to count as a next turn waiting") { engine.next_turn_waiting.call }
        release << true

        expect(ran(command_id)).to include(status: "ok", changed: ["thinking"], queued: true)
        wait_for("the queued command to have run") { !engine.next_turn_waiting.call }
      end

      describe "a change that restarts the prompt cache (CacheConfirm)" do
        before { allow(engine).to receive_messages(thinking_cache_cost: :full, history?: true) }

        def post_turn_from(prompt, client_id)
          Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/turn"),
                         JSON.generate(session_id: session.id, prompt: prompt, client_id: client_id),
                         "Content-Type" => "application/json", **bridge_auth(sidecar))
        end

        def ran_line(line)
          wait_for("#{line} to run") { events_seen.any? { |e| e[:type] == :command_ran && e[:line] == line } }
          seen.find { |e| e[:type] == :command_ran && e[:line] == line }
        end

        it "asks a web tab or a TUI first: nothing changes, and the command_ran carries the line that applies it" do
          start_worker(poll_interval: 5)

          asked = ran(JSON.parse(post_command("/thinking low", client_id: "web:tab").body)["command_id"])
          expect(asked).to include(status: "ok", changed: [], confirm: { line: "/thinking low --yes",
                                                                         text: "Nothing changed yet: send `/thinking low --yes` to apply." })
          expect(asked).not_to have_key(:thinking)
          expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).thinking).to be_nil

          applied = ran(JSON.parse(post_command("/thinking low --yes", client_id: "web:tab").body)["command_id"])
          expect(applied).to include(changed: ["thinking"])
          expect(applied).not_to have_key(:confirm)
          expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).thinking).to eq(:low)
        end

        it "applies chi send's (POST /turn from cli:send) and a card's at once" do
          start_worker(poll_interval: 5)

          post_turn_from("/thinking low", "cli:send")
          expect(ran_line("/thinking low")).to include(changed: ["thinking"])
          expect(ran(JSON.parse(post_command("/thinking high", client_id: "web:tab", card: true).body)["command_id"]))
            .to include(changed: ["thinking"])
          expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).thinking).to eq(:high)
        end

        it "applies a command that came in an input file from chi send" do
          start_worker(poll_interval: 0.02)
          Samagotchi::SessionManager.write_turn_input(session.id, prompt: "/thinking off", client_id: "cli:send", state_dir: tmpdir)

          expect(ran_line("/thinking off")).to include(changed: ["thinking"])
          expect(ran_line("/thinking off")).not_to have_key(:confirm)
        end

        it "asks a web tab whose command waited for the running turn's end, once it ends" do
          start_worker(poll_interval: 5)
          post_turn("slow, no boundary")
          expect(next_turn&.first).to eq("slow, no boundary")

          command_id = JSON.parse(post_command("/thinking low", client_id: "web:tab").body)["command_id"]
          release << true

          expect(ran(command_id)).to include(queued: true, changed: [], confirm: include(line: "/thinking low --yes"))
        end
      end

      it "refuses while a turn runs: at the latest when it ends" do
        start_worker(poll_interval: 5)
        post_turn("slow, no boundary")
        expect(next_turn&.first).to eq("slow, no boundary")

        command_id = JSON.parse(post_command("!rollback").body)["command_id"]
        release << true

        expect(ran(command_id)).to include(status: "busy")
      end

      describe "a setting command or !cmd while a turn runs (queued)" do
        def started(prompt) = seen.index { |e| e[:type] == :turn_started && e[:prompt] == prompt }
        def ran_at(command_id) = seen.index { |e| e[:type] == :command_ran && e[:command_id] == command_id }

        it "waits for the turn's end, past its iteration boundaries, then runs marked queued" do
          start_worker(poll_interval: 5)
          post_turn("slow")
          expect(next_turn&.first).to eq("slow")

          command_id = JSON.parse(post_command("/model Qwen3-14B").body)["command_id"]
          release << true

          done = ran(command_id)
          expect(done).to include(status: "ok", changed: ["model"], model_name: "Qwen3-14B", queued: true)
          expect(seen.find { |e| e[:type] == :command_queued && e[:command_id] == command_id }).to include(waits: "turn_end")
          expect(seen.index { |e| e[:type] == :turn_completed }).to be < ran_at(command_id)
          expect(seen.count { |e| e[:type] == :command_ran }).to eq(1)
        end

        # D1: arrival order with prompts that become later turns.
        it "runs after a prompt sent before it and before one sent after it" do
          start_worker(poll_interval: 5)
          post_turn("slow, no boundary")
          expect(next_turn&.first).to eq("slow, no boundary")

          post_turn("before")
          command_id = JSON.parse(post_command("/model Qwen3-14B").body)["command_id"]
          post_turn("after")
          release << true

          expect(next_turn&.first).to eq("before")
          expect(next_turn&.first).to eq("after")
          expect(ran(command_id)).to include(status: "ok", queued: true)
          wait_for("the after turn to start") { started("after") }
          expect(started("before")).to be < ran_at(command_id)
          expect(ran_at(command_id)).to be < started("after")
        end

        # D4: running it would close the rollback window the turn left.
        it "drops a queued !cmd after a canceled turn, and still runs a queued /model" do
          start_worker(poll_interval: 5)
          post_turn("slow, then canceled")
          expect(next_turn&.first).to eq("slow, then canceled")

          shell = JSON.parse(post_command("!echo hi").body)["command_id"]
          model = JSON.parse(post_command("/model Qwen3-14B").body)["command_id"]
          release << true

          expect(ran(shell)).to include(status: "dropped", output: "turn canceled: !echo hi not run; send it again",
                                        queued: true)
          expect(ran(model)).to include(status: "ok", queued: true)
          rollback = ran(JSON.parse(post_command("!rollback").body)["command_id"])
          expect(rollback).to include(output: "salvaged turn discarded; restored pre-turn state")
        end

        it "is dropped, not left waiting, when the worker leaves (a stop)" do
          start_worker(poll_interval: 0.05)
          post_turn("slow, no boundary")
          expect(next_turn&.first).to eq("slow, no boundary")

          command_id = JSON.parse(post_command("/model Qwen3-14B").body)["command_id"]
          Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)
          release << true

          expect(join!(@thread, "the worker").value).to eq(:stopped)
          expect(ran(command_id)).to include(status: "dropped", queued: true,
                                             output: "dropped: the session's worker stopped before it ran")
        end

        # D1: an idle command that came just after the turn ended stays behind
        # one still waiting for a prompt sent before it.
        it "runs in arrival order: a ready command waits behind one still waiting for its prompt file" do
          worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir)
          queue = Thread::Queue.new
          waiting = cmd(command_id: "x", line: "/model X", mid_turn: :queue, after_file: "20261008000000000000001.json")
          queue << waiting << cmd(command_id: "y", line: "/model Y", mid_turn: :loop)
          File.write(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR, waiting.after_file), "{}")
          worker.instance_variable_set(:@command_queue, queue)
          worker.instance_variable_set(:@engine, engine)

          expect(worker.send(:next_ready_command)).to be_nil
          expect(queue.size).to eq(2)
          File.delete(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR, waiting.after_file))
          expect([worker.send(:next_ready_command), worker.send(:next_ready_command)].map(&:command_id)).to eq(%w[x y])
        end

        # Queued idle just as the turn began (on_command saw no turn running).
        it "marks one queued idle just before the turn began as waiting, and drops its !cmd after a canceled turn" do
          worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir)
          queue = Thread::Queue.new
          queue << cmd(command_id: "a", client_id: "web:1", line: "!ls", mid_turn: :loop, after_seq: 0)
          queue << cmd(command_id: "b", client_id: "web:1", line: "/model X", mid_turn: :loop, after_seq: 0)
          worker.instance_variable_set(:@command_queue, queue)
          worker.instance_variable_set(:@engine, engine)
          worker.instance_variable_set(:@turn_end_seq, 0)

          worker.send(:refuse_queued_commands, mid_turn: true)
          waits = events_seen.select { |e| e[:type] == :command_queued }
          expect(waits.map { |e| [e[:command_id], e[:waits]] }).to eq([%w[a turn_end], %w[b turn_end]])
          expect(events_seen.none? { |e| e[:type] == :command_ran }).to be(true)

          worker.instance_variable_set(:@turn_end_seq, engine.event_count + 1)
          worker.instance_variable_set(:@turn_end_type, :turn_canceled)
          worker.send(:refuse_queued_commands)
          expect(events_seen.find { |e| e[:type] == :command_ran })
            .to include(command_id: "a", status: "dropped", queued: true, output: "turn canceled: !ls not run; send it again")
          expect(queue.size).to eq(1)
          expect(queue.pop).to have_attributes(command_id: "b", mid_turn: :queue)
        end

        # P0: the filter holds the event log, so a command the Bridge queues
        # meanwhile (on_command, under that lock) stays behind the kept ones.
        it "keeps arrival order when refusing: a command queued during the filter goes behind the kept ones" do
          worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir)
          queue = Thread::Queue.new
          queue << cmd(command_id: "k1", client_id: "web:1", line: "/model X", mid_turn: :queue, after_seq: 0)
          queue << cmd(command_id: "r", client_id: "web:1", line: "!rollback", mid_turn: :refuse, after_seq: 0)
          queue << cmd(command_id: "k2", client_id: "web:1", line: "/model Y", mid_turn: :queue, after_seq: 0)
          worker.instance_variable_set(:@command_queue, queue)
          worker.instance_variable_set(:@engine, engine)
          worker.instance_variable_set(:@turn_end_seq, 0)
          arrival = nil
          allow(engine).to receive(:announce).and_wrap_original do |original, event, *rest|
            if event[:command_id] == "r" && arrival.nil?
              # The Bridge queues a command as the busy one is answered.
              arrival = Thread.new { engine.synchronize_events { queue << cmd(command_id: "n", line: "/model Z", mid_turn: :queue) } }
              wait_for("the arrival to wait for the event log") { arrival.status == "sleep" }
            end
            original.call(event, *rest)
          end

          worker.send(:refuse_queued_commands, mid_turn: true)
          join!(arrival, "the arrival")

          expect(events_seen.find { |e| e[:type] == :command_ran }).to include(command_id: "r", status: "busy")
          expect(Array.new(queue.size) { queue.pop.command_id }).to eq(%w[k1 k2 n])
        end

        it "is in the snapshot until it ran" do
          start_worker(poll_interval: 5)
          post_turn("slow, no boundary")
          expect(next_turn&.first).to eq("slow, no boundary")

          command_id = JSON.parse(post_command("/model Qwen3-14B").body)["command_id"]
          snapshot = -> { @worker.instance_variable_get(:@bridge).snapshot }
          during = snapshot.call
          release << true
          ran(command_id)

          expect(during[:queued_commands]).to eq([{ command_id: command_id, client_id: "tui:9", line: "/model Qwen3-14B" }])
          expect(snapshot.call[:queued_commands]).to eq([])
        end
      end

      describe "a show form (/model, /models, … alone) while a turn runs" do
        it "runs at once beside the turn, marked anytime, and a setting form waits for the turn's end" do
          allow(engine.host_registry).to receive(:list_all_models).and_return({})
          start_worker(poll_interval: 5)
          post_turn("slow, no boundary")
          expect(next_turn&.first).to eq("slow, no boundary")

          shown = ran(JSON.parse(post_command("/model").body)["command_id"])
          listed = ran(JSON.parse(post_command("/models qwen").body)["command_id"])
          still_running = engine.turn_running?
          setting = JSON.parse(post_command("/model Qwen3-14B").body)["command_id"]
          release << true

          expect(still_running).to be(true)
          expect(shown).to include(status: "ok", anytime: true, changed: [])
          expect(shown[:output]).to start_with("runtime model:")
          expect(listed).to include(status: "ok", output: "no hosts configured", anytime: true)
          expect(seen.find { |e| e[:type] == :command_queued && e[:line] == "/model" }).to include(anytime: true)
          expect(ran(setting)).to include(status: "ok", queued: true)
          queued = seen.find { |e| e[:type] == :command_queued && e[:line] == "/model Qwen3-14B" }
          expect(queued).to include(waits: "turn_end")
          expect(queued).not_to have_key(:anytime)
        end

        it "runs on the loop in order when idle: /model X then /model shows X" do
          start_worker(poll_interval: 5)
          switch = JSON.parse(post_command("/model Qwen3-14B").body)["command_id"]
          shown = ran(JSON.parse(post_command("/model").body)["command_id"])

          expect(ran(switch)).to include(status: "ok")
          expect(shown[:output]).to start_with("runtime model: Qwen3-14B")
          expect(shown).not_to have_key(:anytime)
          expect(seen.find { |e| e[:type] == :command_queued && e[:line] == "/model" }).not_to have_key(:anytime)
        end
      end

      describe "an anytime command (D8)" do
        before do
          engine.command_registry.register("/side", "a side question", anytime: true, source: "b") do |args|
            engine.show_card(source: "b", title: "side card")
            "side: #{args}"
          end
        end

        ["slow", "slow, no boundary"].each do |prompt|
          it "runs at once while a turn runs (#{prompt}), never busy, its cards announced between its queued and ran" do
            start_worker(poll_interval: 5)
            post_turn(prompt)
            expect(next_turn&.first).to eq(prompt)

            done = ran(JSON.parse(post_command("/side q").body)["command_id"])
            still_running = engine.turn_running?
            release << true

            expect(still_running).to be(true)
            expect(done).to include(status: "ok", output: "side: q")
            wait_for("the turn_completed event") { events_seen.any? { |e| e[:type] == :turn_completed } }
            card = seen.find { |e| e[:type] == :card }
            expect(card).to include(title: "side card", in_turn: false, anytime: true)
            queued = seen.find { |e| e[:type] == :command_queued }
            expect(queued).to include(line: "/side q", anytime: true)
            expect(queued[:event_seq]).to be < card[:event_seq]
            expect(card[:event_seq]).to be < done[:event_seq]
            expect(done).to include(anytime: true)
            expect(seen.count { |e| e[:type] == :command_ran }).to eq(1)
          end
        end

        it "is waited for as the worker leaves on /exit: its command_ran is announced (P2 (d))" do
          gate = Queue.new
          engine.command_registry.register("/slowside", "a slow side question", anytime: true, source: "b") do |_args|
            gate.pop
            "slow side done"
          end
          start_worker(poll_interval: 5)
          command_id = JSON.parse(post_command("/slowside").body)["command_id"]
          Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/exit"),
                         JSON.generate(client_id: "tui:9"), "Content-Type" => "application/json", **bridge_auth(sidecar))
          # In its teardown: the Engine's shutdown joins the command.
          wait_for("the worker to reach its Engine's shutdown") { @thread.backtrace.to_a.any? { |frame| frame.include?("shutdown'") } }
          expect(@thread).to be_alive # waiting for the command
          gate << true

          expect(join!(@thread, "the worker").value).to eq(:exit_requested)
          expect(ran(command_id)).to include(status: "ok", output: "slow side done", anytime: true)
        end

        # D3 of the session title plan: /title saves beside the turn, and the
        # turn's own saves keep it.
        it "names the session at once while a turn runs, and the turn's end save keeps the title" do
          start_worker(poll_interval: 5)
          post_turn("slow, no boundary")
          expect(next_turn&.first).to eq("slow, no boundary")

          done = ran(JSON.parse(post_command("/title Coordinator").body)["command_id"])
          during = Samagotchi::Session.load(session.id, state_dir: tmpdir)
          still_running = engine.turn_running?
          release << true

          expect(still_running).to be(true)
          expect(done).to include(status: "ok", output: "title: Coordinator", anytime: true, changed: ["title"],
                                  title: "Coordinator")
          expect(during).to have_attributes(title: "Coordinator", status: Samagotchi::Session::STATUS_RUNNING)
          wait_for("the turn to be saved") { saved_messages.include?("OK") }
          expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).title).to eq("Coordinator")
        end

        it "turns the recap off at once while a turn runs, saved beside it, and the turn's end save keeps it" do
          start_worker(poll_interval: 5)
          post_turn("slow, no boundary")
          expect(next_turn&.first).to eq("slow, no boundary")

          done = ran(JSON.parse(post_command("/recap off").body)["command_id"])
          during = Samagotchi::Session.load(session.id, state_dir: tmpdir)
          still_running = engine.turn_running?
          release << true

          expect(still_running).to be(true)
          expect(done).to include(status: "ok", anytime: true, changed: ["recap"])
          expect(engine.recap).to be_nil
          expect(during.settings.core).to eq("recap.enabled" => false)
          wait_for("the turn to be saved") { saved_messages.include?("OK") }
          expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).settings.core).to eq("recap.enabled" => false)
        end

        it "runs between turns too, and a normal command still waits its turn" do
          start_worker(poll_interval: 5)
          post_turn("slow, no boundary")
          expect(next_turn&.first).to eq("slow, no boundary")
          normal = JSON.parse(post_command("/model Qwen3-14B").body)["command_id"]
          side = ran(JSON.parse(post_command("/side").body)["command_id"])
          release << true

          expect(side).to include(status: "ok", output: "side: ")
          expect(ran(normal)).to include(status: "ok", queued: true)
          expect(ran(JSON.parse(post_command("/side again").body)["command_id"])).to include(status: "ok", output: "side: again")
        end
      end

      it "runs commands queued before a prompt first" do
        start_worker(poll_interval: 5)
        # Written without a wake (another process); the command wakes the loop.
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "after", state_dir: tmpdir)
        command_id = JSON.parse(post_command("/model").body)["command_id"]

        expect(next_turn&.first).to eq("after")
        types = events_seen.map { |e| e[:type] }
        expect(ran(command_id)).to include(status: "ok")
        expect(types.index(:command_ran)).to be < types.index(:turn_started)
      end

      describe "/continue" do
        before do
          allow(engine).to receive(:recap_awaiting_continue=) { |seam| @recap_offer_seam = seam }
          start_worker(poll_interval: 5)
          post_turn("long task")
          wait_for("the continue offer") { events_seen.any? { |e| e[:type] == :continue_offered } }
        end

        it "runs the continue turn on yes, for whoever answered" do
          done = ran(JSON.parse(post_command("/continue yes", client_id: "web:2").body)["command_id"])

          expect(done).to include(status: "ok")
          wait_for("the second turn to complete") { turns.size >= 2 && events_seen.count { |e| e[:type] == :turn_completed } == 2 }
          resolved = seen.find { |e| e[:type] == :continue_resolved }
          expect(resolved).to include(decision: "resume", client_id: "web:2")
          started = seen.select { |e| e[:type] == :turn_started }
          # The offer turn's id: the continue turn is that turn's.
          offer_id = started.first.dig(:origin, :enqueued_id)
          expect(offer_id).to be_a(String)
          expect(started.last).to include(continue: true, prompt: nil, origin: { client_id: "web:2", enqueued_id: offer_id })
          wait_for("the continued turn to be saved") { saved_messages == ["long task", "r1", "OK"] }
        end

        it "brings an archived session back when a user answers it" do
          Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir)
          ran(JSON.parse(post_command("/continue no", client_id: "web:2").body)["command_id"])

          # Un-archived after command_ran and the session's save: wait for it.
          eventually { expect(Samagotchi::ArchiveStore.archived?(session_dir)).to be(false) }
        end

        it "tells the recap an offer is open, and records activity when no ends it, so a new recap follows" do
          expect(@recap_offer_seam.call).to be(true)
          seq = engine.activity_seq
          ran(JSON.parse(post_command("/continue no").body)["command_id"])

          expect(@recap_offer_seam.call).to be(false)
          # Recorded after command_ran and the session's save: wait for it.
          wait_for("the activity mark") { engine.activity_seq > seq }
        end

        it "keeps the interrupted turn on no, with a note (D3)" do
          done = ran(JSON.parse(post_command("/continue no").body)["command_id"])

          expect(done).to include(output: "turn not continued; its work so far stays (!rollback erases it)", changed: ["messages"])
          expect(seen.find { |e| e[:type] == :continue_resolved }).to include(decision: "abort", client_id: "tui:9")
          wait_for("the not-continued note to be saved") { saved_messages == ["long task", "r1", Samagotchi::TurnNote.not_continued[:content]] }
        end

        it "asks again on anything else, with the offer still open" do
          done = ran(JSON.parse(post_command("/continue maybe").body)["command_id"])

          expect(done).to include(status: "error", output: "answer yes, no, or no, <reason>")
          expect(seen.map { |e| e[:type] }).not_to include(:continue_resolved)
        end
      end

      # The worker's pass found no command, then the answer's /continue yes
      # and a prompt both came in before it listed the input files (a slow
      # pass under parallel load): the command queued first still runs first.
      it "runs an answer's /continue queued before a prompt first, though both came in after the pass looked for commands" do
        start_worker(poll_interval: 5)
        inbound = @worker.instance_variable_get(:@inbound)
        armed = false
        reached = Queue.new
        gate = Queue.new
        engine.subscribe(observer: ->(event) { armed = true if event[:type] == :question_requested })
        # The pass absorbs notes after it ran the queued commands and before
        # it lists the input files: hold it there once the question is out.
        allow(inbound).to receive(:absorb_notes).and_wrap_original do |original, *args|
          if armed
            armed = false
            reached << true
            gate.pop
          end
          original.call(*args)
        end
        post_turn("long task")
        expect(pop!(reached, "the notes' look")).to be(true)

        asked = events_seen.find { |e| e[:type] == :question_requested }
        answer = Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/answer"),
                                JSON.generate(id: asked[:pending_question][:id], selected: ["Continue"], client_id: "web:2"),
                                "Content-Type" => "application/json", **bridge_auth(sidecar))
        expect(answer.code).to eq("200")
        post_turn("something else")
        gate << :go

        wait_for("the third turn to complete") { events_seen.count { |e| e[:type] == :turn_completed } == 3 }
        started = seen.select { |e| e[:type] == :turn_started }
        expect(started[1]).to include(continue: true)
        expect(started[2]).to include(prompt: "something else")
      end

      # The offer as a question on the desk (kind continue): what chi send
      # --wait, chi answer, the lists and the web's badge read.
      describe "the step-limit question" do
        before do
          start_worker(poll_interval: 5)
          post_turn("long task")
          wait_for("the continue question") { events_seen.any? { |e| e[:type] == :question_requested } }
        end

        def saved_session = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        def question = seen.find { |e| e[:type] == :question_requested }[:pending_question]

        def post_answer(selected, freeform: nil, client_id: "web:2", id: question[:id])
          Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/answer"),
                         JSON.generate(id: id, selected: selected, freeform: freeform, client_id: client_id),
                         "Content-Type" => "application/json", **bridge_auth(sidecar))
        end

        def continue_ran(line)
          wait_for("#{line} to run") { events_seen.any? { |e| e[:type] == :command_ran && e[:line] == line } }
          seen.find { |e| e[:type] == :command_ran && e[:line] == line }
        end

        it "opens after the turn's after_turn hooks ran (check-in closes its card there), so the two never stand together" do
          seen_by_hook = []
          engine.instance_variable_get(:@hooks).register_persistent(:after_turn) do |_event|
            seen_by_hook << engine.pending_question
          end
          # A second turn that runs out too: the first question went as it started.
          post_turn("long task")
          wait_for("the second continue question") { events_seen.count { |e| e[:type] == :question_requested } == 2 }

          expect(seen_by_hook).to eq([nil])
        end

        it "is pending in the file as the session goes idle, with the turn's limit, and no reply is written" do
          expect(question).to include(kind: "continue", header: "Step limit", options: %w[Continue Stop], limit: Samagotchi::IterationLimit::DEFAULT,
                                      allow_freeform: true)
          expect(question[:question])
            .to start_with("The turn ran out of iterations (#{Samagotchi::IterationLimit::DEFAULT} steps) before it answered. Continue it?")
          expect(question[:question]).to include("Prompt: long task")
          expect(seen.find { |e| e[:type] == :question_requested }).to include(standing: true)
          # Every save from the turn's end on has it: no idle write without it.
          wait_for("the session to be saved idle") { saved_session.status == "idle" }
          expect(saved_session.pending_question).to have_attributes(id: question[:id], kind: "continue")
          expect(saved_session.last_turn.to_file).to include("exhausted" => true, "limit" => Samagotchi::IterationLimit::DEFAULT)
          expect(Samagotchi::ReplyWait.newest_reply(session.id, state_dir: tmpdir)).to be_nil
        end

        it "runs the continue turn on Continue, as a card's /continue yes for whoever answered" do
          expect(post_answer(["Continue"]).code).to eq("200")

          done = continue_ran("/continue yes")
          expect(done).to include(status: "ok", client_id: "web:2", card: true)
          wait_for("the second turn to complete") { events_seen.count { |e| e[:type] == :turn_completed } == 2 }
          expect(seen.find { |e| e[:type] == :continue_resolved }).to include(decision: "resume", client_id: "web:2")
          started = seen.select { |e| e[:type] == :turn_started }
          offer_id = started.first.dig(:origin, :enqueued_id)
          expect(started.last).to include(continue: true, origin: { client_id: "web:2", enqueued_id: offer_id })
          wait_for("the continued turn saved, its question gone") { saved_messages == ["long task", "r1", "OK"] && saved_session.pending_question.nil? }
          # Its last_turn and reply are the offer turn's: a wait on that turn gets them.
          expect(saved_session.last_turn.enqueued_id).to eq(offer_id)
          expect(Samagotchi::SessionInbox.reply_for(session_dir, offer_id)).to end_with("-#{offer_id}.txt")
        end

        # The continued turn's first boundary, as the kernel reads it.
        def answer_continue_with(text, client_id:)
          drained = Queue.new
          allow(kernel).to receive(:run) do |messages, pending_input:, **|
            drained << pending_input.call(at_answer: false)
            Samagotchi::LLM::ModelResult.new(text: "OK", conversation: messages + [{ role: "model", content: "OK" }],
                                             exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
          end
          expect(post_answer(["Continue"], freeform: text, client_id: client_id).code).to eq("200")
          wait_for("the second turn to complete") { events_seen.count { |e| e[:type] == :turn_completed } == 2 }
          drained.pop
        end

        it "runs the continue turn on Continue with a text, which joins that turn as a steer from the user" do
          expect(answer_continue_with("also check the specs", client_id: "web:2"))
            .to eq([{ text: "also check the specs", source: "user" }])
          # turn_completed goes out before the turn lets go (release_turn):
          # a steer is refused once no turn runs.
          wait_for("the turn to end") { !engine.turn_running? }
          expect(engine.steer("late", source: "x")).to be(false)
        end

        it "labels the steer as the parent agent's when chi answer sent the Continue" do
          expect(answer_continue_with("also check the specs", client_id: "cli:answer"))
            .to eq([{ text: "also check the specs", source: "parent_agent" }])
        end

        it "stops on Stop: no turn runs, last_turn says not_continued, and a wait on it ends" do
          baseline = Samagotchi::ReplyWait.baseline_of(saved_session, question_id: question[:id])
          waited = Thread.new do
            Samagotchi::ReplyWait.call(session.id, state_dir: tmpdir, cursor: nil, timeout: 5, poll_interval: 0.02,
                                                   baseline: baseline)
          end
          expect(post_answer(["Stop"], freeform: "enough for now", client_id: "cli:answer").code).to eq("200")

          expect(continue_ran("/continue no, enough for now")).to include(status: "ok")
          result = waited.value
          expect(result.to_h).to include(status: :no_reply, outcome: "not_continued")
          expect(Samagotchi::ParentReport.status(result)).to eq("not_continued")
          expect(Samagotchi::ParentReport.exit_status(result)).to eq(0)
          expect(turns.size).to eq(1)
          expect(saved_session.pending_question).to be_nil
        end

        it "ends a wait on the offer turn (turn:) at a Stop: its not_continued last_turn carries the turn's id" do
          offer_id = seen.find { |e| e[:type] == :turn_started }.dig(:origin, :enqueued_id)
          expect(Samagotchi::ReplyWait.own_turn(saved_session, session_dir: session_dir)).to eq(offer_id)
          baseline = Samagotchi::ReplyWait.baseline_of(saved_session, question_id: question[:id])
          waited = Thread.new do
            Samagotchi::ReplyWait.call(session.id, state_dir: tmpdir, cursor: nil, timeout: 5, poll_interval: 0.02,
                                                   baseline: baseline, turn: offer_id)
          end
          expect(post_answer(["Stop"], client_id: "cli:answer").code).to eq("200")

          expect(waited.value.to_h).to include(status: :no_reply, outcome: "not_continued")
          expect(saved_session.last_turn.enqueued_id).to eq(offer_id)
        end

        it "is withdrawn when a new prompt drops the offer, and the prompt runs" do
          post_turn("something else")

          wait_for("the second turn to complete") { events_seen.count { |e| e[:type] == :turn_completed } == 2 }
          expect(seen.find { |e| e[:type] == :question_cancelled }).to include(id: question[:id], reason: "dropped")
          expect(saved_session.pending_question).to be_nil
          expect(post_answer(["Continue"]).code).to eq("409")
        end

        it "is withdrawn when a typed /continue answers the offer" do
          ran(JSON.parse(post_command("/continue no").body)["command_id"])

          wait_for("the question to be cancelled") { events_seen.any? { |e| e[:type] == :question_cancelled } }
          expect(seen.find { |e| e[:type] == :question_cancelled }).to include(id: question[:id], reason: "answered")
          expect(engine.pending_question).to be_nil
        end

        it "lets the first of an answer and a prompt win: the answer queued first runs before the prompt" do
          expect(post_answer(["Continue"]).code).to eq("200")
          post_turn("something else")

          wait_for("the third turn to complete") { events_seen.count { |e| e[:type] == :turn_completed } == 3 }
          started = seen.select { |e| e[:type] == :turn_started }
          expect(started[1]).to include(continue: true)
          expect(started[2]).to include(prompt: "something else")
          expect(continue_ran("/continue yes")).to include(status: "ok")
        end

        it "is withdrawn when a reminder turn drops the offer" do
          allow(engine).to receive(:reminders_due?).and_return(true)
          @reminder_callback.call(["stretch"])

          wait_for("the second turn to complete") { events_seen.count { |e| e[:type] == :turn_completed } == 2 }
          expect(seen.find { |e| e[:type] == :question_cancelled }).to include(reason: "dropped")
          expect(engine.pending_question).to be_nil
        end

        it "gives way to a plugin's question asked meanwhile, and comes back once that is answered" do
          box = {}
          asker = Thread.new { box[:answer] = engine.open_question(question: "Which?", options: %w[A B], multi_select: false) }
          wait_for("the plugin's question") { engine.pending_question&.question == "Which?" }
          expect(events_seen.find { |e| e[:type] == :question_cancelled }).to include(id: question[:id], reason: "superseded")

          engine.answer_question(id: engine.pending_question.id, selected: ["A"])
          join!(asker, "the plugin's question")

          wait_for("the continue question again") { engine.pending_question&.kind == "continue" }
          expect(saved_session.pending_question).to have_attributes(kind: "continue")
          expect(post_answer(["Continue"], id: engine.pending_question.id).code).to eq("200")
          expect(continue_ran("/continue yes")).to include(status: "ok")
        end

        it "is asked again after a continue turn that failed, once" do
          allow(kernel).to receive(:run).and_raise(Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500))
          expect(post_answer(["Continue"]).code).to eq("200")

          wait_for("the second continue question") { events_seen.count { |e| e[:type] == :question_requested } == 2 }
          loop_rounds
          expect(events_seen.count { |e| e[:type] == :question_requested }).to eq(2)
          expect(engine.pending_question).to have_attributes(kind: "continue")
          expect(saved_session.pending_question).to have_attributes(kind: "continue")
        end

        it "is asked again, the worker running on, when the continue turn fails before it begins (its save)" do
          failed = false
          allow_any_instance_of(Samagotchi::Session).to receive(:save).and_wrap_original do |original, *args, **kwargs|
            # The save run_engine_turn makes as the session goes running.
            if !failed && original.receiver.status == Samagotchi::Session::STATUS_RUNNING
              failed = true
              raise Errno::ENOSPC, "session file"
            end
            original.call(*args, **kwargs)
          end
          expect(post_answer(["Continue"], freeform: "also X").code).to eq("200")

          wait_for("the second continue question") { events_seen.count { |e| e[:type] == :question_requested } == 2 }
          expect(failed).to be(true)
          expect(@thread).to be_alive
          expect(engine.pending_question).to have_attributes(kind: "continue")
          wait_for("the continue question to be saved") { saved_session.pending_question&.kind == "continue" }
          expect(saved_session.status).to eq("idle")
          expect(seen.map { |e| e[:type] }).not_to include(:turn_failed)
        end

        it "is asked again when the continue turn fails before it begins (the Engine's checkpoint)" do
          allow(engine).to receive(:messages_checkpoint).and_raise(IOError, "checkpoint")
          expect(post_answer(["Continue"]).code).to eq("200")

          wait_for("the second continue question") { events_seen.count { |e| e[:type] == :question_requested } == 2 }
          expect(@thread).to be_alive
          expect(engine.pending_question).to have_attributes(kind: "continue")
        end
      end
    end
  end

  describe "a resumed session under a no-default config" do
    around do |example|
      original = ENV.fetch("SAMAGOTCHI_DEFAULT_MODEL", nil)
      original_xdg = ENV["XDG_CONFIG_HOME"]
      Dir.mktmpdir("samagotchi-worker-no-default") do |dir|
        ENV["XDG_CONFIG_HOME"] = dir
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
        ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
        example.run
      ensure
        if original.nil?
          ENV.delete("SAMAGOTCHI_DEFAULT_MODEL")
        else
          ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
        end
        ENV["XDG_CONFIG_HOME"] = original_xdg
        Samagotchi::Config.reload!(cli_overrides: {}) rescue nil
        FileUtils.rm_rf(tmpdir) if defined?(tmpdir)
      end
    end

    let(:tmpdir) { Dir.mktmpdir("worker-no-default") }
    let!(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "splash:some-id", working_directory: tmpdir).tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

    it "starts without raising when the session has its own model" do
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
      worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                   idle_exit_minutes: 0.01, poll_interval: 0.1)
      thread = Thread.new { worker.run }
      thread.report_on_exception = false

      # Wait until the sidecar appears (engine is building) — main bug was here
      sidecar = File.join(session_dir, Samagotchi::WorkerSidecar::FILE)
      wait_for("the worker's sidecar") { File.exist?(sidecar) }

      # Mark stopped so the worker exits (no input would keep it waiting)
      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      expect(join!(thread, "the worker").value).to eq(:stopped)
    end
  end
end
