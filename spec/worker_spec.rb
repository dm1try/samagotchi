# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "net/http"
require "json"

require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/bridge_client"
require "samagotchi/worker"

RSpec.describe Samagotchi::Worker do
  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def wait_until(timeout: 2)
    deadline = mono + timeout
    sleep(0.01) until yield || mono > deadline
    yield
  end

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
      woken = Thread.new { waker.wait(5) }
      sleep(0.05)
      started = mono
      waker.wake
      expect(woken.value).to be(true)
      expect(mono - started).to be < 0.3
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
      Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client),
                             kernel: instance_double(Samagotchi::KernelLoop))
    end
    let(:turns) { Queue.new }
    let(:result) { instance_double(Samagotchi::KernelLoop::Result, output: "") }

    before do
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR))
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
      begin
        @thread&.join(2)
      rescue SystemExit
        nil # the worker's exit(0) on a stop; re-raised by every join
      end
      FileUtils.rm_rf(tmpdir)
    end

    # Runs the worker on a thread; its exit(0) on a stop ends only the thread.
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
      File.join(session_dir, Samagotchi::Bridge::SIDECAR_FILE)
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

    it "tells its Engine it is a worker, so approvals wait for an attached UI" do
      start_worker
      expect(engine.interface).to eq(:worker)
    end

    it "starts a turn posted to its Bridge at once, not on the next tick" do
      start_worker(poll_interval: 5)

      posted_at = mono
      expect(post_turn("PING").code).to eq("202")

      prompt, started_at = next_turn
      expect(prompt).to eq("PING")
      expect(started_at - posted_at).to be < 0.3
    end

    it "picks up an input file written without a wake on the fallback tick" do
      start_worker(poll_interval: 0.2)

      Samagotchi::SessionManager.write_turn_input(session.id, prompt: "from another process", state_dir: tmpdir)

      expect(next_turn&.first).to eq("from another process")
    end

    it "runs a due reminder at once, as a continue turn with no user message (as the REPL)" do
      allow(engine).to receive(:reminders_due?).and_return(true)
      start_worker(poll_interval: 5)

      called_at = mono
      @reminder_callback.call(["stretch"])

      prompt, started_at, kwargs = next_turn
      expect(prompt).to be_nil
      expect(kwargs).to include(continue: true, origin: { client_id: "system:reminder" })
      expect(started_at - called_at).to be < 0.3
      expect(Dir.children(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR))).to be_empty
      expect(engine.due_reminder_names).to be_empty
    end

    it "runs no reminder turn when a prompt's turn already took the due reminders (a stale latch)" do
      allow(engine).to receive(:reminders_due?).and_return(false)
      start_worker(poll_interval: 5)

      @reminder_callback.call(["stretch"])

      expect(next_turn(timeout: 0.5)).to be_nil
      expect(engine.due_reminder_names).to be_empty
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
      expect(started_at - released_at).to be < 0.3
    end

    it "still exits on a stop marked on disk" do
      start_worker(poll_interval: 0.05)

      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      expect { @thread.join(2) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "still leaves when idle" do
      start_worker(poll_interval: 0.05, idle_exit_minutes: 0.002)

      expect(@thread.join(2)&.value).to eq(:idle_exit)
      expect(File.exist?(sidecar)).to be(false)
    end

    describe "an exit request (POST /exit)" do
      def post_exit(client_id: "tui:1")
        port = JSON.parse(File.read(sidecar))["port"]
        res = Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/exit"),
                             JSON.generate(client_id: client_id), "Content-Type" => "application/json")
        [res.code.to_i, JSON.parse(res.body)]
      end

      it "leaves at once when nothing keeps it, even with idle exit off, and the session isn't stopped" do
        start_worker(poll_interval: 5, idle_exit_minutes: 0)

        expect(post_exit.first).to eq(200)
        expect(@thread.join(2)&.value).to eq(:exit_requested)
        expect(File.exist?(sidecar)).to be(false)
        expect(engine).to have_received(:stop_idle)
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).not_to eq(Samagotchi::Session::STATUS_STOPPED)
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

      after { Array(@streams).each(&:close) }

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
          raise Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500) unless prompt == "fine"

          Samagotchi::KernelLoop::Result.new(output: "FINE", conversation: messages + [{ role: "model", content: "FINE" }],
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
        expect(conversation).to eq(%w[sys earlier ok])
        expect(wait_until { saved_messages == %w[sys earlier ok] }).to be(true)
        expect(@thread).to be_alive

        post_turn("fine")
        expect(next_turn&.first).to eq("fine")
        expect(wait_until { saved_messages.drop(1) == %w[earlier ok fine FINE] }).to be(true)
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
        expect(wait_until { saved_messages.drop(1) == %w[earlier ok fine FINE] }).to be(true)
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
        expect(wait_until { saved_messages.empty? }).to be(true)
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
            Samagotchi::KernelLoop::Result.new(
              output: "", conversation: messages + [{ role: "model", content: "calling ls" }, { role: "tool_response", content: "a b" }],
              exhausted: true, pending_tool_calls: true, canceled: false,
              tool_activity: [{ tool: "execute", status: "ok", params: 'command="ls"' }]
            )
          else
            Samagotchi::KernelLoop::Result.new(output: "OK", conversation: messages + [{ role: "model", content: "OK" }],
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
          when "slow, no boundary"
            release.pop
          end
          if prompt == "long task"
            Samagotchi::KernelLoop::Result.new(output: "", conversation: messages + [{ role: "tool_response", content: "r1" }],
                                               exhausted: true, pending_tool_calls: true, tool_activity: [], canceled: false)
          elsif prompt == "cancel me"
            Samagotchi::KernelLoop::Result.new(output: "", conversation: messages + [{ role: "model", content: "Partial\n[interrupted]" }],
                                               exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: true,
                                               cancellation_reason: :manual)
          else
            Samagotchi::KernelLoop::Result.new(output: "OK", conversation: messages + [{ role: "model", content: "OK" }],
                                               exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
          end
        end
        engine.subscribe(observer: ->(event) { events << event })
      end

      def port = JSON.parse(File.read(sidecar))["port"]

      def post_command(line, client_id: "tui:9", session_id: session.id)
        Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session_id}/command"),
                       JSON.generate(line: line, client_id: client_id), "Content-Type" => "application/json")
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
        allow(Samagotchi::Tools::Execute).to receive(:call).with("echo hi").and_return("hi\n")
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

      it "is busy while a turn runs: at the turn's next iteration boundary" do
        start_worker(poll_interval: 5)
        post_turn("slow")
        expect(next_turn&.first).to eq("slow")

        command_id = JSON.parse(post_command("/model").body)["command_id"]
        release << true

        done = ran(command_id)
        expect(done).to include(status: "busy", output: "busy: wait for the turn to end")
        types = seen.map { |e| e[:type] }
        expect(types.index(:command_ran)).to be < types.index(:turn_completed)
      end

      it "is busy while a turn runs: at the latest when it ends" do
        start_worker(poll_interval: 5)
        post_turn("slow, no boundary")
        expect(next_turn&.first).to eq("slow, no boundary")

        command_id = JSON.parse(post_command("/model").body)["command_id"]
        release << true

        expect(ran(command_id)).to include(status: "busy")
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

        it "discards the interrupted turn on no" do
          done = ran(JSON.parse(post_command("/continue no").body)["command_id"])

          expect(done).to include(output: "interrupted turn cancelled; enter your next prompt", changed: ["messages"])
          expect(seen.find { |e| e[:type] == :continue_resolved }).to include(decision: "abort", client_id: "tui:9")
          expect(wait_until { saved_messages.empty? }).to be(true)
        end

        it "asks again on anything else, with the offer still open" do
          done = ran(JSON.parse(post_command("/continue maybe").body)["command_id"])

          expect(done).to include(status: "error", output: "answer yes, no, or no, <reason>")
          expect(seen.map { |e| e[:type] }).not_to include(:continue_resolved)
        end
      end
    end
  end
end
