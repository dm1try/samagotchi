# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/session_manager"
require "samagotchi/session_chain"
require "samagotchi/tools/delegate_cursor"

# SessionManager.continue_session: the next link of a session chain.
RSpec.describe Samagotchi::SessionManager, ".continue_session" do
  let(:tmpdir) { Dir.mktmpdir("continue-spec") }
  let(:folder) { Dir.mktmpdir("continue-folder") }
  let(:locks) { [] }

  before { allow(Process).to receive(:spawn).and_return(12_345) }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
    FileUtils.rm_rf(folder)
  end

  def make(prompt: "you are coordinator again", parent_id: nil, delegate: false, status: nil, created: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: folder,
                                    parent_id: parent_id, delegate: delegate).tap do |s|
      s.first_preview = prompt
      s.messages = [{ role: "user", content: prompt }, { role: "assistant", content: "ok" }]
      s.status = status if status
      s.created_at = created if created
      s.save(state_dir: tmpdir)
    end
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: tmpdir)
  def archived?(id) = Samagotchi::ArchiveStore.archived?(dir_of(id))
  def own(id) = locks << Samagotchi::OwnerLock.acquire(dir_of(id), kind: "worker")
  def load(id) = Samagotchi::Session.load(id, state_dir: tmpdir)

  def save_recap(id, text, at: "2026-10-08T17:30:00Z")
    FileUtils.mkdir_p(dir_of(id))
    File.write(File.join(dir_of(id), Samagotchi::RecapStore::FILE), JSON.generate(text: text, created_at: at))
  end

  # The one context note queued for the session.
  def note_of(id)
    notes = Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| Samagotchi::SessionInbox.read_note(f) }
    expect(notes.size).to eq(1)
    notes.first
  end

  def continue(ref, **)
    described_class.continue_session(ref, state_dir: tmpdir, recap_wait: 0, **)
  end

  it "starts the next link in the previous one's folder, model (as typed) and llm_context, and archives the previous one" do
    previous = make(created: "2026-10-08T09:00:00+02:00")
    previous.model_typed = "small"
    previous.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:stale], budget_tokens: 64_000)
    previous.save(state_dir: tmpdir)
    save_recap(previous.id, "The user reviewed three PRs and merged two.")
    allow(Samagotchi::ConfigFile).to receive(:model_ref).and_call_original
    allow(Samagotchi::ConfigFile).to receive(:model_ref).with("small")
                                                         .and_return(Samagotchi::ConfigFile.model_ref("main:gemma-small"))

    link = continue(previous.id)

    saved = load(link.id)
    expect(saved).to have_attributes(continues: previous.id, working_directory: folder, model_name: "main:gemma-small",
                                     model_typed: "small", status: Samagotchi::Session::STATUS_IDLE,
                                     first_preview: "you are coordinator again")
    expect(saved.llm_context).to eq(previous.llm_context)
    expect(archived?(previous.id)).to be(true)
    # Not a descendant: the archive's cascade never reaches the new link.
    expect(archived?(link.id)).to be(false)
    expect(Process).to have_received(:spawn).once

    note = note_of(link.id)
    expect(note[:source]).to eq("session chain")
    as_of = Time.iso8601("2026-10-08T17:30:00Z").localtime.strftime("%Y-%m-%d %H:%M")
    expect(note[:text]).to eq("This session continues #{previous.id[0, 8]} (2026-10-08), the previous link of its chain. " \
                              "Its recap, as of #{as_of}:\nThe user reviewed three PRs and merged two.")
  end

  it "carries only the link when the previous one has no recap, and runs a first message it was given" do
    previous = make

    link = continue(previous.id, prompt: "start the day")

    expect(note_of(link.id)[:text]).to end_with("the previous link of its chain. It left no recap.")
    expect(load(link.id)).to have_attributes(last_prompt: "start the day", first_preview: "start the day",
                                             status: Samagotchi::Session::STATUS_RUNNING)
  end

  it "asks the previous link's live worker for a recap and carries the one it writes" do
    previous = make
    save_recap(previous.id, "The old recap.")
    client = instance_double(Samagotchi::BridgeClient)
    allow(described_class).to receive(:worker_live?).and_call_original
    allow(described_class).to receive(:worker_live?).with(previous.id, state_dir: tmpdir).and_return(true)
    allow(Samagotchi::BridgeClient).to receive(:discover).and_return(client)
    allow(client).to receive(:request_recap) do
      Thread.new do
        sleep 0.3
        save_recap(previous.id, "The fresh recap.", at: "2026-10-09T18:00:00Z")
      end
      Samagotchi::BridgeClient::Response.new(status: 200, body: JSON.generate(enabled: true, request: "started"))
    end

    link = continue(previous.id, recap_wait: 5)

    expect(note_of(link.id)[:text]).to end_with(":\nThe fresh recap.")
  end

  it "archives the previous link's finished delegates with it" do
    previous = make
    child = make(prompt: "count the specs", parent_id: previous.id, delegate: true)
    Samagotchi::SessionInbox.write_output(dir_of(child.id), "42 specs")
    reply = Dir.children(File.join(dir_of(child.id), "output")).first
    Samagotchi::Tools::DelegateCursors.update(previous.id, child.id, state_dir: tmpdir) { |c| c.with(reply_file: reply) }

    link = continue(previous.id)

    expect([previous.id, child.id].map { |id| archived?(id) }).to eq([true, true])
    expect(archived?(link.id)).to be(false)
  end

  describe "moving the open delegates to the new link" do
    def cursors(id) = Samagotchi::Tools::DelegateCursors.read(id, state_dir: tmpdir)
    def rings(id) = Samagotchi::SessionInbox.find_ring_files(dir_of(id))
    def ring_ids(id) = rings(id).map { |f| Samagotchi::SessionInbox.read_ring(f)[:child_id] }

    def started(parent, child)
      Samagotchi::Tools::DelegateWait.mark_started(parent.id, child, state_dir: tmpdir)
    end

    # A child's notes, by source.
    def notes_of(id)
      Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| Samagotchi::SessionInbox.read_note(f) }
    end

    it "moves running, live and unreported delegates and an open grandchild's delegate; archives the finished one" do
      previous = make
      running = make(prompt: "a", parent_id: previous.id, delegate: true, status: Samagotchi::Session::STATUS_RUNNING)
      own(running.id)
      live = make(prompt: "b", parent_id: previous.id, delegate: true)
      own(live.id)
      unreported = make(prompt: "c", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(unreported.id), "done")
      middle = make(prompt: "d", parent_id: previous.id, delegate: true)
      grandchild = make(prompt: "e", parent_id: middle.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(grandchild.id), "done")
      finished = make(prompt: "f", parent_id: previous.id, delegate: true)
      [running, live, unreported, finished].each { |c| started(previous, c) }
      Samagotchi::SessionInbox.write_ring(dir_of(previous.id), child_id: unreported.id, why: "turn_end")
      moved = [running, live, unreported, middle].map(&:id)

      link = continue(previous.id)

      expect(link.moved_children).to match_array(moved)
      expect(described_class.children_of(link.id, state_dir: tmpdir).map { |r| r[:id] }).to match_array(moved)
      moved.each do |id|
        expect(Samagotchi::Session.parent_override(id, state_dir: tmpdir)).to eq(link.id)
        expect(archived?(id)).to be(false)
        expect(notes_of(id).map { |n| n[:text] }).to eq(["Your parent session is now #{link.id[0, 8]} (#{link.id}), " \
                                                          "the next link of its session chain: send notes there, " \
                                                          "and your reports reach it."])
      end
      expect(load(grandchild.id).parent_id).to eq(middle.id)
      expect(archived?(grandchild.id)).to be(false)
      expect([archived?(previous.id), archived?(finished.id)]).to eq([true, true])
      expect(load(finished.id).parent_id).to eq(previous.id)
      # Cursors copied (the previous link keeps its own), rings moved.
      expect(cursors(link.id).keys).to match_array([running, live, unreported].map(&:id))
      expect(cursors(previous.id).keys).to include(finished.id, unreported.id)
      expect(ring_ids(link.id)).to eq([unreported.id])
      expect(rings(previous.id)).to be_empty
      # The move is done: no intent. The starting marker stays until the
      # spawned worker holds the link (Worker#start clears it).
      expect(Samagotchi::ChildMove.read_intent(link.id, state_dir: tmpdir)).to be_nil
      expect(Samagotchi::ChildMove.starting?(link.id, state_dir: tmpdir)).to be(true)
      expect(Process).to have_received(:spawn).once
      expect(Samagotchi::ChildrenStatus.counts(link.id, state_dir: tmpdir))
        .to have_attributes(running: 1, unreported: 1)
    end

    it "lists a moved child under the new link even after its live worker saves its stale copy" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      own(child.id)
      held = load(child.id)

      link = continue(previous.id)
      held.save(state_dir: tmpdir)

      expect(JSON.parse(File.read(File.join(tmpdir, "#{child.id}.json")))["parent_id"]).to eq(previous.id)
      expect(Samagotchi::Session.list(state_dir: tmpdir).find { |s| s.id == child.id }.parent_id).to eq(link.id)
      expect(described_class.children_of(link.id, state_dir: tmpdir).map { |r| r[:id] }).to eq([child.id])
      expect(described_class.children_of(previous.id, state_dir: tmpdir)).to be_empty
    end

    it "moves a delegate started during the recap wait too" do
      previous = make
      late = nil
      allow(described_class).to receive(:recap_before_archive) do
        late = make(prompt: "late", parent_id: previous.id, delegate: true)
        Samagotchi::SessionInbox.write_output(dir_of(late.id), "done")
      end

      link = continue(previous.id)

      expect(link.moved_children).to eq([late.id])
      expect(load(late.id).parent_id).to eq(link.id)
      expect(archived?(late.id)).to be(false)
    end

    it "takes a ring a moved child writes between its override and the spawn once, and spawns one worker" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      started(previous, child)
      Samagotchi::SessionInbox.write_output(dir_of(child.id), "found it")
      allow(Samagotchi::Session).to receive(:reparent).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do
          # The child's turn ends now, in its own process: it rings and wakes.
          Samagotchi::ChildRing.ring(load(child.id), why: "turn_end", state_dir: tmpdir)
          Samagotchi::ChildRing.await_wakes
        end
      end
      allow(described_class).to receive(:wake_for_report).and_call_original

      link = continue(previous.id)

      expect(described_class).to have_received(:wake_for_report).with(link.id, state_dir: tmpdir)
      expect(Process).to have_received(:spawn).once
      expect(ring_ids(link.id)).to eq([child.id])
      reports = Samagotchi::ChildReports.new(session_id: link.id, state_dir: tmpdir, predecessor: previous.id).take
      expect(reports.map(&:child_id)).to eq([child.id])
    end

    it "continues again after a crash between the archive and the new link (crash 1): the delegates move then" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
      Samagotchi::ArchiveStore.archive(previous.id, state_dir: tmpdir)

      link = continue(previous.id)

      expect(load(child.id).parent_id).to eq(link.id)
      expect([archived?(previous.id), archived?(child.id)]).to eq([true, false])
    end

    it "moves the delegates back when the new link's worker fails to spawn" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
      Samagotchi::SessionInbox.write_ring(dir_of(previous.id), child_id: child.id, why: "turn_end")
      allow(Process).to receive(:spawn).and_raise(Errno::EAGAIN)

      expect { continue(previous.id) }.to raise_error(Errno::EAGAIN)

      expect(load(child.id).parent_id).to eq(previous.id)
      expect(ring_ids(previous.id)).to eq([child.id])
      expect([archived?(previous.id), archived?(child.id)]).to eq([false, false])
      expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id))
        .to contain_exactly(previous.id, child.id)
      expect(notes_of(child.id).last[:text]).to start_with("Your parent session is #{previous.id[0, 8]} (#{previous.id}) " \
                                                           "again: the continue that moved you to its next link failed.")
    end

    it "gives back a ring a child wrote into the failed link as it was moved back, and wakes the previous link for it" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
      allow(Process).to receive(:spawn).and_raise(Errno::EAGAIN)
      allow(Samagotchi::ChildMove).to receive(:apply).and_wrap_original do |original, ids, **kwargs|
        original.call(ids, **kwargs).tap do
          # The child read the override just before the undo wrote it back.
          Samagotchi::SessionInbox.write_ring(dir_of(kwargs[:from]), child_id: child.id, why: "turn_end") if kwargs[:undo]
        end
      end
      allow(described_class).to receive(:wake_for_report)

      expect { continue(previous.id) }.to raise_error(Errno::EAGAIN)

      expect(ring_ids(previous.id)).to eq([child.id])
      expect(described_class).to have_received(:wake_for_report).with(previous.id, state_dir: tmpdir)
    end

    describe "a failure once the new link's worker exists" do
      let(:link_locks) { [] }

      before do
        allow(described_class).to receive(:spawn_worker_for_session) do |session, **|
          link_locks << Samagotchi::OwnerLock.acquire(dir_of(session.id), kind: "worker")
          raise IOError, "spawned, then failed"
        end
      end

      after { link_locks.each(&:release) }

      it "stops that worker, deletes the link and moves the delegates back" do
        previous = make
        child = make(prompt: "a", parent_id: previous.id, delegate: true)
        Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
        allow(described_class).to receive(:stop_session) do
          link_locks.each(&:release)
          true
        end

        expect { continue(previous.id) }.to raise_error(IOError)

        expect(described_class).to have_received(:stop_session).once
        expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id))
          .to contain_exactly(previous.id, child.id)
        expect(load(child.id).parent_id).to eq(previous.id)
        expect(archived?(previous.id)).to be(false)
      end

      it "raises DeleteRefused when that worker outlives the stop, with the delegates back and nothing archived" do
        previous = make
        child = make(prompt: "a", parent_id: previous.id, delegate: true)
        Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
        allow(described_class).to receive(:stop_session).and_return(false)

        expect { continue(previous.id) }.to raise_error(described_class::DeleteRefused, /still shutting down/)

        expect(load(child.id).parent_id).to eq(previous.id)
        expect([archived?(previous.id), archived?(child.id)]).to eq([false, false])
      end
    end
  end

  describe "refusals, which start nothing and archive nothing" do
    def expect_nothing_started(previous)
      expect(Process).not_to have_received(:spawn)
      expect(archived?(previous.id)).to be(false)
      expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:continues).compact).to be_empty
    end

    it "refuses a link that is continued already, naming the next one (a double click); an archived link reached later still continues" do
      previous = make
      link = continue(previous.id)

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ContinueRefused) { |e|
        expect(e).to have_attributes(reason: :continued, ids: [link.id])
        expect(e.message).to eq("#{previous.id[0, 8]} is continued already, by #{link.id[0, 8]}; " \
                                "continue that one (or last:#{previous.id[0, 8]})")
      }
      expect(Process).to have_received(:spawn).once

      Samagotchi::ArchiveStore.archive(link.id, state_dir: tmpdir)
      third = continue(link.id)
      expect(load(third.id).continues).to eq(link.id)
      expect(archived?(link.id)).to be(true)
    end

    it "refuses a live delegate on an older chi's worker (no reparent feature), naming it, and starts nothing" do
      previous = make
      old = make(prompt: "a", parent_id: previous.id, delegate: true)
      own(old.id)
      sidecar = Samagotchi::WorkerSidecar.new(port: 1, version: "0.46.1", features: %w[restart task_stop])
      allow(Samagotchi::WorkerSidecar).to receive(:live).and_call_original
      allow(Samagotchi::WorkerSidecar).to receive(:live).with(dir_of(old.id), unlink: false).and_return(sidecar)

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ContinueRefused) { |e|
        expect(e).to have_attributes(reason: :open_children, ids: [old.id])
        expect(e.message).to include("#{old.id[0, 8]} (older chi worker 0.46.1; restart it)")
      }
      expect_nothing_started(previous)
      expect(Samagotchi::Session.parent_override(old.id, state_dir: tmpdir)).to be_nil
    end

    it "refuses what the archive would refuse before asking for the recap (a queued prompt)" do
      previous = make
      Samagotchi::SessionInbox.write_input(dir_of(previous.id), prompt: "queued", client_id: "cli:send")
      allow(described_class).to receive(:recap_before_archive)

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ArchiveRefused) { |e|
        expect(e.reason).to eq(:queued)
      }
      expect(described_class).not_to have_received(:recap_before_archive)
      expect_nothing_started(previous)
    end

    it "refuses while the previous link runs a turn (archive_session's rule)" do
      previous = make(status: Samagotchi::Session::STATUS_RUNNING)
      own(previous.id)

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ArchiveRefused) { |e|
        expect(e.reason).to eq(:busy)
      }
      expect_nothing_started(previous)
    end

    it "refuses when the previous link's folder is gone" do
      previous = make
      FileUtils.rm_rf(folder)

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ContinueRefused, /folder .* is gone/)
      expect_nothing_started(previous)
    end

    it "refuses a model whose host config.yml no longer has before the archive stops anything" do
      stub_const("ENV", ENV.to_h.merge("SAMAGOTCHI_HOSTS_JSON" => JSON.generate("main" => { "host" => "localhost", "port" => 8080 })))
      previous = make
      previous.model_name = "gone:org/model"
      previous.save(state_dir: tmpdir)
      allow(described_class).to receive(:archive_session).and_call_original

      expect { continue(previous.id) }.to raise_error(Samagotchi::ModelProfile::UnknownHost, /unknown host 'gone'/)
      expect(described_class).not_to have_received(:archive_session)
      expect_nothing_started(previous)
    end

    it "refuses an unknown session" do
      expect { continue("feedbeef") }.to raise_error(ArgumentError, "no session feedbeef")
      expect { continue("../etc") }.to raise_error(ArgumentError, "no session ../etc")
    end

    it "deletes a new link saved before its worker failed to spawn, so the chain stays continuable" do
      previous = make
      allow(Process).to receive(:spawn).and_raise(Errno::EAGAIN)

      expect { continue(previous.id) }.to raise_error(Errno::EAGAIN)
      expect(archived?(previous.id)).to be(false)
      expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id)).to eq([previous.id])

      allow(Process).to receive(:spawn).and_return(12_345)
      expect(load(continue(previous.id).id).continues).to eq(previous.id)
    end

    it "puts what it archived back when the new link fails to start" do
      previous = make
      allow(described_class).to receive(:spawn_session).and_raise(Samagotchi::ModelProfile::MissingModel, "no model")

      expect { continue(previous.id) }.to raise_error(Samagotchi::ModelProfile::MissingModel)
      expect(archived?(previous.id)).to be(false)
    end
  end

  it "locks per session: a continue of another chain doesn't wait for one still waiting on its recap" do
    slow = make
    other = make
    started = Queue.new
    allow(described_class).to receive(:recap_before_archive).and_call_original
    allow(described_class).to receive(:recap_before_archive).with(slow.id, tmpdir, wait: 0) do
      started << true
      sleep 2
    end
    waiting = Thread.new { continue(slow.id) }
    started.pop

    at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    link = continue(other.id)
    expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - at).to be < 1.5
    expect(load(link.id).continues).to eq(other.id)
    waiting.join
  end

  it "follows last:<id> to the chain's new end when another continue moved it meanwhile" do
    first = make
    second = continue(first.id)
    allow(Samagotchi::SessionChain).to receive(:resolve).and_call_original
    allow(Samagotchi::SessionChain).to receive(:resolve).with("last:#{first.id}", state_dir: tmpdir).and_return(first.id, second.id)

    third = continue("last:#{first.id}")
    expect(load(third.id).continues).to eq(second.id)
  end

  it "continues the chain's latest link for last:<any link>" do
    first = make
    second = continue(first.id)
    third = continue("last:#{first.id[0, 6]}")

    expect(load(third.id).continues).to eq(second.id)
    expect(Samagotchi::SessionChain.resolve("last:#{second.id}", state_dir: tmpdir)).to eq(third.id)
    expect(Samagotchi::SessionChain.resolve(third.id[0, 8], state_dir: tmpdir)).to eq(third.id)
  end

  # An idle new link holds only the carry note until its first message; it
  # is kept, not discarded as empty, with the note queued or absorbed.
  it "keeps an idle continuation that holds only the carry note" do
    link = continue(make.id)
    expect(described_class.discardable?(link.id, default_model: "main:gemma-small", state_dir: tmpdir)).to be(false)

    note = note_of(link.id)
    saved = load(link.id)
    saved.messages = [{ role: "system", content: "prompt" }, Samagotchi::ContextNote.message(**note)]
    saved.save(state_dir: tmpdir)
    FileUtils.rm_rf(File.join(dir_of(link.id), Samagotchi::SessionInbox::NOTES_DIR))
    expect(described_class.discardable?(link.id, default_model: "main:gemma-small", state_dir: tmpdir)).to be(false)
  end
end
