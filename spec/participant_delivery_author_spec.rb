# frozen_string_literal: true

require "spec_helper"
require "samagotchi/worker_link"
require "support/worker_fixtures"
require "tmpdir"
require "json"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/worker"
require "samagotchi/bridge"
require "samagotchi/bridge_client"
require "samagotchi/queued_command"
require "samagotchi/participants"
require "samagotchi/web/app"
require "samagotchi/session_access/remote"
require "samagotchi/session_access/web_bridge_client"
require_relative "support/remote_backend"

# A participant's author survives every way their input reaches a
# session (a queued turn's announcement, its own turn's saved prompt), and
# the worker's own layer keeps it a turn of its own: never merged into a
# running turn whatever its delivery, never a command (a /word input file
# or POST /turn). The owner's events and commands carry no author key.
RSpec.describe "a participant's author on delivery" do
  let(:tmpdir) { Dir.mktmpdir("delivery-author") }

  after { FileUtils.rm_rf(tmpdir) }

  def read_file(path) = JSON.parse(File.read(path))

  describe Samagotchi::QueuedCommand do
    it "names a participant's author in its events, the owner's none" do
      expect(described_class.mint("/model x", client_id: "web:t", author: "p:p_1").event_fields).to include(author: "p:p_1")
      expect(described_class.mint("/model x", client_id: "web:t").event_fields.keys).to eq(%i[command_id client_id line])
    end
  end

  describe Samagotchi::Worker do
    around do |example|
      WebMock.allow_net_connect! if defined?(WebMock)
      with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run }
    ensure
      WebMock.disable_net_connect! if defined?(WebMock)
    end

    let!(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let!(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
    let(:result) { instance_double(Samagotchi::LLM::ModelResult, output: "", canceled?: false, resumable?: false) }
    let(:drained) { Queue.new }
    let(:events) { Queue.new }
    let(:grant) do
      grants = Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: tmpdir))
      Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", mode: "pair", state_dir: tmpdir).grant
    end

    before do
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR))
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
      allow(engine).to receive_messages(start_idle: nil, stop_idle: nil)
      engine.subscribe(observer: ->(event) { events << event if %i[command_queued].include?(event[:type]) })
    end

    after do
      @thread&.kill
      @thread&.join(2)
    end

    def start_worker
      @worker = worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                             idle_exit_minutes: 0, poll_interval: 0.02)
      @thread = Thread.new { worker.run }
      @thread.report_on_exception = false
    end

    it "never merges a participant's line into a running turn, whatever its delivery: it waits for its own" do
      author = grant.author
      engine.session_state_dir = tmpdir
      prompts = Queue.new
      allow(engine).to receive(:run_turn) do |turn_session, prompt, **kwargs|
        prompts << [prompt, kwargs[:origin]&.author]
        if prompt == "first"
          engine.instance_variable_get(:@participants).refresh!(turn_session)
          Samagotchi::SessionInbox.write_input(session_dir, prompt: "owner steer", client_id: "web:o")
          Samagotchi::SessionInbox.write_input(session_dir, prompt: "is step 3 safe?", client_id: "review:p",
                                                            author: author, delivery: "cut")
          drained << kwargs[:pending_input].call
        end
        result
      end
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "first", client_id: "web:o", enqueued_id: "e1")

      lines = pop!(drained, "the drain's lines")
      expect(lines.map { |l| [l.text, l.author] }).to eq([["owner steer", nil]])
      expect(pop!(prompts, "the owner's turn")).to eq(["first", nil])
      expect(pop!(prompts, "the participant's own turn")).to eq(["is step 3 safe?", author])
    end

    # W3: the owner's input never goes into a participant's read-only
    # review turn, whatever its delivery: it runs as the owner's own turn
    # after it (an owner's turn still takes the owner's steer).
    it "never merges the owner's line into a participant's running turn: it runs as the owner's own turn after it" do
      author = grant.author
      engine.session_state_dir = tmpdir
      prompts = Queue.new
      allow(engine).to receive(:run_turn) do |turn_session, prompt, **kwargs|
        prompts << [prompt, kwargs[:origin]&.author]
        if prompt == "is step 3 safe?"
          engine.instance_variable_get(:@participants).refresh!(turn_session)
          Samagotchi::SessionInbox.write_input(session_dir, prompt: "owner steer", client_id: "web:o", delivery: "cut")
          Samagotchi::SessionInbox.write_input(session_dir, prompt: "owner next", client_id: "tui:o")
          drained << kwargs[:pending_input].call
        end
        result
      end
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "is step 3 safe?", client_id: "review:p", author: author,
                                                        enqueued_id: "p1")

      expect(pop!(drained, "the participant turn's drain")).to eq([])
      expect(pop!(prompts, "the participant's turn")).to eq(["is step 3 safe?", author])
      expect(pop!(prompts, "the owner's first queued turn")).to eq(["owner steer", nil])
      expect(pop!(prompts, "the owner's second queued turn")).to eq(["owner next", nil])
    end

    it "doesn't start a participant's queued turn past their cap: dropped from the queue, audited, the owner told once" do
      author = grant.author
      notices = Queue.new
      dequeued = Queue.new
      engine.subscribe(observer: lambda { |event|
        notices << event if event[:type] == :hook_notice
        dequeued << event if event[:type] == :turn_dequeued
      })
      allow(engine.metrics).to receive(:spend).with(author).and_return(2.5)
      allow(engine).to receive(:run_turn).and_return(result)
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "q1", client_id: "review:p", author: author, enqueued_id: "e1")
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "q2", client_id: "review:p", author: author, enqueued_id: "e2")

      expect(pop!(dequeued, "the first refused turn")).to include(enqueued_id: "e1")
      expect(pop!(dequeued, "the second refused turn")).to include(enqueued_id: "e2")
      notice = pop!(notices, "the owner's cap notice")
      # A working session: its participant's turns are pair turns.
      expect(notice[:text]).to eq("Alex reached their $2.00 cap: their turns stop and are refused until you raise it " \
                                  "(chi share cap #{session.id[0, 8]} #{grant.id} AMOUNT).")
      expect(notices).to be_empty
      expect(engine).not_to have_received(:run_turn)
      refused = File.readlines(File.join(session_dir, Samagotchi::Participants::LOG)).map { |line| JSON.parse(line) }
                    .select { |line| line["event"] == "turn" }
      expect(refused.map { |line| line.values_at("enqueued_id", "reason") }).to eq([%w[e1 cap_reached], %w[e2 cap_reached]])
    end

    it "stops a participant's running pair turn at their cap (Engine#participant_stop): the reason, the owner told once" do
      author = grant.author
      notices = Queue.new
      engine.subscribe(observer: ->(event) { notices << event if event[:type] == :hook_notice })
      spend = 1.0
      allow(engine.metrics).to receive(:spend).with(author) { spend }
      reasons = Queue.new
      allow(engine).to receive(:run_turn) do |*_args, **_opts|
        check = engine.instance_variable_get(:@participant_stop)
        reasons << check.call(author).inspect
        spend = 2.5
        reasons << check.call(author).inspect
        reasons << check.call(author).inspect
        reasons << notices.size
        result
      end
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "q1", client_id: "review:p", author: author, enqueued_id: "e1")

      expect(pop!(reasons, "under the cap")).to eq("nil")
      expect(pop!(reasons, "past the cap")).to eq('"Alex reached their $2.00 cap"')
      expect(pop!(reasons, "past the cap again")).to eq('"Alex reached their $2.00 cap"')
      expect(pop!(reasons, "the notices so far")).to eq(1)
      notice = pop!(notices, "the owner's cap notice")
      expect(notice[:text]).to start_with("Alex reached their $2.00 cap: their turns stop")
    end

    it "stops a participant's running pair turn once their link is revoked mid-turn (Engine#participant_stop)" do
      author = grant.author
      reasons = Queue.new
      allow(engine).to receive(:run_turn) do |*_args, **_opts|
        check = engine.instance_variable_get(:@participant_stop)
        reasons << check.call(author).inspect
        grants = Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: tmpdir))
        Samagotchi::Participants.revoke(grants, session_id: session.id, id: grant.id, state_dir: tmpdir)
        reasons << check.call(author).inspect
        result
      end
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "q1", client_id: "review:p", author: author, enqueued_id: "e1")

      expect(pop!(reasons, "while the link works")).to eq("nil")
      expect(pop!(reasons, "once it is revoked")).to eq(%("Alex's link was revoked or expired"))
    end

    # Their chi send --wait (and chi web's participant /wait) reads the
    # refusal from the settled record: it ends at once, never at its timeout.
    it "ends a wait on a refused participant turn with the refusal, not at its timeout" do
      author = grant.author
      dequeued = Queue.new
      engine.subscribe(observer: ->(event) { dequeued << event if event[:type] == :turn_dequeued })
      allow(engine.metrics).to receive(:spend).with(author).and_return(2.5)
      allow(engine).to receive(:run_turn).and_return(result)
      baseline = Samagotchi::ReplyWait.baseline_of(Samagotchi::Session.load(session.id, state_dir: tmpdir))
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "q1", client_id: "review:p", author: author, enqueued_id: "e1")
      pop!(dequeued, "the refused turn")

      wait = Samagotchi::ReplyWait.call(session.id, state_dir: tmpdir, cursor: nil, timeout: 5, poll_interval: 0.02,
                                                    baseline: baseline, turn: "e1", queued: true)

      expect(wait).to have_attributes(status: :no_reply, outcome: "canceled", cancel_reason: "cap_reached")
      # Whose turn it was, for a chi web restarted since (ParticipantAccess#turn_author).
      expect(Samagotchi::TurnCheckpoint.settled_turn(session_dir, "e1").author).to eq(author)
      expect(Samagotchi::ParentReport.status(wait)).to eq("refused")
      expect(Samagotchi::ParentReport.exit_status(wait)).to eq(Samagotchi::CLI::Exit::FAILED)
      expect(Samagotchi::ParentReport.json(wait, session_id: session.id)[:detail])
        .to start_with("the turn was refused (#{Samagotchi::ParticipantMessages::CAP_REACHED}); no turn ran for it")
    end

    it "doesn't start a revoked participant's queued turn (dropped from the queue, audited)" do
      author = grant.author
      dequeued = Queue.new
      engine.subscribe(observer: ->(event) { dequeued << event if event[:type] == :turn_dequeued })
      grants = Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: tmpdir))
      Samagotchi::Participants.revoke(grants, session_id: session.id, id: grant.id, state_dir: tmpdir)
      allow(engine).to receive(:run_turn).and_return(result)
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "q", client_id: "review:p", author: author, enqueued_id: "e1")

      expect(pop!(dequeued, "the refused turn")).to include(enqueued_id: "e1")
      expect(engine).not_to have_received(:run_turn)
      refused = File.readlines(File.join(session_dir, Samagotchi::Participants::LOG)).map { |line| JSON.parse(line) }
                    .select { |line| line["event"] == "turn" }
      expect(refused.map { |line| line["reason"] }).to eq(["revoked"])
    end

    it "saves a participant's prompt as theirs before the loop's first boundary (a worker killed there keeps the author)" do
      author = grant.author
      engine.session_state_dir = tmpdir
      saved = Queue.new
      allow(engine).to receive(:run_turn) do |turn_session, _prompt, **|
        saved << Samagotchi::Session.load(turn_session.id, state_dir: tmpdir).messages.last
        result
      end
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "is step 3 safe?", client_id: "web:t", author: author)

      expect(pop!(saved, "the running save's last message"))
        .to eq(role: "user", content: "is step 3 safe?", author: author, author_name: "Alex", at: message_at)
    end

    it "refuses a participant's /word or !line input file (dropped, audited); the owner's is queued" do
      allow(engine).to receive(:run_turn).and_return(result)
      start_worker
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "/toolkit full", client_id: "review:p_1", author: "p:p_1")
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "!ls", client_id: "review:p_1", author: "p:p_1")
      Samagotchi::SessionInbox.write_input(session_dir, prompt: "/title mine", client_id: "web:o")

      mine = pop!(events, "the owner's command_queued")
      expect(mine).to include(line: "/title mine")
      expect(mine).not_to have_key(:author)
      expect(engine).not_to have_received(:run_turn)
      audit = File.readlines(File.join(session_dir, Samagotchi::Participants::LOG)).map { |line| JSON.parse(line) }
      expect(audit.select { |line| line["event"] == "refused" }.map { |line| line.values_at("participant", "what") })
        .to eq([%w[p_1 command], %w[p_1 command]])
    end

    # The owner's turn ran out of iterations: its Continue offer is the
    # owner's to answer, so a participant's queued turn waits (in the
    # inbox, still queued) until the owner continues, stops or sends a turn
    # of their own; then the held turns run in order.
    describe "while the owner's Continue offer stands" do
      let(:kernel) { engine.instance_variable_get(:@kernel) }
      let(:prompts) { Queue.new }
      let(:resolved) { Queue.new }
      let(:dequeued) { Queue.new }
      let(:t0) { Time.now }

      before do
        engine.session_state_dir = tmpdir
        allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
        engine.subscribe(observer: lambda { |event|
          resolved << event if event[:type] == :continue_resolved
          dequeued << event if event[:type] == :turn_dequeued
        })
      end

      # The owner's "long task" runs out of iterations; while it runs, the
      # inputs +during+ names are written (queued for after it).
      def run_out_of_iterations(during: [])
        allow(kernel).to receive(:run) do |messages, **|
          prompt = messages.last[:content].to_s.lines.last.to_s
          prompts << prompt
          if prompt == "long task"
            during.each_with_index { |input, i| write_queued(**input, now: t0 + 1 + i) }
            Samagotchi::LLM::ModelResult.new(
              text: "", conversation: messages + [{ role: "model", content: "calling ls" }, { role: "tool_response", content: "a b" }],
              exhausted: true, pending_tool_calls: true, canceled: false, tool_activity: []
            )
          else
            Samagotchi::LLM::ModelResult.new(text: "OK", conversation: messages + [{ role: "model", content: "OK" }],
                                             exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
          end
        end
      end

      def write_queued(prompt:, author: nil, enqueued_id: nil, now: Time.now)
        Samagotchi::SessionInbox.write_input(session_dir, prompt: prompt, client_id: author ? "review:p" : "web:o",
                                                          enqueued_id: enqueued_id, author: author, delivery: "queue", now: now)
      end

      it "holds a participant's turn until the owner answers the offer, then runs it (the offer isn't dropped)" do
        run_out_of_iterations(during: [{ prompt: "is step 3 safe?", author: grant.author, enqueued_id: "p1" },
                                       { prompt: "/continue no" }])
        start_worker
        write_queued(prompt: "long task", now: t0)

        expect(pop!(prompts, "the owner's turn")).to eq("long task")
        expect(pop!(resolved, "the offer's answer")).to include(decision: "abort", client_id: "web:o")
        expect(pop!(prompts, "the held turn")).to eq("is step 3 safe?")
        expect(resolved).to be_empty
        expect(dequeued).to be_empty
      end

      it "runs the owner's own turn first (it drops the offer), then the held turns in the order they came" do
        run_out_of_iterations(during: [{ prompt: "first", author: grant.author, enqueued_id: "p1" },
                                       { prompt: "something else" },
                                       { prompt: "second", author: grant.author, enqueued_id: "p2" }])
        start_worker
        write_queued(prompt: "long task", now: t0)

        expect(Array.new(4) { pop!(prompts, "a turn") }).to eq(["long task", "something else", "first", "second"])
        expect(pop!(resolved, "the dropped offer")).to include(decision: "dropped", client_id: "web:o")
      end

      it "tells a client asking to exit or restart that the step-limit question waits, not that a prompt is queued" do
        run_out_of_iterations(during: [{ prompt: "is step 3 safe?", author: grant.author, enqueued_id: "p1" }])
        start_worker
        write_queued(prompt: "long task", now: t0)
        expect(pop!(prompts, "the owner's turn")).to eq("long task")
        wait_for("the offer's question") do
          Samagotchi::Session.load(session.id, state_dir: tmpdir).pending_question&.kind.to_s == "continue"
        end

        expect(@worker.send(:exit_request, "web:o", restart: true)).to have_attributes(reason: :continue_offered)
        expect(@worker.send(:exit_request, "web:o")).to have_attributes(reason: :continue_offered)
        expect(Samagotchi::SessionInbox.find_new_input_files(session_dir).size).to eq(1)
      end

      it "doesn't run a held turn whose link ended meanwhile: dropped from the queue and audited as it's released" do
        run_out_of_iterations(during: [{ prompt: "is step 3 safe?", author: grant.author, enqueued_id: "p1" }])
        start_worker
        write_queued(prompt: "long task", now: t0)
        expect(pop!(prompts, "the owner's turn")).to eq("long task")
        wait_for("the offer's question") do
          Samagotchi::Session.load(session.id, state_dir: tmpdir).pending_question&.kind.to_s == "continue"
        end

        grants = Samagotchi::Web::Grants.new(Samagotchi::Web::Grants.path(state_dir: tmpdir))
        Samagotchi::Participants.revoke(grants, session_id: session.id, id: grant.id, state_dir: tmpdir)
        write_queued(prompt: "/continue no")

        expect(pop!(resolved, "the offer's answer")).to include(decision: "abort")
        expect(pop!(dequeued, "the refused turn")).to include(enqueued_id: "p1")
        expect(prompts).to be_empty
      end
    end
  end

  describe Samagotchi::Bridge, "POST /session/:id/turn" do
    let(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel) }
    let(:session_dir) { Samagotchi::Session.session_dir("s1", state_dir: tmpdir) }
    let(:announced) { [] }
    let(:commands) { [] }

    include WorkerFixtures

    before do
      WebMock.allow_net_connect! if defined?(WebMock)
      hold_worker(session_dir)
      engine.subscribe(observer: ->(event) { announced << event })
      @bridge = described_class.new(engine: engine, state_dir: tmpdir, session_id: "s1", heartbeat_interval: 0.2,
                                    on_command: lambda { |command, **|
                                      commands << command
                                      :anytime
                                    }).start
      @client = Samagotchi::WorkerLink.client("s1", session_dir: session_dir)
    end

    after do
      @bridge.stop
      WebMock.disable_net_connect! if defined?(WebMock)
    end

    def of_type(type) = announced.select { |event| event[:type] == type }

    it "announces a participant's queued turn with its author, the owner's without" do
      @client.post_turn(prompt: "theirs", client_id: "web:t", author: "p:p_1")
      @client.post_turn(prompt: "mine", client_id: "web:o")

      theirs, mine = of_type(:turn_enqueued)
      expect(theirs).to include(prompt: "theirs", author: "p:p_1")
      expect(mine).not_to have_key(:author)
    end

    it "refuses a participant's /word or !line sent as a message (403 not_permitted); the owner's is the command" do
      ["/title x", "/toolkit full", "!ls"].each do |line|
        reply = @client.post_turn(prompt: line.delete("\\"), client_id: "review:p_1", author: "p:p_1")
        expect([reply.status, reply.json]).to eq([403, { "error" => "not_permitted", "detail" => Samagotchi::Participants::NOT_PERMITTED }])
      end
      @client.post_turn(prompt: "/title y", client_id: "web:o")

      expect(commands.map(&:author)).to eq([nil])
      expect(of_type(:command_queued).map { |event| event[:line] }).to eq(["/title y"])
    end

    it "refuses a participant's turn past their pending limit (429 too_many_turns); another's and the owner's go in" do
      2.times { |i| expect(@client.post_turn(prompt: "q#{i}", client_id: "review:p_1", author: "p:p_1", pending_limit: 2).status).to eq(202) }
      reply = @client.post_turn(prompt: "q2", client_id: "review:p_1", author: "p:p_1", pending_limit: 2)
      expect([reply.status, reply.json]).to eq([429, { "error" => "too_many_turns",
                                                       "detail" => Samagotchi::ParticipantMessages::TOO_MANY_TURNS }])
      expect(@client.post_turn(prompt: "k", client_id: "review:p_2", author: "p:p_2", pending_limit: 2).status).to eq(202)
      expect(@client.post_turn(prompt: "mine", client_id: "web:o").status).to eq(202)
      expect(of_type(:turn_enqueued).map { |event| event[:prompt] }).to eq(%w[q0 q1 k mine])
    end

    it "queues a participant's message as its own turn whatever its delivery asks, and never cuts" do
      reply = @client.post_turn(prompt: "theirs", client_id: "review:p_1", author: "p:p_1", delivery: "cut")
      expect(reply.status).to eq(202)
      expect(reply.json).not_to have_key("cut")
      file = Dir[File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR, "*")].first
      expect(read_file(file)).to include("delivery" => "queue", "author" => "p:p_1")
    end

    # W3: the owner's input while a participant's review turn runs queues
    # behind it, whatever it asked (a steer, a cut), and the sender is told;
    # during the owner's own turn it steers as before.
    it "queues the owner's message behind a participant's running turn, never steering or cutting it" do
      accumulator = @bridge.instance_variable_get(:@accumulator)
      accumulator.call({ type: :turn_started, prompt: "theirs", origin: { client_id: "review:p_1", author: "p:p_1" },
                         author: "p:p_1" })
      %w[next_step cut].each do |delivery|
        reply = @client.post_turn(prompt: "owner #{delivery}", client_id: "web:o", delivery: delivery)
        expect(reply.status).to eq(202)
        expect(reply.json).to include("delivery" => "queue")
        expect(reply.json).not_to have_key("cut")
      end
      expect(of_type(:turn_enqueued).map { |event| event[:delivery] }).to eq(%w[queue queue])
      files = Dir[File.join(session_dir, Samagotchi::SessionInbox::INPUT_DIR, "*.json")]
      expect(files.map { |file| read_file(file)["delivery"] }).to eq(%w[queue queue])

      accumulator.call({ type: :turn_completed })
      accumulator.call({ type: :turn_started, prompt: "mine", origin: { client_id: "web:o" } })
      expect(@client.post_turn(prompt: "owner steer", client_id: "web:o").json).to include("delivery" => "next_step")
    end
  end

  describe Samagotchi::Bridge::TurnAccumulator do
    it "keeps the author on its queued turn and queued command rows" do
      accumulator = described_class.new
      accumulator.call({ type: :turn_enqueued, enqueued_id: "e1", client_id: "web:t", prompt: "x", author: "p:p_1" })
      accumulator.call({ type: :turn_enqueued, enqueued_id: "e2", client_id: "web:o", prompt: "y" })
      accumulator.call({ type: :command_queued, command_id: "c1", client_id: "web:t", line: "/model a", waits: "turn_end",
                         author: "p:p_1" })
      accumulator.call({ type: :command_queued, command_id: "c2", client_id: "web:o", line: "/model b", waits: "turn_end" })

      expect(accumulator.queued).to eq([{ enqueued_id: "e1", client_id: "web:t", prompt: "x", author: "p:p_1" },
                                        { enqueued_id: "e2", client_id: "web:o", prompt: "y" }])
      expect(accumulator.queued_commands).to eq([{ command_id: "c1", client_id: "web:t", line: "/model a", author: "p:p_1" },
                                                 { command_id: "c2", client_id: "web:o", line: "/model b" }])
    end
  end

  describe Samagotchi::SessionAccess::WebBridgeClient do
    let(:app) { RemoteBackend.app(state_dir: tmpdir) }
    let(:remote) { RemoteBackend.access(state_dir: tmpdir, app: app) }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap { |s| s.save(state_dir: tmpdir) }
    end
    let(:bridge) { instance_double(Samagotchi::BridgeClient) }

    it "takes an author but never sends it: the remote chi web stamps the author from its token" do
      allow(Samagotchi::SessionManager).to receive(:resume_session)
      allow(app).to receive_messages(live_bridge_client: bridge, bridge_client: bridge)
      allow(bridge).to receive(:post_turn)
        .and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: JSON.generate(status: "accepted")))
      client = remote.attach_client(session.id, worker: { "epoch" => "e1", "started_at" => "t" })

      expect(client.post_turn(prompt: "go", client_id: "tui:1@mac", author: "p:p_forged").status).to eq(202)
      expect(bridge).to have_received(:post_turn).with(prompt: "go", client_id: "tui:1@mac")
    end
  end
end
