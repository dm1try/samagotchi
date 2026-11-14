# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "samagotchi/objectives"
require "samagotchi/session_commands"
require "samagotchi/turn_checkpoint"
require "samagotchi/worker_inbound"
require "samagotchi/worker_wakes"
require "samagotchi/context_absorber"
require "samagotchi/context_sources"
require "samagotchi/archive_store"

# What comes into a worker's session between turns and how each kind is
# saved; the turns they start are the Worker's (worker_*_spec).
RSpec.describe Samagotchi::WorkerInbound do
  # The Engine's part: notes into the conversation, the command check, a
  # rollback.
  let(:fake_engine) do
    Class.new do
      attr_reader :rolled_back, :announced

      def initialize(session)
        @session = session
        @announced = []
        @enqueued_ids = {}
      end

      def announce(**event) = @announced << event

      def claim_enqueued_id(id)
        return true if id.to_s.empty?
        return false if @enqueued_ids.key?(id)

        @enqueued_ids[id] = true
      end

      def finish_enqueued_id(_id); end
      def command_registry = self
      def command?(text) = text.start_with?("/model", "!")
      def messages_checkpoint = @session.messages.map(&:dup)
      def rollback_to(messages) = (@rolled_back = messages)

      def add_context_note(session, note)
        return if session.messages.any? { |m| m[:note_id] == note[:note_id] }

        session.messages = session.messages + [Samagotchi::ContextNote.message(**note)]
      end
    end
  end

  let(:tmpdir) { Dir.mktmpdir("worker-inbound") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir)
                       .tap { |s| s.save(state_dir: tmpdir) }
  end
  let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
  let(:engine) { fake_engine.new(session) }
  let(:absorber) { instance_double(Samagotchi::ContextAbsorber, pending: nil, commit: nil) }
  let(:wakes) { Samagotchi::WorkerWakes.new(grace: 0, max: -> { 10 }) }
  let(:stopped) { [false] }
  let(:queued) { [] }
  let(:awaiting) { [false] }
  let(:inbound) do
    described_class.new(session: session, state_dir: tmpdir, session_dir: session_dir, engine: engine,
                        context_absorber: absorber, wakes: wakes, awaiting_continue: -> { awaiting[0] },
                        stopped: -> { stopped[0] },
                        queue_command: ->(line, client_id, _after_file, enqueued_id) { queued << [line, client_id, enqueued_id] })
  end

  after { FileUtils.rm_rf(tmpdir) }

  def saved = Samagotchi::Session.load(session.id, state_dir: tmpdir)

  def failing_save
    allow(session).to receive(:save).and_raise(Errno::ENOSPC)
  end

  describe ".save_or_log" do
    it "logs a failed save and says whether it saved" do
      expect(described_class.save_or_log(:turn) { :ok }).to be(true)
      expect(Samagotchi::Log).to receive(:exception).with(:worker, "save_failed", kind_of(Errno::ENOSPC), at: :turn)
      expect(described_class.save_or_log(:turn) { raise Errno::ENOSPC }).to be(false)
    end
  end

  describe "#absorb_notes" do
    before { Samagotchi::SessionInbox.write_note(session.id, text: "the build is red", state_dir: tmpdir) }

    it "adds the notes, saves, then deletes their files" do
      inbound.absorb_notes

      expect(saved.messages.map { |m| m[:content] }.join).to include("the build is red")
      expect(Samagotchi::SessionInbox.find_new_note_files(session_dir)).to be_empty
    end

    describe "objectives notes" do
      let(:first_list) { Samagotchi::Objectives::List.new.add("Old aim") }
      let(:second_list) { first_list.add("New aim") }

      def queue_list(list)
        Samagotchi::SessionInbox.write_note(session.id, text: list.text, source: Samagotchi::Objectives::SOURCE,
                                                        objectives: list.to_payload, state_dir: tmpdir)
      end

      it "takes only the newest list in a batch, deletes them all and keeps the plain notes" do
        queue_list(first_list)
        queue_list(second_list)
        Samagotchi::SessionInbox.write_note(session.id, text: "fyi", state_dir: tmpdir)

        inbound.absorb_notes

        lists = session.messages.select { |m| m[:objectives] }
        expect(lists.size).to eq(1)
        expect(Samagotchi::ContextNote.text_of(lists.first)).to eq("O1 Old aim\nO2 New aim")
        expect(session.messages.map { |m| Samagotchi::ContextNote.text_of(m) }).to include("the build is red", "fyi")
        expect(Samagotchi::SessionInbox.find_new_note_files(session_dir)).to be_empty
        expect(Samagotchi::Objectives.build(saved.messages)).to eq(second_list)
      end

      it "skips a list a crashed worker's save already holds" do
        path = queue_list(first_list)
        claimed = Samagotchi::SessionInbox.claim_note_file(path)
        session.messages = [Samagotchi::ContextNote.message(**Samagotchi::SessionInbox.read_note(claimed))]

        inbound.absorb_notes

        expect(session.messages.count { |m| m[:objectives] }).to eq(1)
      end
    end

    it "keeps the claimed files when the save fails" do
      failing_save
      inbound.absorb_notes

      expect(Samagotchi::SessionInbox.find_new_note_files(session_dir).map { |f| File.extname(f) }).to eq([".processing"])
    end

    describe "a note left in the link this one continues" do
      let(:previous) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir, now: Time.now - 60)
                           .tap { |s| s.save(state_dir: tmpdir) }
      end
      let(:session) do
        Samagotchi::ArchiveStore.archive(previous.id, state_dir: tmpdir)
        Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir, continues: previous.id)
                           .tap { |s| s.save(state_dir: tmpdir) }
      end

      it "is adopted on the next pass, once the link exists (a straggler, an older chi's writer)" do
        inbound.absorb_notes
        Samagotchi::SessionInbox.write_note(previous.id, text: "straggler", state_dir: tmpdir)

        inbound.absorb_notes

        expect(saved.messages.map { |m| Samagotchi::ContextNote.text_of(m) }).to include("the build is red", "straggler")
        expect(Samagotchi::SessionInbox.find_new_note_files(Samagotchi::Session.session_dir(previous.id, state_dir: tmpdir))).to be_empty
      end
    end

    it "leaves the notes queued in a stopped session" do
      stopped[0] = true
      inbound.absorb_notes

      expect(session.messages).to be_empty
      expect(Samagotchi::SessionInbox.find_new_note_files(session_dir).size).to eq(1)
    end
  end

  describe "the objectives lock" do
    it "holds it from the claim to the files' delete, so an edit can't read between them" do
      list = Samagotchi::Objectives::List.new.set([{ text: "A" }])
      Samagotchi::SessionInbox.write_note(session.id, text: list.text, source: "objectives", objectives: list.to_payload, state_dir: tmpdir)
      locked = nil
      allow(engine).to receive(:add_context_note).and_wrap_original do |original, *args|
        File.open(File.join(session_dir, Samagotchi::Objectives::LOCK_FILE)) { |f| locked = !f.flock(File::LOCK_EX | File::LOCK_NB) }
        original.call(*args)
      end
      inbound.absorb_notes
      expect(locked).to be(true)
    end
  end

  describe "a participant's /objectives" do
    it "is refused like any command: no turn, nothing queued, no note file" do
      allow(engine).to receive(:command_registry).and_return(Samagotchi::SessionCommands.builtin_registry)
      allow(Samagotchi::Participants).to receive(:log)
      input = Samagotchi::SessionInbox.write_input(session_dir, prompt: "/objectives set Mine now", author: "p:abc")

      expect { |turn| inbound.take_input(input, &turn) }.not_to yield_control

      expect(queued).to be_empty
      expect(Samagotchi::SessionInbox.find_new_note_files(session_dir)).to be_empty
      expect(Samagotchi::Participants).to have_received(:log).with(session.id, :refused, hash_including(what: "command"))
    end
  end

  describe "#take_initial_prompt and #initial_command?" do
    it "takes the first prompt once and saves it cleared" do
      session.last_prompt = "count the specs"
      session.save(state_dir: tmpdir)

      expect(inbound.take_initial_prompt).to eq("count the specs")
      expect(saved.last_prompt).to eq("")
      expect(inbound.take_initial_prompt).to be_nil
    end

    it "takes none from a session with a conversation" do
      session.last_prompt = "an old turn"
      session.messages = [{ role: "user", content: "an old turn" }]

      expect(inbound.take_initial_prompt).to be_nil
    end

    it "queues a first prompt that is a command and saves the session idle, unless it was stopped" do
      session.status = Samagotchi::Session::STATUS_RUNNING
      expect(inbound.initial_command?("/model x")).to be(true)
      expect(queued).to eq([["/model x", Samagotchi::ClientId::FIRST_PROMPT, nil]])
      expect(saved.status).to eq(Samagotchi::Session::STATUS_IDLE)

      expect(inbound.initial_command?("hello")).to be(false)

      stopped[0] = true
      expect(session).not_to receive(:save)
      inbound.initial_command?("/model y")
    end
  end

  describe "#initial_origin" do
    it "is the first prompt's turn id and sender; a first command from a delegate is its, a /word its text" do
      session.first_turn_id = "first-1"
      session.first_turn_client_id = "delegate:1234abcd"

      expect(inbound.initial_origin).to eq(Samagotchi::TurnOrigin.new(client_id: "delegate:1234abcd", enqueued_id: "first-1"))
      expect(inbound.initial_command?("/model x")).to be(false)
      expect(inbound.initial_command?("!touch x")).to be(true)
      expect(queued).to eq([["!touch x", "delegate:1234abcd", "first-1"]])
    end

    it "names the owner's first prompt for a session created by a person, or before the field; its /word runs" do
      session.first_turn_id = "first-1"
      expect(inbound.initial_origin).to eq(Samagotchi::TurnOrigin.new(client_id: Samagotchi::ClientId::FIRST_PROMPT,
                                                                      enqueued_id: "first-1"))
      expect(inbound.initial_command?("/model x")).to be(true)
      expect(queued).to eq([["/model x", Samagotchi::ClientId::FIRST_PROMPT, "first-1"]])
    end

    it "names the parent for a delegate child's task without the field (an older chi spawned it)" do
      session.parent_id = "0123abcd-ffff-4fff-8fff-ffffffffffff"
      session.delegate = true
      session.first_turn_id = "first-1"

      expect(inbound.initial_origin).to eq(Samagotchi::TurnOrigin.new(client_id: "delegate:0123abcd", enqueued_id: "first-1"))
      expect(inbound.initial_command?("!touch x")).to be(true)
      expect(queued).to eq([["!touch x", "delegate:0123abcd", "first-1"]])
    end
  end

  describe "#take_input" do
    def write(prompt, **opts) = Samagotchi::SessionInbox.write_input(session_dir, prompt: prompt, **opts)

    it "yields the file's Prompt and deletes the claimed file after the block" do
      file = write("hello", client_id: "web:1", no_interrupt: true, images: [{ file: "a.png", name: "a" }])
      seen = nil
      inbound.take_input(file) { |prompt| seen = [prompt, File.exist?("#{file}.processing")] }

      expect(seen).to eq([described_class::Prompt.new(text: "hello", origin: { client_id: "web:1" }, no_interrupt: true,
                                                      images: [{ file: "a.png", name: "a" }]), true])
      expect(File.exist?("#{file}.processing")).to be(false)
    end

    it "carries the file's delivery, nil for a step-boundary one" do
      seen = []
      inbound.take_input(write("queued up", delivery: "queue")) { |p| seen << p.delivery }
      inbound.take_input(write("goes in at the next step")) { |p| seen << p.delivery }
      inbound.take_input(write("cut it", delivery: "cut")) { |p| seen << p.delivery }

      expect(seen).to eq(["queue", nil, nil])
    end

    it "queues a command without images, and yields nothing for it or an empty line" do
      yielded = []
      inbound.take_input(write("/model x", client_id: "web:1", enqueued_id: "e1")) { |p| yielded << p }
      inbound.take_input(write("  ")) { |p| yielded << p }
      inbound.take_input(write("/model y", images: [{ file: "b.png", name: "b" }])) { |p| yielded << p.text }

      expect(queued).to eq([["/model x", "web:1", "e1"]])
      expect(yielded).to eq(["/model y"])
      expect(Samagotchi::SessionInbox.find_new_input_files(session_dir)).to be_empty
    end

    # Only a person's (and chi answer's) line runs as a command: from a
    # delegate, a schedule or a plugin a /word is the model's text, and a
    # shell line is queued for the worker to refuse (Worker#run_command_line).
    it "yields a /word from a sender that may not send commands as a prompt, and queues its shell line to be refused" do
      yielded = []
      %w[delegate:1234abcd system:schedule:abc plugin].each do |client_id|
        inbound.take_input(write("/model x", client_id: client_id)) { |p| yielded << [p.text, p.origin.client_id] }
      end
      inbound.take_input(write("!touch x", client_id: "delegate:1234abcd", enqueued_id: "e2")) { |p| yielded << p.text }
      inbound.take_input(write("/model y", client_id: "cli:answer", enqueued_id: "e3")) { |p| yielded << p.text }

      expect(yielded).to eq([["/model x", "delegate:1234abcd"], ["/model x", "system:schedule:abc"], ["/model x", "plugin"]])
      expect(queued).to eq([["!touch x", "delegate:1234abcd", "e2"], ["/model y", "cli:answer", "e3"]])
    end

    it "yields nothing for a file another reader claimed" do
      expect { |b| inbound.take_input(File.join(session_dir, "input", "gone.json"), &b) }.not_to yield_control
    end

    it "consumes a repeated enqueued id without yielding another turn" do
      id = "e1"
      first = write("first", enqueued_id: id, now: Time.at(1))
      duplicate = write("duplicate", enqueued_id: id, now: Time.at(2))
      yielded = []

      expect(Samagotchi::Log).to receive(:info).with(:worker, "duplicate_input_dropped", enqueued_id: id)
      inbound.take_input(first) { |prompt| yielded << prompt.text }
      inbound.take_input(duplicate) { |prompt| yielded << prompt.text }

      expect(yielded).to eq(["first"])
      expect(Samagotchi::SessionInbox.find_new_input_files(session_dir)).to be_empty
    end

    it "drops a fallback file already run by a previous worker" do
      id = "e1"
      session.last_turn = Samagotchi::LastTurn.new(enqueued_id: id)
      session.save(state_dir: tmpdir)
      restarted = described_class.new(
        session: Samagotchi::Session.load(session.id, state_dir: tmpdir), state_dir: tmpdir, session_dir: session_dir,
        engine: fake_engine.new(session), context_absorber: absorber, wakes: wakes,
        awaiting_continue: -> { awaiting[0] }, stopped: -> { stopped[0] }, queue_command: ->(*) {}
      )
      fallback = write("already ran", enqueued_id: id)
      yielded = []

      expect(Samagotchi::Log).to receive(:info).with(:worker, "duplicate_input_dropped", enqueued_id: id)
      restarted.take_input(fallback) { |prompt| yielded << prompt.text }

      expect(yielded).to be_empty
      expect(Samagotchi::SessionInbox.find_new_input_files(session_dir)).to be_empty
    end

    it "drops a fallback file whose interrupted turn was settled by the previous worker" do
      id = "e1"
      session.status = Samagotchi::Session::STATUS_RUNNING
      session.interrupted_turn = {
        "id" => "t1", "started_at" => Time.now.iso8601(3), "iteration" => 1, "enqueued_id" => id
      }
      session.save(state_dir: tmpdir)

      restarted_session = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      Samagotchi::TurnCheckpoint.settle(restarted_session, session_dir: session_dir)
      restarted_session.save(state_dir: tmpdir)
      restarted = described_class.new(
        session: restarted_session, state_dir: tmpdir, session_dir: session_dir, engine: fake_engine.new(restarted_session),
        context_absorber: absorber, wakes: wakes, awaiting_continue: -> { awaiting[0] }, stopped: -> { stopped[0] },
        queue_command: ->(*) {}
      )
      fallback = write("already interrupted", enqueued_id: id)
      yielded = []

      expect(Samagotchi::TurnCheckpoint.settled_turn(session_dir, id))
        .to have_attributes(outcome: "canceled", cancel_reason: "worker_stopped")
      expect(Samagotchi::Log).to receive(:info).with(:worker, "duplicate_input_dropped", enqueued_id: id)
      restarted.take_input(fallback) { |prompt| yielded << prompt.text }

      expect(yielded).to be_empty
      expect(Samagotchi::SessionInbox.find_new_input_files(session_dir)).to be_empty
    end
  end

  describe "#absorb_context" do
    let(:subscription) { Samagotchi::ContextSources::Subscription.blank("ci") }
    let(:note) { { note_id: "ctx-ci-1", text: "ci changed", source: "context" } }
    let(:delivery) do
      Samagotchi::ContextAbsorber::Delivery.new(name: "ci", note: note, subscription: subscription,
                                                wake_note: note.merge(text: "ci changed; wake"))
    end
    let(:batch) { Samagotchi::ContextAbsorber::Batch.new(deliveries: [delivery], signature: "sig") }

    before do
      allow(absorber).to receive(:pending).and_return(batch)
      session.messages = [{ role: "user", content: "hi" }]
    end

    it "takes nothing into a session with no turn yet, unless a turn is about to run" do
      session.messages = []
      expect(inbound.absorb_context).to be_nil
      expect(absorber).not_to have_received(:pending)

      inbound.absorb_context(before_turn: true)
      expect(session.messages.size).to eq(1)
    end

    it "adds the notes as plain ones, saves, then commits the batch" do
      expect(inbound.absorb_context).to be_nil
      expect(saved.messages.last[:note_id]).to eq("ctx-ci-1")
      expect(absorber).to have_received(:commit).with(batch)
    end

    it "commits nothing when the save fails" do
      failing_save
      expect(inbound.absorb_context).to be_nil
      expect(absorber).not_to have_received(:commit)
    end

    it "returns the ContextWake when the source may wake the session, its note the turn's start, the wake stamped" do
      wake = inbound.absorb_context(wake: true)

      expect(wake.name).to eq("ci")
      expect(wake.origin).to eq(Samagotchi::TurnOrigin.new(client_id: "context:ci"))
      expect(session.messages.last).to include(turn_start: true, turn_id: wake.turn_id)
      expect(absorber).to have_received(:commit) do |committed|
        expect(committed.deliveries.first.subscription.wakes_at).not_to be_nil
      end
    end

    it "keeps a wake batch uncommitted through start grace, then wakes it" do
      now = [0]
      grace_wakes = Samagotchi::WorkerWakes.new(grace: 2, clock: -> { now[0] }, max: -> { 10 })
      grace_inbound = described_class.new(session: session, state_dir: tmpdir, session_dir: session_dir, engine: engine,
                                          context_absorber: absorber, wakes: grace_wakes,
                                          awaiting_continue: -> { awaiting[0] }, stopped: -> { stopped[0] },
                                          queue_command: ->(*) {})
      allow(Samagotchi::Config).to receive(:get).with("context.wake").and_return(true)

      expect(grace_inbound.absorb_context(wake: true)).to be_nil
      expect(grace_inbound.context_wake_waiting?).to be(true)
      expect(session.messages.map { |message| message[:note_id] }).not_to include("ctx-ci-1")
      expect(absorber).not_to have_received(:commit)

      now[0] = 3
      expect(grace_inbound.absorb_context(wake: true)).to have_attributes(name: "ci")
      expect(grace_inbound.context_wake_waiting?).to be(false)
      expect(absorber).to have_received(:commit).once
    end

    it "does not defer a wake held by a continue offer" do
      awaiting[0] = true

      expect(inbound.context_wake_waiting?).to be(false)
      expect(inbound.absorb_context(wake: true)).to be_nil
      expect(absorber).to have_received(:commit).with(batch)
      expect(session.messages.last).not_to have_key(:turn_start)
    end

    it "wakes nothing while the wake budget is closed or the source woke lately" do
      awaiting[0] = true
      expect(inbound.absorb_context(wake: true)).to be_nil

      awaiting[0] = false
      lately = delivery.with(subscription: subscription.with(wakes_at: Time.now.iso8601))
      allow(absorber).to receive(:pending).and_return(batch.with(deliveries: [lately]))
      expect(inbound.absorb_context(wake: true)).to be_nil
    end

    it "puts a failed wake's note back as a plain one" do
      wake = inbound.absorb_context(wake: true)
      inbound.unmark_wake(wake)

      expect(engine.rolled_back.last).to eq(Samagotchi::ContextNote.message(**note))
    end

    describe "a peer's answer" do
      let(:wakes) { Samagotchi::WorkerWakes.new(grace: 0, max: -> { max[0] }, peer_max: -> { 2 }) }
      let(:max) { [10] }
      let(:announced) { engine.announced }
      let(:peer_note) { { note_id: "ctx-codex-outbox-1", text: "Codex answered", source: "context" } }
      let(:peer) do
        Samagotchi::ContextAbsorber::Delivery.new(name: "codex-outbox", note: peer_note, peer: "Codex",
                                                  subscription: Samagotchi::ContextSources::Subscription.blank("codex-outbox")
                                                                .with(wakes_at: Time.now.iso8601),
                                                  wake_note: peer_note.merge(text: "Codex answered; peer line"))
      end

      before do
        allow(absorber).to receive(:pending).and_return(batch.with(deliveries: [peer]))
      end

      it "wakes past the 10-minute window, while the peer budget lasts; then a note and one notice" do
        2.times do
          wake = inbound.absorb_context(wake: true)
          expect(wake).to have_attributes(name: "codex-outbox", peer?: true)
          wakes.count!(peer: wake.peer?)
        end

        expect(inbound.absorb_context(wake: true)).to be_nil
        expect(inbound.absorb_context(wake: true)).to be_nil
        expect(announced).to eq([{ type: :hook_notice, hook: "context", level: :info, between_turns: true,
                                   text: "Codex answered again; it waits as a note for your next message " \
                                         "(2 wake turns in a row, context.peer_turns)" }])
      end

      it "is held by session.max_wakes too, and says so" do
        max[0] = 1
        wakes.count!

        expect(inbound.absorb_context(wake: true)).to be_nil
        expect(announced.map { |e| e[:text] })
          .to eq(["Codex answered again; it waits as a note for your next message (1 wake turn in a row, session.max_wakes)"])
      end

      it "doesn't take a non-peer's 10-minute window; in a mixed batch a held peer is a note and the other wakes" do
        2.times { wakes.count!(peer: true) }
        other = delivery
        allow(absorber).to receive(:pending).and_return(batch.with(deliveries: [peer, other]))

        expect(inbound.absorb_context(wake: true)).to have_attributes(name: "ci", peer?: false)
        expect(announced.size).to eq(1)
      end
    end
  end
end
