# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/session_protection"
require "samagotchi/schedules"
require "samagotchi/session_retention"
require "samagotchi/session_chain/delete"
require "samagotchi/session_chain/delete_preview"

RSpec.describe Samagotchi::SessionProtection do
  let(:root) { Dir.mktmpdir("session-protection-spec") }
  let(:sessions_dir) { File.join(root, "sessions").tap { |path| FileUtils.mkdir_p(path) } }
  let(:schedules) { Samagotchi::Schedules.new(state_dir: sessions_dir) }

  after { FileUtils.rm_rf(root) }

  def saved_session(continues: nil)
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
    session.continues = continues
    session.save(state_dir: sessions_dir)
    session
  end

  def every_hour = Samagotchi::Schedules.recurrence(every: "1h")

  def edit_file
    data = JSON.parse(File.read(schedules.path))
    yield data.fetch("schedules")
    File.write(schedules.path, JSON.generate(data))
  end

  describe "the schedule protector" do
    # anchor ← head ← target: the schedule stores anchor and head; its
    # target resolves to the chain's latest link.
    let!(:anchor) { saved_session }
    let!(:head) { saved_session(continues: anchor.id) }
    let!(:target) { saved_session(continues: head.id) }
    let!(:other) { saved_session }
    let!(:entry) do
      schedules.add(target: anchor.id, prompt: "Audit", recurrence: every_hour).tap do
        edit_file { |list| list.first["head"] = head.id }
      end
    end

    it "holds an enabled schedule's anchor, head and resolved target, and nothing else" do
      expect(described_class.protected_ids(state_dir: sessions_dir)).to contain_exactly(anchor.id, head.id, target.id)
    end

    it "answers a link's hold with :scheduled and the schedule id, for the anchor, the head and the target" do
      [anchor, head, target].each do |session|
        expect(described_class.hold(session.id, state_dir: sessions_dir))
          .to eq(described_class::Hold.new(session_id: session.id, reason: :scheduled, ref: entry.id))
      end
      expect(described_class.hold(other.id, state_dir: sessions_dir)).to be_nil
    end

    it "answers a chain's hold with :chain_scheduled for any link of the chain" do
      expect(described_class.chain_hold(target.id, state_dir: sessions_dir))
        .to eq(described_class::Hold.new(session_id: target.id, reason: :chain_scheduled, ref: entry.id))
      expect(described_class.chain_hold(other.id, state_dir: sessions_dir)).to be_nil
    end

    it "holds nothing for a disabled schedule" do
      schedules.disable(entry.id)

      expect(described_class.protected_ids(state_dir: sessions_dir)).to be_empty
      expect(described_class.hold(anchor.id, state_dir: sessions_dir)).to be_nil
      expect(described_class.hold(target.id, state_dir: sessions_dir)).to be_nil
      expect(described_class.chain_hold(target.id, state_dir: sessions_dir)).to be_nil
    end

    it "names the schedule whose anchor or head a session is before one whose target it is" do
      # +entry+ resolves to +target+ and sorts first; +own+ is anchored on it.
      own = schedules.add(target: target.id, prompt: "Own", recurrence: every_hour)
      edit_file do |list|
        list.find { |row| row["id"] == entry.id }["next_due"] = "2000-01-01T00:00:00Z"
        list.find { |row| row["id"] == own.id }["next_due"] = "2999-01-01T00:00:00Z"
      end
      expect(schedules.entries.first.id).to eq(entry.id)

      expect(described_class.hold(target.id, state_dir: sessions_dir).ref).to eq(own.id)
    end
  end

  describe "a protector that raises" do
    let(:failing) do
      Class.new do
        def protected_ids = raise(IOError, "unreadable")
        def hold(_id) = raise(IOError, "unreadable")
        def chain_hold(_id) = raise(IOError, "unreadable")
      end.new
    end

    before { allow(Samagotchi::Log).to receive(:warn) }

    it "raises from every question when its method raises, and logs protector_failed" do
      stub_const("#{described_class}::PROTECTORS", { schedule: ->(_dir) { failing } })

      expect { described_class.protected_ids(state_dir: sessions_dir) }.to raise_error(IOError, "unreadable")
      expect { described_class.hold("abc", state_dir: sessions_dir) }.to raise_error(IOError)
      expect { described_class.chain_hold("abc", state_dir: sessions_dir) }.to raise_error(IOError)
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:worker, "protector_failed", hash_including(protector: :schedule, sid: "abc", error: "IOError")).twice
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:worker, "protector_failed", hash_including(protector: :schedule, sid: nil)).once
    end

    it "raises from every question when building it raises" do
      stub_const("#{described_class}::PROTECTORS", { schedule: ->(_dir) { raise ArgumentError, "no dir" } })

      expect { described_class.protected_ids(state_dir: sessions_dir) }.to raise_error(ArgumentError, "no dir")
      expect { described_class.hold("abc", state_dir: sessions_dir) }.to raise_error(ArgumentError)
      expect { described_class.chain_hold("abc", state_dir: sessions_dir) }.to raise_error(ArgumentError)
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:worker, "protector_failed", hash_including(protector: :schedule, error: "ArgumentError")).exactly(3).times
    end
  end

  describe "an unreadable schedules.json" do
    let!(:plain) { saved_session }
    let!(:delegate) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |child|
        child.parent_id = plain.id
        child.delegate = true
        child.save(state_dir: sessions_dir)
      end
    end
    let(:words) { /\Aschedules\.json is unreadable \(.+\): fix or remove it before deleting sessions\z/ }

    before { allow(Samagotchi::Log).to receive(:warn) }

    def on_disk?(session) = File.exist?(Samagotchi::Session.session_file(session.id, state_dir: sessions_dir))

    shared_examples "fails closed" do
      it "makes every question raise in its words, logging nothing itself (the caller logs it)" do
        expect { described_class.protected_ids(state_dir: sessions_dir) }.to raise_error(described_class::Unreadable, words)
        expect { described_class.hold(plain.id, state_dir: sessions_dir) }.to raise_error(described_class::Unreadable, words)
        expect { described_class.chain_hold(plain.id, state_dir: sessions_dir) }
          .to raise_error(described_class::Unreadable, words)
        expect(Samagotchi::Log).not_to have_received(:warn)
      end

      it "skips the retention sweep's deletes once per interval, one log record, the saved runs still swept" do
        expect { Samagotchi::SessionRetention.apply(state_dir: sessions_dir, days: 0, max_count: 0, any_age: true) }
          .to raise_error(described_class::Unreadable, words)
        allow(Samagotchi::SessionRetention).to receive(:sweep_runs).and_call_original
        marker = File.join(sessions_dir, Samagotchi::SessionRetention::MARKER)

        expect(Samagotchi::SessionRetention.sweep_if_due(state_dir: sessions_dir)).to be_nil
        expect(Samagotchi::SessionRetention.sweep_if_due(state_dir: sessions_dir)).to be_nil

        expect(Samagotchi::Log).to have_received(:warn).once
        expect(Samagotchi::Log).to have_received(:warn).with(:worker, "retention_skipped", hash_including(msg: match(words)))
        expect(Samagotchi::SessionRetention).to have_received(:sweep_runs).once
        expect(File).to exist(marker)
        expect([plain, delegate].map { |session| on_disk?(session) }).to eq([true, true])
      end

      it "refuses a link's, a delegate's and a chain's delete with that one message, and the sheet shows it" do
        manager = Samagotchi::SessionManager
        refused = lambda do |error|
          expect(error).to have_attributes(reason: :protection_unreadable, schedule_id: nil)
          expect(error.message).to match(words)
        end

        expect { manager.delete_session(plain.id, state_dir: sessions_dir, stop: true, revive_previous: true) }
          .to raise_error(manager::DeleteRefused, &refused)
        expect { manager.delete_session(delegate.id, state_dir: sessions_dir) }.to raise_error(manager::DeleteRefused, &refused)
        expect { manager.delete_chain(plain.id, state_dir: sessions_dir, stop: true) }.to raise_error(manager::DeleteRefused, &refused)
        # The delegate that would go with its parent is refused in the same words.
        expect { Samagotchi::SessionChain::Delete.precheck!([delegate.id], sessions_dir) }
          .to raise_error(manager::DeleteRefused, &refused)
        # The delete sheet (a session in no chain: its link choice).
        shown = Samagotchi::SessionChain::Delete::Preview.call(plain.id, state_dir: sessions_dir)
        expect(shown.dig(:link, :refusal)).to include(reason: "protection_unreadable", message: match(words))
        expect([plain, delegate].map { |session| on_disk?(session) }).to eq([true, true])
      end
    end

    context "when it is not JSON" do
      before { File.write(schedules.path, "{not json") }

      it_behaves_like "fails closed"

      it "leaves the tick refusing as it does today" do
        expect { schedules.tick }.to raise_error(Samagotchi::Schedules::Corrupt, /not readable JSON/)
      end
    end

    context "when it is not a schedules document" do
      before { File.write(schedules.path, JSON.generate({ "version" => 1, "schedules" => "nope" })) }

      it_behaves_like "fails closed"
    end

    context "when its schedules member is not a list" do
      before { File.write(schedules.path, JSON.generate({ "version" => 1, "schedules" => {} })) }

      it_behaves_like "fails closed"
    end

    context "when chi can't open it (a directory in its place)" do
      before { FileUtils.mkdir_p(schedules.path) }

      it_behaves_like "fails closed"
    end

    context "when one entry can't be read" do
      let!(:good) { schedules.add(target: delegate.id, prompt: "Other", recurrence: every_hour) }
      let!(:bad) do
        schedules.add(target: other_session.id, prompt: "Audit", recurrence: every_hour).tap do |entry|
          edit_file { |list| list.find { |row| row["id"] == entry.id }.delete("prompt") }
        end
      end
      let(:other_session) { saved_session }
      let(:words) do
        /\Aschedule entry #{bad.id} in schedules\.json is unreadable \(lacks prompt\): chi schedule cancel #{bad.id}, or fix the file, before deleting sessions\z/
      end

      it_behaves_like "fails closed"

      it "leaves the tick reading the rest as it does today" do
        expect(schedules.tick.outcomes).to be_empty
      end

      it "is dropped by chi schedule cancel <id>, after which deletes work again" do
        expect { Samagotchi::SessionManager.delete_session(plain.id, state_dir: sessions_dir) }
          .to raise_error(Samagotchi::SessionManager::DeleteRefused, words)

        expect(schedules.cancel(bad.id)).not_to be_nil
        expect(schedules.cancel(bad.id)).to be_nil

        expect(described_class.protected_ids(state_dir: sessions_dir)).to include(delegate.id)
        expect(Samagotchi::SessionManager.delete_session(plain.id, state_dir: sessions_dir, stop: true)[:id]).to eq(plain.id)
        expect(schedules.lookup(good.id)).not_to be_nil
      end
    end

    it "is no schedules when the file is missing" do
      expect(File.exist?(schedules.path)).to be(false)
      expect(described_class.protected_ids(state_dir: sessions_dir)).to be_empty
      expect(described_class.hold(plain.id, state_dir: sessions_dir)).to be_nil
      expect(Samagotchi::SessionManager.delete_session(delegate.id, state_dir: sessions_dir)[:id]).to eq(delegate.id)
    end
  end
end
