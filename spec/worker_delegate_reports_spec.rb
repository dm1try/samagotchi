# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "support/test_kernel"
require "support/worker_loop_rounds"
require "support/bridge_auth"

require "samagotchi/engine"
require "samagotchi/worker"

# The worker's side of delegate reports: a delegate child's turns ring its
# parent (ChildRing), and a parent's turns take its children's reports at
# their iteration boundaries (ChildReports), committed when the turn is kept.
RSpec.describe Samagotchi::Worker, "delegate reports" do
  include BridgeAuth

  include WorkerLoopRounds

  around do |example|
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    WebMock.allow_net_connect! if defined?(WebMock)
    example.run
  ensure
    WebMock.disable_net_connect! if defined?(WebMock)
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  let(:tmpdir) { Dir.mktmpdir("worker-reports") }
  let!(:parent) { save(Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir)) }
  let(:parent_dir) { Samagotchi::Session.session_dir(parent.id, state_dir: tmpdir) }
  let!(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
  let(:turns) { Queue.new }
  let(:events) { Queue.new }
  let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }
  let(:wakes) { [] }

  before do
    allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    allow(engine).to receive(:start_idle)
    allow(engine).to receive(:stop_idle)
    allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
      turns << [prompt, kwargs]
      result
    end
    allow(Samagotchi::SessionManager).to receive(:wake_for_report) { |id, **| wakes << id }
    engine.subscribe(observer: ->(event) { events << event })
  end

  after do
    @thread&.kill
    @thread&.join(2)
    FileUtils.rm_rf(tmpdir)
  end

  def save(session)
    session.save(state_dir: tmpdir)
    FileUtils.mkdir_p(File.join(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), "input"))
    session
  end

  def make_child(prompt: "")
    child = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir,
                                            parent_id: parent.id, delegate: true)
    child.last_prompt = prompt
    save(child)
  end

  # Input files come in without a wake: the fallback tick takes them.
  def start_worker(session, poll_interval: 0.02)
    dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
    worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: dir, idle_exit_minutes: 0,
                                 poll_interval: poll_interval)
    count_loop_rounds(worker)
    @thread = Thread.new { worker.run }
    @thread.report_on_exception = false
    wait_for("the worker's sidecar") { File.exist?(File.join(dir, Samagotchi::WorkerSidecar::FILE)) }
    worker
  end

  def send_turn(session, prompt, client_id)
    Samagotchi::SessionManager.write_turn_input(session.id, prompt: prompt, client_id: client_id, state_dir: tmpdir)
  end

  def rings = Samagotchi::SessionInbox.find_ring_files(parent_dir)
  def ring_whys = rings.map { |f| Samagotchi::SessionInbox.read_ring(f)[:why] }

  def question(kind, **more)
    engine.instance_variable_get(:@session_observer)
          .notify(type: :question_requested, pending_question: { id: "q-#{kind}", kind: kind, question: "?", **more }.compact)
  end

  def next_turn(timeout: 5) = pop!(turns, "the next turn", timeout: timeout)

  describe "a delegate child" do
    # A5 (2026-10-06): the worker's process exits right after #run returns
    # (exit 1 on a crash), which killed the wake thread before it spawned
    # the idle parent's worker: the parent never woke.
    it "wakes its idle parent before its run returns when it crashes" do
      child = make_child
      allow(Samagotchi::SessionManager).to receive(:wake_for_report) do |id, **|
        sleep(0.2) # sleep-ok: a slow wake, which run must still wait for before it returns
        wakes << id
      end
      allow(Samagotchi::SessionInbox).to receive(:find_new_input_files).and_raise(RuntimeError, "boom")
      dir = Samagotchi::Session.session_dir(child.id, state_dir: tmpdir)
      worker = described_class.new(session_id: child.id, state_dir: tmpdir, session_dir: dir, idle_exit_minutes: 0, poll_interval: 5)

      expect(worker.run).to eq(:crashed)
      expect(ring_whys).to eq(["crash"])
      expect(wakes).to eq([parent.id])
    end

    it "rings its parent after its first turn (the parent's task) is saved, and wakes a parent with no worker" do
      child = make_child(prompt: "count the specs")
      start_worker(child)

      expect(next_turn&.first).to eq("count the specs")
      wait_for("the turn_end ring") { ring_whys == ["turn_end"] }
      expect(Samagotchi::SessionInbox.read_ring(rings.first)[:child_id]).to eq(child.id)
      wait_for("the parent's wake") { wakes == [parent.id] }
    end

    it "takes a parent.json written while it runs at its next turn's start: the turn and the save see the new parent" do
      child = make_child
      seen = Queue.new
      allow(engine).to receive(:run_turn) { |session, prompt, **| seen << [prompt, session.parent_id] and result }
      start_worker(child)
      moved_to = save(Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir))
      Samagotchi::Session.reparent(child.id, to: moved_to.id, from: parent.id, state_dir: tmpdir)

      send_turn(child, "from the web", "web:tab1")

      expect(pop!(seen, "the turn after the move")).to eq(["from the web", moved_to.id])
      wait_for("the save to name the new parent") { JSON.parse(File.read(File.join(tmpdir, "#{child.id}.json")))["parent_id"] == moved_to.id }
    end

    it "rings after a follow-up from its parent, not after a turn the user typed into it" do
      child = make_child
      start_worker(child)

      send_turn(child, "from the web", "web:tab1")
      expect(next_turn&.first).to eq("from the web")
      loop_rounds
      expect(rings).to be_empty

      send_turn(child, "and the second?", "delegate:#{parent.id[0, 8]}")
      expect(next_turn&.first).to eq("and the second?")
      wait_for("the turn_end ring after the parent's follow-up") { ring_whys == ["turn_end"] }
    end

    # P4: a hook's question rings too (the parent reports or relays it); an
    # approval doesn't (the relay takes it while the parent waits), nor a
    # relay card (a hook card relayed from a grandchild: the hop is the
    # grandparent's wait, as for approvals).
    it "rings on the model's question, the continue offer and a hook's question in its parent's turn, not on an approval or a relay card" do
      child = make_child
      allow(engine).to receive(:run_turn) do |_session, prompt, **|
        question("approval")
        question("hook", relay: { id: "r1", child_id: "c" })
        question("hook")
        turns << [prompt]
        result
      end
      start_worker(child)
      send_turn(child, "go", "delegate:#{parent.id[0, 8]}")

      expect(next_turn&.first).to eq("go")
      wait_for("the question and turn_end rings") { ring_whys == %w[question turn_end] }
    end

    it "doesn't ring on a hook's question in a turn its user typed into it" do
      child = make_child
      allow(engine).to receive(:run_turn) do |_session, prompt, **|
        question("hook")
        turns << [prompt]
        result
      end
      start_worker(child)
      send_turn(child, "from the web", "web:tab1")
      expect(next_turn&.first).to eq("from the web")
      loop_rounds
      expect(rings).to be_empty
    end

    it "rings after a turn that follows a question it rang about, whoever starts that turn (D10)" do
      child = make_child
      allow(engine).to receive(:run_turn) do |session, prompt, **|
        if prompt == "go"
          session.pending_question = { id: "c1", kind: "continue", question: "Continue it?" }
          question("continue")
        else
          session.pending_question = nil
        end
        turns << [prompt]
        result
      end
      start_worker(child)
      send_turn(child, "go", "delegate:#{parent.id[0, 8]}")
      wait_for("the question and turn_end rings") { ring_whys == %w[question turn_end] }
      rings.each { |f| File.delete(f) }

      send_turn(child, "answered on the web", "web:tab1")
      expect(next_turn&.first).to eq("go")
      expect(next_turn&.first).to eq("answered on the web")
      wait_for("the turn_end ring after the web answer") { ring_whys == ["turn_end"] }
      rings.each { |f| File.delete(f) }

      # Settled: the user's next turn is the user's again.
      send_turn(child, "another", "web:tab1")
      expect(next_turn&.first).to eq("another")
      loop_rounds
      expect(rings).to be_empty
    end

    it "doesn't ring when delegate_reports is off" do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.delegate_reports").and_return("off")
      child = make_child(prompt: "task")
      start_worker(child)

      expect(next_turn&.first).to eq("task")
      loop_rounds
      expect(rings).to be_empty
    end

    it "never rings for a fork" do
      fork = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir,
                                             parent_id: parent.id)
      fork.last_prompt = "seeded"
      save(fork)
      start_worker(fork)

      expect(next_turn&.first).to eq("seeded")
      loop_rounds
      expect(rings).to be_empty
    end
  end

  describe "a parent" do
    let(:child) { make_child }
    let(:child_dir) { Samagotchi::Session.session_dir(child.id, state_dir: tmpdir) }

    # The child's turn ended with +text+ and rang.
    def child_answers(text)
      Samagotchi::Tools::DelegateWait.mark_started(parent.id, child, state_dir: tmpdir)
      Samagotchi::SessionInbox.write_output(child_dir, text)
      s = Samagotchi::Session.load(child.id, state_dir: tmpdir)
      s.last_turn = { "outcome" => "completed", "ended_at" => Time.now.iso8601(6) }
      s.save(state_dir: tmpdir)
      Samagotchi::SessionInbox.write_ring(parent_dir, child_id: child.id, why: "turn_end")
    end

    def cursor = Samagotchi::Tools::DelegateCursors.get(parent.id, child.id, state_dir: tmpdir)

    it "merges a report at an iteration boundary as the child's, and commits it when the turn is kept" do
      allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
        child_answers("found it")
        turns << [prompt, kwargs[:pending_input].call, kwargs[:pending_input].call]
        result
      end
      start_worker(parent)
      send_turn(parent, "keep going", "web:tab1")

      prompt, first, second = next_turn
      expect(prompt).to eq("keep going")
      expect(first).to eq([Samagotchi::Steer::Line.new(text: "session: #{child.id}\nstatus: answered\n---\nfound it",
                                                       source: "delegate_report")])
      # Taken once in the turn.
      expect(second).to eq([])
      merged = nil
      wait_for("the input_merged event") { merged = drain.find { |e| e[:type] == :input_merged } }
      expect(merged).to include(count: 1, origins: [{ client_id: "child:#{child.id[0, 8]}" }])

      wait_for("the report's ring to be taken") { rings.empty? }
      expect(cursor.reply_file).to end_with(".txt")
    end

    it "leaves the report out of a failed turn's restored prompts and keeps its ring for the next turn" do
      # queue: no wake turn takes the ring before the next prompt.
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("session.delegate_reports").and_return("queue")
      calls = 0
      allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
        calls += 1
        child_answers("found it") if calls == 1
        turns << [prompt, kwargs[:pending_input].call]
        raise Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500) if calls == 1

        result
      end
      start_worker(parent)
      send_turn(parent, "boom", "web:tab1")

      expect(next_turn.last.map(&:source)).to eq(["delegate_report"])
      restored = nil
      wait_for("the prompt_restored event") { (restored = drain.select { |e| e[:type] == :prompt_restored }).any? }
      expect(restored.map { |e| e[:prompt] }).to eq(["boom"])
      expect(rings.size).to eq(1)

      send_turn(parent, "again", "web:tab1")
      prompt, lines = next_turn
      expect(prompt).to eq("again")
      expect(lines.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\nfound it"])
      wait_for("the report's ring to be taken") { rings.empty? }
    end

    it "commits the report a failed turn read when the turn's work stays, and hands no prompt back" do
      allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
        child_answers("found it")
        turns << [prompt, kwargs[:pending_input].call]
        error = Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500)
        # What Engine#failed_messages marks on a turn that got to tool steps.
        raise(Samagotchi::LLM::FailedTurn.attach(error, nil).tap { |e| e.kept_steps = 2 })
      end
      start_worker(parent)
      send_turn(parent, "boom", "web:tab1")

      expect(next_turn.last.map(&:source)).to eq(["delegate_report"])
      wait_for("the report's ring to be taken") { rings.empty? }
      expect(cursor.reply_file).to end_with(".txt")
      expect(drain.none? { |e| e[:type] == :prompt_restored }).to be(true)
    end

    # L3 (2026-10-08): a reminder or continue turn that failed before any
    # progress isn't rolled back (the Engine keeps it with its failed note,
    # the report it merged included), but its reports were released, so the
    # next turn delivered them again. A failure past the loop is the
    # opposite: the Engine drops what the loop merged, so the ring stays.
    describe "a failed turn nothing rolled back" do
      # Marked as the loops mark a failure inside them (LLM::FailedTurn):
      # the Engine keeps their conversation, the merged report in it.
      let(:server_error) do
        Samagotchi::LLM::FailedTurn.attach(Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500), [])
      end

      before do
        # queue: no wake turn takes the ring first.
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("session.delegate_reports").and_return("queue")
      end

      it "commits the report a reminder turn read: the next turn doesn't bring it again" do
        reminder = nil
        allow(Samagotchi::Engine).to receive(:new) do |**kwargs|
          reminder = kwargs.dig(:reminders, :callback)
          engine
        end
        allow(engine).to receive(:reminders_due?).and_return(true)
        calls = 0
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          calls += 1
          turns << [prompt, kwargs[:pending_input].call]
          raise server_error if calls == 1

          result
        end
        start_worker(parent)
        child_answers("found it")
        reminder.call(["stretch"])

        prompt, lines = next_turn
        expect(prompt).to be_nil
        expect(lines.map(&:source)).to eq(["delegate_report"])
        wait_for("the report's ring to be taken") { rings.empty? }
        expect(cursor.reply_file).to end_with(".txt")

        send_turn(parent, "again", "web:tab1")
        expect(next_turn).to eq(["again", []])
      end

      # A reminder turn on the real Engine whose loop merges the report and
      # answers, failed by the block (it installs a stub that raises once).
      # @return [Array(Boolean, Boolean)] whether the saved conversation
      #   holds the report, and whether the next turn brought it again
      def reminder_turn_failing(outcome, canceled: false)
        reminder = nil
        allow(Samagotchi::Engine).to receive(:new) do |**kwargs|
          reminder = kwargs.dig(:reminders, :callback)
          engine
        end
        allow(engine).to receive(:reminders_due?).and_return(true)
        allow(engine).to receive(:run_turn).and_call_original
        backend = Object.new
        seen = turns
        backend.define_singleton_method(:provider) { :chat }
        backend.define_singleton_method(:complete) do |messages:, pending_input:, **|
          lines = pending_input.call
          seen << lines
          conversation = messages + lines.map { |line| { role: "user", content: line.text } } +
                         [{ role: "model", content: "noted" }]
          Samagotchi::LLM::ModelResult.new(text: "noted", conversation: conversation, canceled: canceled,
                                           cancellation_reason: (:user if canceled))
        end
        allow(engine).to receive(:backend_for).and_return(backend)
        yield
        start_worker(parent)
        child_answers("found it")
        reminder.call(["stretch"])

        expect(next_turn.map(&:source)).to eq(["delegate_report"])
        wait_for("the turn's end event") { drain.any? { |e| %i[turn_failed turn_completed turn_canceled].include?(e[:type]) } }
        # Saved as the turn ended (the Engine's failed save, or the worker's after the turn).
        saved = -> { Samagotchi::Session.load(parent.id, state_dir: tmpdir) }
        wait_for("the turn's outcome to be saved") { saved.call.last_turn&.outcome == outcome }
        kept = saved.call.messages.any? { |m| m[:content].to_s.include?("found it") }

        send_turn(parent, "again", "web:tab1")
        again = next_turn
        [kept, again.any? { |line| line.text.include?("found it") }]
      end

      # A failure that escapes past the loop (the Engine's own end of the
      # turn, before the turn ended) carries no partial conversation: the
      # Engine keeps the turn's start only, without the report the loop
      # merged. The parent must still get the report.
      it "keeps the report a reminder turn read when the turn fails after its loop, on the real Engine" do
        kept, brought = reminder_turn_failing("failed") do
          failed = false
          allow(engine).to receive(:record_last_turn).and_wrap_original do |original, session, outcome, *rest, **options|
            if outcome == "completed" && !failed
              failed = true
              raise IOError, "disk full"
            end
            original.call(session, outcome, *rest, **options)
          end
        end

        expect([kept, brought]).to eq([false, true])
      end

      # Raised after the turn ended (engine.rb's post-turn work): the turn,
      # the report in it, was kept as completed; a release would bring the
      # report twice.
      it "commits the report a reminder turn read when the Engine fails after the turn ended" do
        kept, brought = reminder_turn_failing("completed") do
          failed = false
          allow(engine.metrics).to receive(:persist).and_wrap_original do |original, **options|
            next original.call(**options) if failed

            failed = true
            raise IOError, "disk full"
          end
        end

        expect([kept, brought]).to eq([true, false])
      end

      # Likewise for a turn that ended canceled: it was kept with the report
      # in it, so a post-turn error must not release the report.
      it "commits the report a canceled reminder turn read when the Engine fails after the turn ended" do
        kept, brought = reminder_turn_failing("canceled", canceled: true) do
          failed = false
          allow(engine.metrics).to receive(:persist).and_wrap_original do |original, **options|
            next original.call(**options) if failed

            failed = true
            raise IOError, "disk full"
          end
        end

        expect([kept, brought]).to eq([true, false])
      end

      it "commits the report a continue turn read when the turn fails, and gives a canceled one's back" do
        resumable = instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: true, run_start: 3,
                                                                  conversation: nil, tool_activity: [])
        canceled = instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: true, resumable?: false,
                                                                 conversation: nil)
        allow_any_instance_of(Samagotchi::TurnFlow).to receive(:interrupted_turn_context).and_return({})
        outcomes = [resumable, canceled, resumable, :fail, result]
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          turns << [prompt, kwargs[:pending_input].call]
          outcome = outcomes.shift
          raise server_error if outcome == :fail

          outcome
        end
        start_worker(parent)
        port = JSON.parse(File.read(File.join(parent_dir, Samagotchi::WorkerSidecar::FILE)))["port"]
        continue = lambda do
          Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{parent.id}/command"),
                         JSON.generate(line: "/continue", client_id: "web:tab1"), "Content-Type" => "application/json",
                         **bridge_auth(parent_dir))
        end

        send_turn(parent, "long task", "web:tab1")
        expect(next_turn).to eq(["long task", []])
        wait_for("the continue offer") { drain.one? { |e| e[:type] == :continue_offered } }
        child_answers("found it")

        # Canceled, the continue turn goes back to before it (TurnFlow): its
        # report with it, so its ring stays for the next turn.
        continue.call
        expect(next_turn.last.map(&:source)).to eq(["delegate_report"])
        wait_for("the /continue command to run") { drain.any? { |e| e[:type] == :command_ran } }
        loop_rounds
        expect(rings.size).to eq(1)

        offers = drain.count { |e| e[:type] == :continue_offered }
        send_turn(parent, "long task", "web:tab1")
        expect(next_turn.last.map(&:source)).to eq(["delegate_report"])
        wait_for("the report's ring to be taken") { rings.empty? }
        wait_for("the next continue offer") { drain.count { |e| e[:type] == :continue_offered } == offers + 1 }
        child_answers("more")

        # Failed before any progress, the continue turn stays (the offer
        # comes back): the report it read is delivered, once.
        continue.call
        expect(next_turn.last.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\nmore"])
        wait_for("the third continue offer") { drain.count { |e| e[:type] == :continue_offered } == offers + 2 }
        wait_for("the report's ring to be taken") { rings.empty? }

        send_turn(parent, "again", "web:tab1")
        expect(next_turn).to eq(["again", []])
      end
    end

    describe "idle (a wake turn)" do
      let(:max_wakes) { [10] }
      let(:wake_turns) { Queue.new }
      # A fresh worker's wait before its first wake turn: short here, so an
      # example doesn't sit out the real 2 s; D5's example, about that wait,
      # keeps it.
      let(:wake_start_grace) { 0.2 }

      before do
        stub_const("Samagotchi::Worker::WAKE_START_GRACE", wake_start_grace)
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("session.max_wakes") { max_wakes[0] }
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          lines = kwargs[:pending_input].call
          (prompt.nil? ? wake_turns : turns) << [prompt, kwargs, lines]
          if @fail_next
            @fail_next = false
            raise Samagotchi::LLM::ServerError.new("main: HTTP 500: boom", host: "main", status: 500)
          end

          result
        end
      end

      it "runs a continue turn for the report, origin child:<id8>, the report at its first boundary" do
        start_worker(parent)
        child_answers("found it")

        prompt, kwargs, lines = pop!(wake_turns, "the wake turn")
        expect(prompt).to be_nil
        expect(kwargs).to include(continue: true, origin: Samagotchi::TurnOrigin.new(client_id: "child:#{child.id[0, 8]}"))
        # A new reason to act, not a step-limit Continue: it doesn't resume
        # the run before it (its reasoning isn't sent back).
        expect(kwargs).not_to have_key(:resume_from)
        expect(kwargs).not_to have_key(:resumed)
        expect(lines.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\nfound it"])
        # Its message starts the turn (a reload shows the wake turn as its own).
        expect(lines.first.mark).to include(turn_start: true)
        wait_for("the report's ring to be taken") { rings.empty? }
        loop_rounds
        expect(wake_turns).to be_empty
      end

      it "takes a parent.json written while it idles at a wake turn's start too" do
        start_worker(parent)
        grand = save(Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir))
        Samagotchi::Session.reparent(parent.id, to: grand.id, from: nil, state_dir: tmpdir)
        allow(engine).to receive(:run_turn) do |session, prompt, **kwargs|
          wake_turns << [prompt, session.parent_id, kwargs[:pending_input].call]
          result
        end
        child_answers("found it")

        prompt, parent_id, = pop!(wake_turns, "the wake turn")
        expect([prompt, parent_id]).to eq([nil, grand.id])
        wait_for("the parent's save to name the grandparent") { JSON.parse(File.read(File.join(tmpdir, "#{parent.id}.json")))["parent_id"] == grand.id }
      end

      it "keeps the rings and stops waking after a failed wake turn, until a human's input" do
        @fail_next = true
        start_worker(parent)
        child_answers("found it")

        pop!(wake_turns, "the wake turn")
        loop_rounds
        expect(wake_turns).to be_empty
        expect(rings.size).to eq(1)
        expect(Samagotchi::Session.load(parent.id, state_dir: tmpdir).messages.last[:content])
          .to include("The wake turn for a delegate's report was not answered; chi starts no other wake turn until the user writes. " \
                      "chi keeps the report and brings it again with the user's next message.")

        send_turn(parent, "hello", "web:tab1")
        prompt, _kwargs, lines = next_turn
        expect(prompt).to eq("hello")
        # The report joins the human's turn.
        expect(lines.map(&:source)).to eq(["delegate_report"])
        wait_for("the report's ring to be taken") { rings.empty? }
      end

      # A Stop (or a before_turn hook's cancel) before the model call: the
      # turn is restored, its rings released; without a pause the next
      # idle tick woke again at once, up to session.max_wakes.
      it "pauses wakes after a wake turn stopped before the model call, until a human's input" do
        stopped = instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: true, resumable?: false,
                                                                conversation: nil)
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          lines = kwargs[:pending_input].call
          (prompt.nil? ? wake_turns : turns) << [prompt, kwargs, lines]
          prompt.nil? && !@stopped_once ? (@stopped_once = true) && stopped : result
        end
        start_worker(parent)
        child_answers("found it")

        pop!(wake_turns, "the wake turn")
        loop_rounds
        expect(wake_turns).to be_empty
        expect(rings.size).to eq(1)

        send_turn(parent, "hello", "web:tab1")
        prompt, _kwargs, lines = next_turn
        expect(prompt).to eq("hello")
        expect(lines.map(&:source)).to eq(["delegate_report"])
        wait_for("the report's ring to be taken") { rings.empty? }
      end

      it "stops at session.max_wakes in a row, says so once, and wakes again after a human's input" do
        max_wakes[0] = 1
        start_worker(parent)
        child_answers("one")
        expect(pop!(wake_turns, "the wake turn").last.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\none"])
        wait_for("the report's ring to be taken") { rings.empty? }

        child_answers("two")
        notice = nil
        wait_for("the max_wakes notice") { notice = drain.find { |e| e[:type] == :hook_notice } }
        expect(notice[:text]).to eq("1 delegate report waiting; it joins your next message (1 turn ran for reports in a row, session.max_wakes)")
        loop_rounds
        expect(wake_turns).to be_empty
        expect(drain.count { |e| e[:type] == :hook_notice }).to eq(1)

        send_turn(parent, "hi", "web:tab1")
        expect(next_turn&.last&.map(&:text)).to eq(["session: #{child.id}\nstatus: answered\n---\ntwo"])
        child_answers("three")
        pop!(wake_turns, "the wake turn")
      end

      context "with the real start grace" do
        let(:wake_start_grace) { Samagotchi::Worker::WAKE_START_GRACE }

        it "lets the message a fresh worker was started for go first; the report joins its turn (D5)" do
          child_answers("found it")
          start_worker(parent)
          # Delivered just after the worker started (chi send to a stopped parent).
          send_turn(parent, "anything new?", "cli:send")

          prompt, _kwargs, lines = next_turn
          expect(prompt).to eq("anything new?")
          expect(lines.map(&:source)).to eq(["delegate_report"])
          loop_rounds
          expect(wake_turns).to be_empty
        end
      end

      it "starts the wake turn with its first merged line, whoever sent it" do
        start_worker(parent)
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          send_turn(parent, "me too", "web:tab1")
          wake_turns << [prompt, kwargs, kwargs[:pending_input].call]
          result
        end
        child_answers("found it")

        _prompt, _kwargs, lines = pop!(wake_turns, "the wake turn")
        expect(lines.map(&:source)).to eq([nil, "delegate_report"])
        expect(lines.first.mark).to include(turn_start: true)
        expect(lines.last.mark).to be_nil
      end

      it "doesn't wake in queue mode: the report joins the next turn" do
        allow(Samagotchi::Config).to receive(:get).with("session.delegate_reports").and_return("queue")
        start_worker(parent)
        child_answers("found it")
        loop_rounds
        expect(wake_turns).to be_empty

        send_turn(parent, "hi", "web:tab1")
        expect(next_turn&.last&.map(&:source)).to eq(["delegate_report"])
      end

      it "doesn't wake while a continue offer waits; the report joins the continue turn" do
        resumable = instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: true, run_start: 3,
                                                                  conversation: nil, tool_activity: [])
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          lines = kwargs[:pending_input].call
          (prompt.nil? && !kwargs[:origin].to_h[:client_id].to_s.start_with?("child:") ? wake_turns : turns) << [prompt, kwargs, lines]
          prompt == "long task" ? resumable : result
        end
        allow_any_instance_of(Samagotchi::TurnFlow).to receive(:interrupted_turn_context).and_return({})
        start_worker(parent)
        send_turn(parent, "long task", "web:tab1")
        expect(next_turn&.first).to eq("long task")
        wait_for("the continue offer") { drain.any? { |e| e[:type] == :continue_offered } }

        child_answers("found it")
        loop_rounds
        expect(turns).to be_empty
        expect(rings.size).to eq(1)
      end
    end

    # P4 (3b): a child's hook question the parent may only deny under the
    # child's strategy is relayed to the parent's user at a boundary, on the
    # turn thread, before the boundary merges anything (M6); the model gets
    # the outcome line as the report.
    describe "a child's hook question it may only deny" do
      let(:cost_cap) do
        { "id" => "h1", "kind" => "hook", "hook" => "cost-cap", "header" => "Cost cap", "question" => "Spent $5.",
          "options" => %w[Continue Stop], "effects" => %w[spend deny], "status" => "pending" }
      end
      let(:relayed) { [] }

      # A fresh worker's wait before its first wake turn, short as in "idle
      # (a wake turn)", so a wake-turn example doesn't sit out the real 2 s.
      before { stub_const("Samagotchi::Worker::WAKE_START_GRACE", 0.2) }
      after { @child_lock&.release }

      # The child's live worker holds its question (ReplyWait reports only those).
      def child_asks(pending = cost_cap)
        @child_lock ||= Samagotchi::OwnerLock.acquire(child_dir, kind: "worker")
        Samagotchi::Tools::DelegateWait.mark_started(parent.id, child, state_dir: tmpdir)
        s = Samagotchi::Session.load(child.id, state_dir: tmpdir)
        s.parent_answers = "hard"
        s.pending_question = pending
        s.save(state_dir: tmpdir)
        Samagotchi::SessionInbox.write_ring(parent_dir, child_id: child.id, why: "question")
      end

      def relay_outcome(line: "hook question relayed to your user: Cost cap → Stop", stopped: false, &before)
        allow(Samagotchi::Tools::DelegateRelay).to receive(:call) do |child_id, question, relay:, **|
          before&.call
          relayed << [child_id, question.id, relay.class, drain.map { |e| e[:type] }]
          Samagotchi::Tools::DelegateRelay::Outcome.new(line: line, stopped: stopped)
        end
      end

      def report_text(line)
        "session: #{child.id}\nstatus: question\n#{line}\n#{Samagotchi::Tools::DelegateWait::REPORT_NEXT_REPLY}"
      end

      it "relays it at a boundary and merges the outcome line as the report, announced after the card settles" do
        relay_outcome
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          child_asks
          turns << [prompt, kwargs[:pending_input].call]
          result
        end
        start_worker(parent)
        send_turn(parent, "keep going", "web:tab1")

        _prompt, lines = next_turn
        expect(lines.map(&:text)).to eq([report_text("hook question relayed to your user: Cost cap → Stop")])
        expect(relayed.size).to eq(1)
        child_id, qid, peer, seen = relayed.first
        expect([child_id, qid, peer]).to eq([child.id, "h1", Samagotchi::Engine::RelayPeer])
        expect(seen).not_to include(:input_merged)
        wait_for("the input_merged event") { drain.any? { |e| e[:type] == :input_merged } }
        wait_for("the report's ring to be taken") { rings.empty? }
      end

      it "opens no card for a question answered on the child after the ring was taken (M1)" do
        relay_outcome
        allow_any_instance_of(Samagotchi::ChildReports).to receive(:take).and_wrap_original do |original|
          original.call.tap do
            s = Samagotchi::Session.load(child.id, state_dir: tmpdir)
            s.pending_question = nil
            s.save(state_dir: tmpdir)
          end
        end
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          child_asks
          turns << [prompt, kwargs[:pending_input].call]
          result
        end
        start_worker(parent)
        send_turn(parent, "keep going", "web:tab1")

        _prompt, lines = next_turn
        expect(relayed).to be_empty
        expect(lines.map(&:text)).to eq([report_text("hook question relayed to your user: Cost cap → answered on the child")])
      end

      it "keeps the ring and the cursor when the card is stopped, and offers it again at the user's next turn (H1)" do
        relay_outcome(line: "hook question relayed to your user: Cost cap → still open (your turn was stopped)", stopped: true)
        calls = 0
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          calls += 1
          child_asks if calls == 1
          turns << [prompt, kwargs[:pending_input].call]
          result
        end
        start_worker(parent)
        send_turn(parent, "keep going", "web:tab1")

        _prompt, lines = next_turn
        expect(lines).to eq([])
        loop_rounds
        # No wake turn re-offers it at once after a Stop: the user's next turn does.
        expect(turns).to be_empty
        expect(rings.size).to eq(1)
        expect(cursor.report_claim).to be_nil
        expect(cursor.baseline&.question_id).not_to eq("h1")

        relay_outcome
        send_turn(parent, "again", "web:tab1")
        _prompt, lines = next_turn
        expect(lines.map(&:text)).to eq([report_text("hook question relayed to your user: Cost cap → Stop")])
        # Offered again: the stopped card's, then this one.
        expect(relayed.map { |row| row[1] }).to eq(%w[h1 h1])
      end

      # M-a: a Stop holds back only that question: no wake turn offers it
      # again until the user's next input, while another child's report
      # still wakes the parent.
      it "holds back only the stopped question after a Stop in a wake turn, until the user's next input" do
        relay_outcome(line: "hook question relayed to your user: Cost cap → still open (your turn was stopped)", stopped: true)
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          turns << [prompt, kwargs[:pending_input].call]
          result
        end
        start_worker(parent)
        child_asks

        expect(next_turn).to eq([nil, []])
        loop_rounds(3)
        expect(turns).to be_empty
        expect(rings.size).to eq(1)

        other = make_child
        Samagotchi::Tools::DelegateWait.mark_started(parent.id, other, state_dir: tmpdir)
        other_dir = Samagotchi::Session.session_dir(other.id, state_dir: tmpdir)
        Samagotchi::SessionInbox.write_output(other_dir, "linted")
        s = Samagotchi::Session.load(other.id, state_dir: tmpdir)
        s.last_turn = { "outcome" => "completed", "ended_at" => Time.now.iso8601(6) }
        s.save(state_dir: tmpdir)
        Samagotchi::SessionInbox.write_ring(parent_dir, child_id: other.id, why: "turn_end")
        _prompt, lines = next_turn
        expect(lines.map(&:text)).to eq(["session: #{other.id}\nstatus: answered\n---\nlinted"])
        expect(relayed.size).to eq(1)

        relay_outcome
        send_turn(parent, "again", "web:tab1")
        _prompt, lines = next_turn
        expect(lines.map(&:text)).to eq([report_text("hook question relayed to your user: Cost cap → Stop")])
      end

      it "relays it in a wake turn at the turn's first boundary, not before the turn" do
        relay_outcome
        allow(engine).to receive(:run_turn) do |_session, prompt, **kwargs|
          turns << [prompt, relayed.size, kwargs[:pending_input].call]
          result
        end
        start_worker(parent)
        child_asks

        prompt, before, lines = next_turn
        expect(prompt).to be_nil
        expect(before).to eq(0)
        expect(lines.map(&:text)).to eq([report_text("hook question relayed to your user: Cost cap → Stop")])
      end
    end

    def drain
      list = []
      list << events.pop until events.empty?
      (@seen ||= []).concat(list)
    end
  end
end
