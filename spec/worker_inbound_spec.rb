# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

require "samagotchi/worker_inbound"
require "samagotchi/worker_wakes"
require "samagotchi/context_absorber"
require "samagotchi/context_sources"

# What comes into a worker's session between turns and how each kind is
# saved; the turns they start are the Worker's (worker_*_spec).
RSpec.describe Samagotchi::WorkerInbound do
  # The Engine's part: notes into the conversation, the command check, a
  # rollback.
  let(:fake_engine) do
    Class.new do
      attr_reader :rolled_back

      def initialize(session) = @session = session
      def command_registry = self
      def command?(text) = text.start_with?("/model")
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
                        stopped: -> { stopped[0] }, queue_command: ->(line, client_id, _after_file) { queued << [line, client_id] })
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

    it "keeps the claimed files when the save fails" do
      failing_save
      inbound.absorb_notes

      expect(Samagotchi::SessionInbox.find_new_note_files(session_dir).map { |f| File.extname(f) }).to eq([".processing"])
    end

    it "leaves the notes queued in a stopped session" do
      stopped[0] = true
      inbound.absorb_notes

      expect(session.messages).to be_empty
      expect(Samagotchi::SessionInbox.find_new_note_files(session_dir).size).to eq(1)
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
      expect(queued).to eq([["/model x", nil]])
      expect(saved.status).to eq(Samagotchi::Session::STATUS_IDLE)

      expect(inbound.initial_command?("hello")).to be(false)

      stopped[0] = true
      expect(session).not_to receive(:save)
      inbound.initial_command?("/model y")
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

    it "queues a command without images, and yields nothing for it or an empty line" do
      yielded = []
      inbound.take_input(write("/model x", client_id: "web:1")) { |p| yielded << p }
      inbound.take_input(write("  ")) { |p| yielded << p }
      inbound.take_input(write("/model y", images: [{ file: "b.png", name: "b" }])) { |p| yielded << p.text }

      expect(queued).to eq([["/model x", "web:1"]])
      expect(yielded).to eq(["/model y"])
      expect(Samagotchi::SessionInbox.find_new_input_files(session_dir)).to be_empty
    end

    it "yields nothing for a file another reader claimed" do
      expect { |b| inbound.take_input(File.join(session_dir, "input", "gone.json"), &b) }.not_to yield_control
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
      expect(wake.origin).to eq({ client_id: "context:ci" })
      expect(session.messages.last).to include(turn_start: true, turn_id: wake.turn_id)
      expect(absorber).to have_received(:commit) do |committed|
        expect(committed.deliveries.first.subscription.wakes_at).not_to be_nil
      end
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
  end
end
