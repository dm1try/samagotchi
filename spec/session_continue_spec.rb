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

    it "refuses while a delegate runs, waits, has a live worker or a reply its parent wasn't given, naming them" do
      previous = make
      running = make(prompt: "a", parent_id: previous.id, delegate: true, status: Samagotchi::Session::STATUS_RUNNING)
      own(running.id)
      live = make(prompt: "b", parent_id: previous.id, delegate: true)
      own(live.id)
      unreported = make(prompt: "c", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(unreported.id), "done")

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ContinueRefused) { |e|
        expect(e.reason).to eq(:open_children)
        expect(e.ids).to contain_exactly(running.id, live.id, unreported.id)
        expect(e.message).to include("#{running.id[0, 8]} (running)", "#{live.id[0, 8]} (live)",
                                     "#{unreported.id[0, 8]} (unreported reply)")
      }
      expect_nothing_started(previous)
    end

    it "refuses for an open delegate of a delegate (the archive's cascade goes that deep)" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      grandchild = make(prompt: "b", parent_id: child.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(grandchild.id), "done")

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ContinueRefused) { |e|
        expect(e).to have_attributes(reason: :open_children, ids: [grandchild.id])
      }
      expect_nothing_started(previous)
    end

    it "looks again after the recap wait: a delegate started meanwhile refuses it" do
      previous = make
      allow(described_class).to receive(:recap_before_archive) do
        child = make(prompt: "late", parent_id: previous.id, delegate: true)
        Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
      end

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ContinueRefused, /unreported reply/)
      expect_nothing_started(previous)
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
