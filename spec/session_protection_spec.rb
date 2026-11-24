# frozen_string_literal: true

require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/session_protection"
require "samagotchi/schedules"

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
end
