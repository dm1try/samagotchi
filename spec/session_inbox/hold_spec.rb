# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "spec_helper"
require "samagotchi/session_inbox"
require "samagotchi/session_manager"
require "samagotchi/client_id"
require_relative "../support/transition_holder"

# Arrivals declare their hold (WakePolicy#hold), taken once in each seat:
# SessionInbox::Dispatch.deliver / .wake and SessionManager.deliver_turn.
# The lock is held for real, on another thread (TransitionHolder), never on
# the spec's own (a thread's own hold passes its shared ones through).
RSpec.describe "the seats' transition hold" do
  include TransitionHolder

  let(:tmpdir) { Dir.mktmpdir("inbox-hold") }
  let(:session) { make }
  let(:starts) { [] }
  let(:start) { ->(id) { (starts << id) && :woken } }
  let(:manager) { Samagotchi::SessionManager }

  after { FileUtils.rm_rf(tmpdir) }

  def make
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap do |s|
      s.save(state_dir: tmpdir)
    end
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: tmpdir)
  def inputs(id) = Samagotchi::SessionInbox.find_new_input_files(dir_of(id))

  def deliver(kind, id = session.id)
    written = []
    result = Samagotchi::SessionInbox.deliver(kind, id, state_dir: tmpdir, owner: ->(_) {}, start: start) do |at|
      (written << at) && true
    end
    [result, written]
  end

  def send_turn(id = session.id, client_id: "cli:send", follow: false)
    manager.deliver_turn(id, prompt: "hi", client_id: client_id, follow: follow, state_dir: tmpdir, bridge: -> {})
  end

  describe "SessionInbox.deliver" do
    it "refuses a shared row's delivery busy while a transition holds the lock, nothing written, nothing started" do
      holding_transition(session.id, state_dir: tmpdir) do
        %i[push peer].each do |kind|
          result, written = deliver(kind)

          expect(result).to have_attributes(kind: kind, status: :refused, wake: :busy), kind.to_s
          expect(written).to be_empty
        end
      end
      expect(starts).to be_empty
    end

    it "names a continue's new link (:continued) when the holder is one" do
      holding_transition(session.id, state_dir: tmpdir, successor: SecureRandom.uuid) do
        result, written = deliver(:push)

        expect(result).to have_attributes(status: :refused, wake: :continued)
        expect(written).to be_empty
      end
    end

    it "lets a :none row's delivery in as before: a note, a ring, a fresh verdict" do
      holding_transition(session.id, state_dir: tmpdir) do
        %i[note ring fresh_verdict].each do |kind|
          result, written = deliver(kind)

          expect(result.refused?).to be(false), kind.to_s
          expect(written).to eq([session.id])
        end
      end
    end

    it "wakes for a ring under a held lock (a :none row: a continue's undo wakes on its own token)" do
      holding_transition(session.id, state_dir: tmpdir) do
        result = Samagotchi::SessionInbox.wake(:ring, session.id, state_dir: tmpdir, owner: ->(_) {}, start: start)

        expect(result).to have_attributes(status: :queued, wake: :woken)
      end
    end

    it "goes in once the transition let go" do
      holding_transition(session.id, state_dir: tmpdir) { deliver(:push) }

      result, written = deliver(:push)
      expect(result.refused?).to be(false)
      expect(written).to eq([session.id])
    end
  end

  describe "SessionManager.deliver_turn" do
    senders = { send: "cli:send", schedule: Samagotchi::ClientId.schedule("s1"),
                plugin: Samagotchi::ClientId::PLUGIN, delegate: Samagotchi::ClientId.delegate("abcd1234"),
                participant: Samagotchi::ClientId.participant("p_1"), agent: Samagotchi::ClientId.agent("claude") }

    it "refuses every sender's turn busy while a transition holds the lock, nothing written" do
      holding_transition(session.id, state_dir: tmpdir) do
        senders.each do |kind, client_id|
          expect(Samagotchi::ClientId.wake_kind(client_id)).to eq(kind)
          result = send_turn(client_id: client_id)

          expect(result).to have_attributes(status: :refused, code: 409), kind.to_s
          expect(result).to be_busy
          expect(result.detail).to eq("session #{session.id[0, 8]} is busy with another change; try again in a moment")
          expect(result.refusal_text).to start_with("refused: ")
        end
      end
      expect(inputs(session.id)).to be_empty
    end

    # The send Phase 3 left open: between the continue's EX and its archive
    # marker the link is not archived yet, and follow_guard didn't look.
    it "refuses a send to a link not archived yet while its continue holds the lock, naming the new link" do
      successor = SecureRandom.uuid
      holding_transition(session.id, state_dir: tmpdir, successor: successor) do
        result = send_turn(client_id: "web:tab")

        expect(result).to be_continued
        expect(result.ack).to include("successor_id" => successor, "session_id" => session.id)
        expect(result.detail).to eq("session #{session.id[0, 8]} is being continued as #{successor}; send again in a moment")
      end
      expect(inputs(session.id)).to be_empty
      expect(Samagotchi::ArchiveStore.archived?(dir_of(session.id))).to be(false)
    end

    # Busy's words name the holder (Busy.held): a delete holding the lock
    # is "being deleted", and a saved link after it (the next link of a
    # middle one being pruned) is not offered as where to send instead.
    it "refuses a turn and a push while a delete holds the lock as being deleted, naming no successor" do
      following = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w")
      following.continues = session.id
      following.save(state_dir: tmpdir)
      Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir)

      holding_transition(session.id, state_dir: tmpdir, kind: :delete) do
        result = send_turn(follow: true)

        expect(result).to be_busy
        expect(result.ack).not_to include("successor_id")
        expect(result.detail).to eq("session #{session.id[0, 8]} is being deleted; try again in a moment")
        expect(deliver(:push).first).to have_attributes(status: :refused, wake: :busy)
      end
      expect(inputs(session.id)).to be_empty
    end

    it "refuses a push while a stop holds the lock over a crashed continue's intent as being stopped, naming no successor" do
      successor = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w")
      successor.save(state_dir: tmpdir)
      FileUtils.mkdir_p(dir_of(session.id))
      Samagotchi::ContinueIntent.write(File.join(dir_of(session.id), Samagotchi::ContinueIntent::FILE),
                                       successor_id: successor.id, previously_archived: [])

      holding_transition(session.id, state_dir: tmpdir, kind: :stop) do
        result = send_turn

        expect(result).to be_busy
        expect(result.ack).not_to include("successor_id")
        expect(result.detail).to eq("session #{session.id[0, 8]} is being stopped; try again in a moment")
        expect(deliver(:push).first).to have_attributes(status: :refused, wake: :busy)
      end
      expect(inputs(session.id)).to be_empty
    end

    it "makes no folder for a session that is gone" do
      gone = SecureRandom.uuid

      expect { send_turn(gone) }.to raise_error(Samagotchi::Session::NotFound)
      expect(Dir.exist?(dir_of(gone))).to be(false)
    end
  end
end
