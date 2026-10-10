# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "net/http"
require "json"
require "support/test_kernel"
require "support/failing_saves"

require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/bridge_client"
require "samagotchi/worker"

RSpec.describe Samagotchi::Worker do
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
      sleep(0.05)
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
    def start_worker(poll_interval: 5, idle_exit_minutes: 0)
      worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                   idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
      @worker = worker
      @thread = Thread.new { worker.run }
      @thread.report_on_exception = false
      expect(wait_until { File.exist?(sidecar) }).to be(true)
      # Let the loop reach its wait.
      sleep(0.1)
    end

    def sidecar
      File.join(session_dir, Samagotchi::WorkerSidecar::FILE)
    end

    def post_turn(prompt)
      port = JSON.parse(File.read(sidecar))["port"]
      Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/turn"),
                     JSON.generate(session_id: session.id, prompt: prompt),
                     "Content-Type" => "application/json")
    end

    def next_turn(timeout: 2)
      turns.pop(timeout: timeout)
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

    it "drops a question a dead worker saved (its turn is gone) and saves, before its Engine sees the session" do
      session.pending_question = { id: "q1", question: "Which?", options: %w[a b] }
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.save(state_dir: tmpdir)

      start_worker

      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).pending_question).to be_nil
      expect(engine.session.pending_question).to be_nil
      expect(engine.pending_question).to be_nil
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

      prompt, started_at = next_turn(timeout: 5)
      expect(prompt).to eq("PING")
      expect(started_at - posted_at).to be < 5
    end

    it "picks up an input file written without a wake on the fallback tick" do
      start_worker(poll_interval: 0.2)

      Samagotchi::SessionManager.write_turn_input(session.id, prompt: "from another process", state_dir: tmpdir)

      expect(next_turn&.first).to eq("from another process")
    end

    it "runs a due reminder at once, as a continue turn with no user message (as the REPL)" do
      allow(engine).to receive(:reminders_due?).and_return(true)
      start_worker(poll_interval: 60)

      called_at = mono
      @reminder_callback.call(["stretch"])

      prompt, started_at, kwargs = next_turn(timeout: 5)
      expect(prompt).to be_nil
      expect(kwargs).to include(continue: true, origin: { client_id: "system:reminder" })
      expect(started_at - called_at).to be < 5
      expect(Dir.children(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))).to be_empty
      expect(engine.due_reminder_names).to be_empty
    end

    it "runs no reminder turn when a prompt's turn already took the due reminders (a stale latch)" do
      allow(engine).to receive(:reminders_due?).and_return(false)
      start_worker(poll_interval: 5)

      @reminder_callback.call(["stretch"])

      expect(next_turn(timeout: 0.5)).to be_nil
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

        expect(wait_until { !failed_saves.empty? }).to be(true)
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
        expect(wait_until { Samagotchi::Session.load(session.id, state_dir: tmpdir).pending_question.nil? }).to be(true)
      end

      it "stays up when taking its first prompt can't be saved" do
        session.messages = []
        session.last_prompt = "first"
        session.save(state_dir: tmpdir)
        saves_fail!

        start_worker(poll_interval: 5)

        # The turn's own saves fail too: the one before it keeps it from
        # beginning (logged as turn_not_begun), the worker stays up.
        expect(wait_until { failed_saves.include?(:turn) }).to be(true)
        expect(failed_saves.first).to eq(:initial_prompt)
        expect(@thread).to be_alive

        saves_fail!(false)
        post_turn("two")
        expect(next_turn&.first).to eq("two")
        # Taken: a later worker won't run it again.
        expect(wait_until { Samagotchi::Session.load(session.id, state_dir: tmpdir).last_prompt == "" }).to be(true)
      end
    end

    it "records a turn that failed before the Engine began it as last_turn, so a wait ends with no_reply" do
      allow(engine).to receive(:run_turn).and_raise(RuntimeError, "boom before the turn")
      start_worker
      baseline = Samagotchi::ReplyWait.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))

      post_turn("hi")
      expect(wait_until do
        s = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        s.status == "idle" && Samagotchi::TurnNote.trailing_index(s.messages)
      end).to be_truthy

      saved = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(saved.last_turn).to include("outcome" => "failed", "origin" => "client")
      result = Samagotchi::ReplyWait.call(session.id, state_dir: tmpdir, cursor: nil, timeout: 1, poll_interval: 0.02,
                                                      baseline: baseline)
      expect(result.to_h).to include(status: :no_reply, outcome: "failed")
    end

    describe "an archived session (ArchiveStore)" do
      def archived? = Samagotchi::ArchiveStore.archived?(session_dir)

      before { Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir) }

      %w[web:tab1 tui:4242 cli:send].each do |client_id|
        it "comes back to the lists on a prompt from #{client_id}" do
          start_worker(poll_interval: 0.2)
          Samagotchi::SessionManager.write_turn_input(session.id, prompt: "hi", client_id: client_id, state_dir: tmpdir)

          expect(next_turn&.first).to eq("hi")
          expect(archived?).to be(false)
        end
      end

      %w[delegate:1234abcd plugin].each do |client_id|
        it "stays archived on a turn from #{client_id}" do
          start_worker(poll_interval: 0.2)
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
        start_worker(poll_interval: 0.2)
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
        start_worker(poll_interval: 0.2)
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "task", client_id: "web:x", state_dir: tmpdir)

        lines = next_turn&.last
        expect(lines.map(&:source)).to eq(["chi_send", "parent_agent", nil, "plugin_send", nil])
        expect(lines.map(&:text)).to eq(["line 0", "line 1", "line 2", "line 3", "line 4"])

        conversation = []
        Samagotchi::Steer.inject!(conversation, -> { lines.first(1) }, iteration: 1, emit: ->(_) {}, cancel_controller: nil)
        expect(conversation).to eq([{ role: "user", kind: "input", source: "chi_send", content: "line 0" }])
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

        expect(next_turn(timeout: 5)&.last).to eq([Samagotchi::Steer::Line.new(text: "steer me", source: nil)])
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

      expect(@thread.join(2)&.value).to eq(:crashed)
      record = File.open(log) { |io| Samagotchi::LogLine.each_record(io).find { |r| r.event == "crashed" } }
      expect(record.to_h).to include(level: "ERROR", tag: "worker")
      expect(record.fields).to include("error" => "JSON::GeneratorError")
      expect(record.payload).to match(/worker\.rb:\d+:in [`'](Samagotchi::Worker#)?run'/) # 3.3: `run', 3.4+: 'Samagotchi::Worker#run'
      expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq("error")
    end

    it "still exits on a stop marked on disk" do
      start_worker(poll_interval: 0.05)

      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      expect(@thread.join(2)&.value).to eq(:stopped)
    end

    it "still leaves when idle" do
      start_worker(poll_interval: 0.05, idle_exit_minutes: 0.002)

      expect(@thread.join(2)&.value).to eq(:idle_exit)
      expect(File.exist?(sidecar)).to be(false)
    end

    it "shuts its Engine down as it idle-exits: the plugins' services stop" do
      stopped = []
      services = engine.instance_variable_get(:@services)
      services.add(Samagotchi::Plugin::Service.new("b:srv") { |svc| svc.on_stop { stopped << :srv } }).value
      start_worker(poll_interval: 0.05, idle_exit_minutes: 0.002)

      expect(@thread.join(2)&.value).to eq(:idle_exit)
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

      expect(@thread.join(2)&.value).to eq(:idle_exit)
      expect(engine).to have_received(:write_recap_now)
    end

    describe "an exit request (POST /exit)" do
      def post_exit(client_id: "tui:1")
        port = JSON.parse(File.read(sidecar))["port"]
        res = Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/exit"),
                             JSON.generate(client_id: client_id), "Content-Type" => "application/json")
        [res.code.to_i, JSON.parse(res.body)]
      end

      after { Array(@streams).each(&:close) }

      it "leaves at once when nothing keeps it, even with idle exit off, and the session isn't stopped" do
        start_worker(poll_interval: 5, idle_exit_minutes: 0)

        expect(post_exit.first).to eq(200)
        expect(@thread.join(2)&.value).to eq(:exit_requested)
        expect(File.exist?(sidecar)).to be(false)
        expect(engine).to have_received(:stop_idle)
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).not_to eq(Samagotchi::Session::STATUS_STOPPED)
      end

      it "says the session is discarded when nothing happened in it, and leaves it for deleting" do
        allow(engine).to receive(:write_recap_now)
        start_worker(poll_interval: 5, idle_exit_minutes: 0)

        expect(post_exit.last).to include("discard" => true)
        expect(@thread.join(2)&.value).to eq(:exit_requested)
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
        expect(@thread.join(2)&.value).to eq(:exit_requested)
        expect(order).to eq([:stop_idle, [:recap, false]])
      end

      it "writes no recap for an exit that deletes the session (/exit --delete)" do
        session.model_name = "Qwen3-14B"
        session.save(state_dir: tmpdir)
        allow(engine).to receive(:write_recap_now)
        start_worker(poll_interval: 5, idle_exit_minutes: 0)
        port = JSON.parse(File.read(sidecar))["port"]
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/exit"),
                       JSON.generate(client_id: "tui:1", delete: true), "Content-Type" => "application/json")

        expect(@thread.join(2)&.value).to eq(:exit_requested)
        expect(engine).not_to have_received(:write_recap_now)
      end

      it "says it keeps a session on another model" do
        session.model_name = "Qwen3-14B"
        session.save(state_dir: tmpdir)
        start_worker(poll_interval: 5, idle_exit_minutes: 0)

        expect(post_exit.last).to include("discard" => false)
        @thread.join(2)
        expect(@worker.discard?).to be(false)
      end

      it "stays up while a turn runs" do
        start_worker(poll_interval: 0.05)
        allow(engine).to receive(:turn_running?).and_return(true)

        expect(post_exit).to eq([409, { "status" => "held", "reason" => "turn_running", "session_id" => session.id }])
        sleep(0.2)
        expect(@thread).to be_alive
      end

      def follow(client_id: nil)
        port = JSON.parse(File.read(sidecar))["port"]
        stream = Samagotchi::BridgeClient.new(session_id: session.id, port: port).follow(client_id: client_id) { |_| nil }
        (@streams ||= []) << stream
        stream
      end

      def open_streams = @worker.instance_variable_get(:@bridge).open_streams

      it "leaves while the asker's own stream is open" do
        start_worker(poll_interval: 0.05)
        follow(client_id: "tui:1")
        expect(wait_until { open_streams == 1 }).to be(true)

        expect(post_exit.first).to eq(200)
        expect(@thread.join(2)&.value).to eq(:exit_requested)
      end

      it "stays up while another client holds a stream" do
        start_worker(poll_interval: 0.05)
        follow(client_id: "tui:1")
        follow # a web tab
        expect(wait_until { open_streams == 2 }).to be(true)

        expect(post_exit.last).to include("reason" => "client_connected")
        sleep(0.2)
        expect(@thread).to be_alive
      end

      describe "with restart: true" do
        def post_restart
          port = JSON.parse(File.read(sidecar))["port"]
          res = Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/exit"),
                               JSON.generate(client_id: "web:1", restart: true), "Content-Type" => "application/json")
          [res.code.to_i, JSON.parse(res.body)]
        end

        it "leaves as :restart while other clients' streams are open, keeping even an empty session, with no recap" do
          allow(engine).to receive(:write_recap_now)
          start_worker(poll_interval: 0.05)
          follow(client_id: "tui:1")
          follow # a web tab
          expect(wait_until { open_streams == 2 }).to be(true)

          expect(post_restart).to eq([200, { "status" => "restarting", "session_id" => session.id }])
          expect(@thread.join(2)&.value).to eq(:restart)
          expect(@worker.discard?).to be(false)
          expect(engine).not_to have_received(:write_recap_now)
        end

        it "stays up while a question waits, and checks again as it leaves" do
          start_worker(poll_interval: 0.05)
          allow(engine).to receive(:pending_question).and_return({ id: "q1" })
          expect(post_restart.last).to include("status" => "held", "reason" => "question_pending")
          sleep(0.2)
          expect(@thread).to be_alive

          allow(engine).to receive(:pending_question).and_return(nil)
          policy = @worker.instance_variable_get(:@idle_exit)
          allow(policy).to receive(:hold_for_restart).and_return(nil, :input_queued)
          expect(post_restart.first).to eq(200)
          sleep(0.3)
          expect(@thread).to be_alive # held at the second look, as it left
        end
      end

      it "answers :starting before the idle-exit policy exists" do
        worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir)
        expect(worker.send(:exit_request, "tui:1")).to eq(:starting)
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
          sleep(@boom_delay) if @boom_delay && prompt == "boom"
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
        expect(wait_until { (seen += drain_events).any? { |e| e[:type] == :prompt_restored } }).to be(true)

        types = seen.map { |e| e[:type] }
        expect(types.index(:turn_failed)).to be < types.index(:prompt_restored)
        restored = seen.find { |e| e[:type] == :prompt_restored }
        expect(restored).to include(prompt: "boom")
        expect(restored[:origin]).to include(:enqueued_id)
        expect(conversation.first(3)).to eq(%w[sys earlier ok])
        expect(conversation.last).to include("failed before any answer").and include("went back to the user")
        expect(conversation.length).to eq(4)
        expect(wait_until { saved_messages.first(3) == %w[sys earlier ok] && saved_messages.length == 4 }).to be(true)
        expect(@thread).to be_alive

        post_turn("fine")
        expect(next_turn&.first).to eq("fine")
        expect(wait_until { saved_messages.drop(1).grep_v(/\A\[SYSTEM: /) == %w[earlier ok fine FINE] }).to be(true)
        expect(saved_messages[3]).to start_with("[SYSTEM: the previous turn failed")
      end

      it "keeps a turn that failed after tool steps: saved with its steps, no prompt handed back, !rollback still erases it" do
        start_worker(poll_interval: 5)

        post_turn("steps")
        expect(next_turn&.first).to eq("steps")
        seen = []
        expect(wait_until { (seen += drain_events).any? { |e| e[:type] == :turn_failed } }).to be(true)
        expect(seen.find { |e| e[:type] == :turn_failed }).to include(error_kind: :credits, kept_steps: 2)
        # The system head is the Engine's own prompt now (the turn's).
        kept = ["earlier", "ok", "steps", "", "[execute]\nstep1", "", "[execute]\nstep2"]
        expect(wait_until { saved_messages.drop(1).first(7) == kept && saved_messages.length == 9 }).to be(true)
        expect(saved_messages.last).to eq("[SYSTEM: the previous turn failed after 2 tool steps: out of credits on host main: " \
                                          "HTTP 402: Insufficient credits; add credits, then send again. Its work so far " \
                                          "(tool calls, file changes) stays; the user's last message is not answered yet.]")
        expect(conversation.length).to eq(9)
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).last_turn).to include("outcome" => "failed", "kept_steps" => 2)
        expect(@thread).to be_alive

        # The next prompt continues from the kept steps.
        post_turn("fine")
        expect(next_turn&.first).to eq("fine")
        expect(wait_until { saved_messages.last == "FINE" }).to be(true)
        expect(saved_messages.drop(1).grep_v(/\A\[SYSTEM: /)).to eq(kept + %w[fine FINE])
        expect(seen + drain_events).to(satisfy { |events| events.none? { |e| e[:type] == :prompt_restored } })
      end

      it "rolls back a context overflow after tool steps and gives its prompt back, as before" do
        start_worker(poll_interval: 5)

        post_turn("overflow")
        expect(next_turn&.first).to eq("overflow")
        seen = []
        expect(wait_until { (seen += drain_events).any? { |e| e[:type] == :prompt_restored } }).to be(true)
        expect(seen.find { |e| e[:type] == :turn_failed }).not_to have_key(:kept_steps)
        expect(seen.find { |e| e[:type] == :prompt_restored }).to include(prompt: "overflow")
        expect(wait_until { saved_messages.first(3) == %w[sys earlier ok] && saved_messages.length == 4 }).to be(true)
        expect(saved_messages.last).to include("failed before any answer: the conversation is too long")
          .and include("went back to the user")
      end

      it "lets !rollback erase a kept failed turn" do
        start_worker(poll_interval: 5)

        post_turn("steps")
        expect(wait_until { saved_messages.length == 9 }).to be(true)
        port = JSON.parse(File.read(sidecar))["port"]
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/command"),
                       JSON.generate(line: "!rollback", client_id: "web:1"), "Content-Type" => "application/json")

        expect(wait_until { saved_messages.drop(1) == %w[earlier ok] }).to be(true)
      end

      it "rolls back with the event log held, so a snapshot sees the failed turn or its restore, not half of it" do
        held = []
        allow(engine).to receive(:rollback_to).and_wrap_original do |original, checkpoint|
          held << engine.instance_variable_get(:@session_observer).instance_variable_get(:@mutex).mon_owned?
          original.call(checkpoint)
        end
        start_worker(poll_interval: 5)

        post_turn("boom")

        expect(wait_until { held.any? }).to be(true)
        expect(held).to eq([true])
      end

      it "runs a prompt queued behind the failed one" do
        @boom_delay = 0.2
        start_worker(poll_interval: 5)

        post_turn("boom")
        expect(next_turn&.first).to eq("boom")
        post_turn("fine")

        expect(next_turn&.first).to eq("fine")
        expect(wait_until { saved_messages.drop(1).grep_v(/\A\[SYSTEM: /) == %w[earlier ok fine FINE] }).to be(true)
      end

      it "survives a failed initial prompt too" do
        session.messages = []
        session.last_prompt = "boom"
        session.save(state_dir: tmpdir)

        start_worker(poll_interval: 5)

        expect(next_turn&.first).to eq("boom")
        seen = []
        expect(wait_until { (seen += drain_events).any? { |e| e[:type] == :prompt_restored } }).to be(true)
        expect(seen.find { |e| e[:type] == :prompt_restored }).to include(prompt: "boom", origin: nil)
        expect(@thread).to be_alive
        expect(wait_until { saved_messages.length == 1 && saved_messages.first.start_with?("[SYSTEM: the previous turn failed") }).to be(true)
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
        JSON.parse(Net::HTTP.get(URI("http://127.0.0.1:#{port}/session/#{session.id}/snapshot")))["snapshot"]
      end

      it "offers to continue it, from its tool results (no [No response] placeholder)" do
        start_worker(poll_interval: 5)

        post_turn("long task")

        expect(wait_until { saw?(:continue_offered) }).to be(true)
        offered = seen.find { |e| e[:type] == :continue_offered }
        expect(offered[:context]).to eq(original_prompt: "long task", tool_trace: ['execute status=ok params=command="ls"'],
                                        last_model_intent: "calling ls")
        expect(offered[:no_interrupt]).to be(false)
        expect(bridge_snapshot["continue_offer"]).to include("context" => include("original_prompt" => "long task"))
        expect(wait_until { saved_messages == ["long task", "calling ls", "a b"] }).to be(true)
      end

      it "drops the offer when a new prompt is taken, keeping the partial turn (D2)" do
        start_worker(poll_interval: 5)
        post_turn("long task")
        expect(wait_until { saw?(:continue_offered) }).to be(true)

        port = JSON.parse(File.read(sidecar))["port"]
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/turn"),
                       JSON.generate(session_id: session.id, prompt: "something else", client_id: "web:1"),
                       "Content-Type" => "application/json")

        expect(wait_until { saw?(:turn_completed) && seen.count { |e| e[:type] == :turn_completed } == 2 }).to be(true)
        types = seen.map { |e| e[:type] }
        resolved = seen.find { |e| e[:type] == :continue_resolved }
        expect(resolved).to include(decision: "dropped", client_id: "web:1")
        expect(types.index(:continue_resolved)).to be < types.rindex(:turn_started)
        expect(bridge_snapshot["continue_offer"]).to be_nil
        expect(wait_until { saved_messages == ["long task", "calling ls", "a b", "something else", "OK"] }).to be(true)
      end

      it "drops the offer when a reminder turn runs, so a later no can't roll the reminder's exchange back" do
        start_worker(poll_interval: 5)
        post_turn("long task")
        expect(wait_until { saw?(:continue_offered) }).to be(true)

        allow(engine).to receive(:reminders_due?).and_return(true)
        @reminder_callback.call(["stretch"])

        expect(wait_until { seen.count { |e| e[:type] == :turn_completed } == 2 if saw?(:turn_completed) }).to be(true)
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
                       JSON.generate(line: "!rollback", client_id: "web:1"), "Content-Type" => "application/json")
        expect(wait_until { saw?(:command_ran) }).to be(true)
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
                       JSON.generate(body), "Content-Type" => "application/json")
      end

      def events_seen
        seen << events.pop until events.empty?
        seen
      end

      def ran(command_id, timeout: 2)
        wait_until(timeout: timeout) { events_seen.any? { |e| e[:type] == :command_ran && e[:command_id] == command_id } }
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

      it "runs a plugin command, and the cards it shows follow its command_ran (as its output)" do
        engine.command_registry.register("/hi", "greet", source: "b") do |_args|
          engine.show_card(source: "b", title: "Hi card")
          "hi"
        end
        start_worker(poll_interval: 5)

        command_id = JSON.parse(post_command("/hi").body)["command_id"]
        done = ran(command_id)
        wait_until(timeout: 2) { events_seen.any? { |e| e[:type] == :card } }
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

        wait_until(timeout: 2) { events_seen.any? { |e| e[:type] == :command_ran } }
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

          wait_until(timeout: 2) { events_seen.any? { |e| e[:type] == :command_ran } }
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
          expect(wait_until { failed_saves.include?(:command) }).to be(true)
          expect(@thread).to be_alive

          saves_fail!(false)
          post_turn("after")
          expect(wait_until { saved_messages.include?("after") }).to be(true)
          expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).model_name).to eq("Qwen3-14B")
        end
      end

      # A message queued as a file while no worker was up (chi send).
      it "runs a session command from an input file as the command, for its sender" do
        Samagotchi::SessionManager.write_turn_input(session.id, prompt: "/model Qwen3-14B", client_id: "cli:send",
                                                                enqueued_id: "e1", state_dir: tmpdir)
        start_worker(poll_interval: 5)

        wait_until(timeout: 2) { events_seen.any? { |e| e[:type] == :command_ran } }
        expect(seen.find { |e| e[:type] == :command_ran }).to include(line: "/model Qwen3-14B", client_id: "cli:send",
                                                                      status: "ok")
        expect(turns).to be_empty
      end

      it "runs a command an input file carries before the next file's turn, not busy" do
        ["one", "/model Qwen3-14B", "two"].each do |prompt|
          Samagotchi::SessionManager.write_turn_input(session.id, prompt: prompt, client_id: "cli:send", state_dir: tmpdir)
          sleep 0.001 # distinct file names, in order
        end
        start_worker(poll_interval: 5)

        expect(next_turn&.first).to eq("one")
        expect(next_turn&.first).to eq("two")
        done = nil
        wait_until { done = events_seen.find { |e| e[:type] == :command_ran } }
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
        allow(Samagotchi::Tools::Execute).to receive(:call).with("echo hi", env: {}).and_return("hi\n")
        start_worker(poll_interval: 5)

        done = ran(JSON.parse(post_command("!echo hi").body)["command_id"])

        expect(done).to include(status: "ok", output: "hi\n", changed: ["messages"])
        saved = -> { Samagotchi::Session.load(session.id, state_dir: tmpdir).messages.map { |m| m[:content] } }
        expect(wait_until { saved.call == ["!(echo hi)\nhi\n"] }).to be(true)
      end

      it "rolls a cancelled turn back with !rollback" do
        start_worker(poll_interval: 5)
        post_turn("cancel me")
        expect(wait_until { events_seen.any? { |e| e[:type] == :turn_canceled } }).to be(true)

        done = ran(JSON.parse(post_command("!rollback").body)["command_id"])

        expect(done).to include(output: "salvaged turn discarded; restored pre-turn state", changed: ["messages"])
        expect(wait_until { saved_messages.empty? }).to be(true)
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
        types = seen.map { |e| e[:type] }
        expect(types.index(:command_ran)).to be < types.index(:turn_completed)
        expect(seen.find { |e| e[:type] == :command_queued && e[:line] == "!rollback" }).not_to have_key(:waits)
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
          wait_until { started("after") }
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

          expect(@thread.join(2)&.value).to eq(:stopped)
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
              arrival.join(0.2)
            end
            original.call(event, *rest)
          end

          worker.send(:refuse_queued_commands, mid_turn: true)
          arrival.join(2)

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
            expect(wait_until { events_seen.any? { |e| e[:type] == :turn_completed } }).to be(true)
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
                         JSON.generate(client_id: "tui:9"), "Content-Type" => "application/json")
          sleep(0.3)
          expect(@thread).to be_alive # waiting for the command
          gate << true

          expect(@thread.join(2)&.value).to eq(:exit_requested)
          expect(ran(command_id)).to include(status: "ok", output: "slow side done", anytime: true)
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
          recap = double("recap")
          allow(recap).to receive(:awaiting_continue=) { |seam| @recap_offer_seam = seam }
          allow(engine).to receive(:recap).and_return(recap)
          start_worker(poll_interval: 5)
          post_turn("long task")
          expect(wait_until { events_seen.any? { |e| e[:type] == :continue_offered } }).to be(true)
        end

        it "runs the continue turn on yes, for whoever answered" do
          done = ran(JSON.parse(post_command("/continue yes", client_id: "web:2").body)["command_id"])

          expect(done).to include(status: "ok")
          expect(wait_until { turns.size >= 2 && events_seen.count { |e| e[:type] == :turn_completed } == 2 }).to be(true)
          resolved = seen.find { |e| e[:type] == :continue_resolved }
          expect(resolved).to include(decision: "resume", client_id: "web:2")
          started = seen.select { |e| e[:type] == :turn_started }.last
          expect(started).to include(continue: true, prompt: nil, origin: { client_id: "web:2" })
          expect(wait_until { saved_messages == ["long task", "r1", "OK"] }).to be(true)
        end

        it "brings an archived session back when a user answers it" do
          Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir)
          ran(JSON.parse(post_command("/continue no", client_id: "web:2").body)["command_id"])

          # Un-archived after command_ran and the session's save: wait for it.
          expect(wait_until { !Samagotchi::ArchiveStore.archived?(session_dir) }).to be(true)
        end

        it "tells the recap an offer is open, and records activity when no ends it, so a new recap follows" do
          expect(@recap_offer_seam.call).to be(true)
          seq = engine.activity_seq
          ran(JSON.parse(post_command("/continue no").body)["command_id"])

          expect(@recap_offer_seam.call).to be(false)
          # Recorded after command_ran and the session's save: wait for it.
          expect(wait_until { engine.activity_seq > seq }).to be(true)
        end

        it "keeps the interrupted turn on no, with a note (D3)" do
          done = ran(JSON.parse(post_command("/continue no").body)["command_id"])

          expect(done).to include(output: "turn not continued; its work so far stays (!rollback erases it)", changed: ["messages"])
          expect(seen.find { |e| e[:type] == :continue_resolved }).to include(decision: "abort", client_id: "tui:9")
          expect(wait_until { saved_messages == ["long task", "r1", Samagotchi::TurnNote.not_continued[:content]] }).to be(true)
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
        expect(reached.pop(timeout: 5)).to be(true)

        asked = events_seen.find { |e| e[:type] == :question_requested }
        answer = Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/answer"),
                                JSON.generate(id: asked[:pending_question][:id], selected: ["Continue"], client_id: "web:2"),
                                "Content-Type" => "application/json")
        expect(answer.code).to eq("200")
        post_turn("something else")
        gate << :go

        expect(wait_until { events_seen.count { |e| e[:type] == :turn_completed } == 3 }).to be(true)
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
          expect(wait_until { events_seen.any? { |e| e[:type] == :question_requested } }).to be(true)
        end

        def saved_session = Samagotchi::Session.load(session.id, state_dir: tmpdir)
        def question = seen.find { |e| e[:type] == :question_requested }[:pending_question]

        def post_answer(selected, freeform: nil, client_id: "web:2", id: question[:id])
          Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/answer"),
                         JSON.generate(id: id, selected: selected, freeform: freeform, client_id: client_id),
                         "Content-Type" => "application/json")
        end

        def continue_ran(line)
          wait_until { events_seen.any? { |e| e[:type] == :command_ran && e[:line] == line } }
          seen.find { |e| e[:type] == :command_ran && e[:line] == line }
        end

        it "opens after the turn's after_turn hooks ran (check-in closes its card there), so the two never stand together" do
          seen_by_hook = []
          engine.instance_variable_get(:@hooks).register_persistent(:after_turn) do |_event|
            seen_by_hook << engine.pending_question
          end
          # A second turn that runs out too: the first question went as it started.
          post_turn("long task")
          expect(wait_until { events_seen.count { |e| e[:type] == :question_requested } == 2 }).to be(true)

          expect(seen_by_hook).to eq([nil])
        end

        it "is pending in the file as the session goes idle, with the turn's limit, and no reply is written" do
          expect(question).to include(kind: "continue", header: "Step limit", options: %w[Continue Stop], limit: 100,
                                      allow_freeform: true)
          expect(question[:question]).to start_with("The turn ran out of iterations (100 steps) before it answered. Continue it?")
          expect(question[:question]).to include("Prompt: long task")
          expect(seen.find { |e| e[:type] == :question_requested }).to include(standing: true)
          # Every save from the turn's end on has it: no idle write without it.
          expect(wait_until { saved_session.status == "idle" }).to be(true)
          expect(saved_session.pending_question).to include(id: question[:id], kind: "continue")
          expect(saved_session.last_turn).to include("exhausted" => true, "limit" => 100)
          expect(Samagotchi::ReplyWait.newest_reply(session.id, state_dir: tmpdir)).to be_nil
        end

        it "runs the continue turn on Continue, as a card's /continue yes for whoever answered" do
          expect(post_answer(["Continue"]).code).to eq("200")

          done = continue_ran("/continue yes")
          expect(done).to include(status: "ok", client_id: "web:2", card: true)
          expect(wait_until { events_seen.count { |e| e[:type] == :turn_completed } == 2 }).to be(true)
          expect(seen.find { |e| e[:type] == :continue_resolved }).to include(decision: "resume", client_id: "web:2")
          expect(seen.select { |e| e[:type] == :turn_started }.last).to include(continue: true, origin: { client_id: "web:2" })
          expect(wait_until { saved_messages == ["long task", "r1", "OK"] && saved_session.pending_question.nil? }).to be(true)
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
          expect(wait_until { events_seen.count { |e| e[:type] == :turn_completed } == 2 }).to be(true)
          drained.pop
        end

        it "runs the continue turn on Continue with a text, which joins that turn as a steer from the user" do
          expect(answer_continue_with("also check the specs", client_id: "web:2"))
            .to eq([{ text: "also check the specs", source: "user" }])
          # turn_completed goes out before the turn lets go (release_turn):
          # a steer is refused once no turn runs.
          expect(wait_until { !engine.turn_running? }).to be(true)
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

        it "is withdrawn when a new prompt drops the offer, and the prompt runs" do
          post_turn("something else")

          expect(wait_until { events_seen.count { |e| e[:type] == :turn_completed } == 2 }).to be(true)
          expect(seen.find { |e| e[:type] == :question_cancelled }).to include(id: question[:id], reason: "dropped")
          expect(saved_session.pending_question).to be_nil
          expect(post_answer(["Continue"]).code).to eq("409")
        end

        it "is withdrawn when a typed /continue answers the offer" do
          ran(JSON.parse(post_command("/continue no").body)["command_id"])

          expect(wait_until { events_seen.any? { |e| e[:type] == :question_cancelled } }).to be(true)
          expect(seen.find { |e| e[:type] == :question_cancelled }).to include(id: question[:id], reason: "answered")
          expect(engine.pending_question).to be_nil
        end

        it "lets the first of an answer and a prompt win: the answer queued first runs before the prompt" do
          expect(post_answer(["Continue"]).code).to eq("200")
          post_turn("something else")

          expect(wait_until { events_seen.count { |e| e[:type] == :turn_completed } == 3 }).to be(true)
          started = seen.select { |e| e[:type] == :turn_started }
          expect(started[1]).to include(continue: true)
          expect(started[2]).to include(prompt: "something else")
          expect(continue_ran("/continue yes")).to include(status: "ok")
        end

        it "is withdrawn when a reminder turn drops the offer" do
          allow(engine).to receive(:reminders_due?).and_return(true)
          @reminder_callback.call(["stretch"])

          expect(wait_until { events_seen.count { |e| e[:type] == :turn_completed } == 2 }).to be(true)
          expect(seen.find { |e| e[:type] == :question_cancelled }).to include(reason: "dropped")
          expect(engine.pending_question).to be_nil
        end

        it "gives way to a plugin's question asked meanwhile, and comes back once that is answered" do
          box = {}
          asker = Thread.new { box[:answer] = engine.open_question(question: "Which?", options: %w[A B], multi_select: false) }
          expect(wait_until { engine.pending_question&.dig(:question) == "Which?" }).to be(true)
          expect(events_seen.find { |e| e[:type] == :question_cancelled }).to include(id: question[:id], reason: "superseded")

          engine.answer_question(id: engine.pending_question[:id], selected: ["A"])
          asker.join(2)

          expect(wait_until { engine.pending_question&.dig(:kind) == "continue" }).to be(true)
          expect(saved_session.pending_question).to include(kind: "continue")
          expect(post_answer(["Continue"], id: engine.pending_question[:id]).code).to eq("200")
          expect(continue_ran("/continue yes")).to include(status: "ok")
        end

        it "is asked again after a continue turn that failed, once" do
          allow(kernel).to receive(:run).and_raise(Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500))
          expect(post_answer(["Continue"]).code).to eq("200")

          expect(wait_until { events_seen.count { |e| e[:type] == :question_requested } == 2 }).to be(true)
          sleep(0.2)
          expect(events_seen.count { |e| e[:type] == :question_requested }).to eq(2)
          expect(engine.pending_question).to include(kind: "continue")
          expect(saved_session.pending_question).to include(kind: "continue")
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

          expect(wait_until { events_seen.count { |e| e[:type] == :question_requested } == 2 }).to be(true)
          expect(failed).to be(true)
          expect(@thread).to be_alive
          expect(engine.pending_question).to include(kind: "continue")
          expect(wait_until { saved_session.pending_question&.dig(:kind) == "continue" }).to be(true)
          expect(saved_session.status).to eq("idle")
          expect(seen.map { |e| e[:type] }).not_to include(:turn_failed)
        end

        it "is asked again when the continue turn fails before it begins (the Engine's checkpoint)" do
          allow(engine).to receive(:messages_checkpoint).and_raise(IOError, "checkpoint")
          expect(post_answer(["Continue"]).code).to eq("200")

          expect(wait_until { events_seen.count { |e| e[:type] == :question_requested } == 2 }).to be(true)
          expect(@thread).to be_alive
          expect(engine.pending_question).to include(kind: "continue")
        end
      end
    end
  end
end
