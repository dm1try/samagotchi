# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/worker_boot"
require "samagotchi/worker"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

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
      instance_double(Samagotchi::Engine, announce_participants: nil, command_registry: Samagotchi::SessionCommandCatalog.builtin_registry, peer_sources: nil, "running_turn_messages=": nil, shutdown: nil, announce_load_events!: nil, start_init_tasks!: nil, warm_toolkit_suggestion!: nil, "interface=": nil, "participant_stop=": nil, recap: nil, "recap_awaiting_continue=": nil, "guardrail_state_dir=": nil, "session_state_dir=": nil, "next_turn_waiting=": nil, due_reminder_names: [], "session=": nil, start_idle: nil, stop_idle: nil,
                                          reminder_store: reminders, turn_running?: false, last_activity_at: 0.0,
                                          messages_checkpoint: [], used_memory_names: [], write_recap_now: nil, recap_timeout: nil)
    end

    before do
      allow(engine).to receive(:subscribe).and_return(double("subscribe_handle", unsubscribe: nil))
      allow(engine).to receive(:synchronize_events).and_yield
      allow(engine).to receive(:claim_enqueued_id).and_return(true)
      allow(engine).to receive(:finish_enqueued_id)
      allow(Samagotchi::Engine).to receive(:new).and_return(engine)
    end

    def run_worker
      Samagotchi::WorkerBoot.run_session_loop(session.id, state_dir: tmpdir, idle_exit_minutes: 0.002, poll_interval: 0.01)
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

    it "marks its owner lock leaving, with the recap's timeout, before the recap on leave" do
      session.messages << { role: "user", content: "hi" }
      session.save(state_dir: tmpdir)
      allow(engine).to receive(:recap_timeout).and_return(12.0)
      owner_at_recap = nil
      allow(engine).to receive(:write_recap_now) { owner_at_recap = Samagotchi::OwnerLock.owner(session_dir) }

      expect(run_worker).to eq(:idle_exit)

      expect(owner_at_recap).to have_attributes(leaving?: true, leave_wait: 12.0)
      expect(Samagotchi::OwnerLock.owner(session_dir)).to be_nil
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
        described_class.write_turn_input(session.id, client_id: nil, prompt: "late", state_dir: tmpdir) if calls == 1
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
        described_class.write_turn_input(session.id, client_id: nil, prompt: "late", state_dir: tmpdir)
      end
      allow(Process).to receive(:spawn).and_return(40_004)

      expect(run_worker).to eq(:idle_exit)

      expect(Process).to have_received(:spawn)
      expect(input_files.size).to eq(1)
    end

    it "wakes a new worker for input queued as it left on a client's request too" do
      allow_any_instance_of(Samagotchi::Worker).to receive(:run) do
        described_class.write_turn_input(session.id, client_id: nil, prompt: "late", state_dir: tmpdir)
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
end
