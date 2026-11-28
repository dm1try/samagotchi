# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"

require "samagotchi/web/last_ask"
require "samagotchi/session"
require "samagotchi/archive_store"

# The thin client's `last` (Web::LastAsk): the session an owner's ask last
# went to, kept in one small file beside the sessions folder, and the
# fallback when it is gone.
RSpec.describe Samagotchi::Web::LastAsk do
  around do |example|
    Dir.mktmpdir("last-ask") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  let(:state_dir) { File.join(@tmp, "samagotchi", "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }

  def make(updated_at: Time.now, **fields)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: @tmp, test_run: false).tap do |s|
      fields.each { |key, value| s.public_send(:"#{key}=", value) }
      s.save(state_dir: state_dir)
      data = JSON.parse(File.read(Samagotchi::Session.session_file(s.id, state_dir: state_dir)))
      File.write(Samagotchi::Session.session_file(s.id, state_dir: state_dir),
                 JSON.generate(data.merge("updated_at" => updated_at.iso8601(3))))
      FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
    end
  end

  describe ".record and .recorded" do
    it "keeps one id beside the sessions folder, written whole, readable by the owner only" do
      id = make.id
      described_class.record(id, state_dir: state_dir, at: Time.utc(2026, 11, 28))

      path = described_class.path(state_dir: state_dir)
      expect(path).to eq(File.join(@tmp, "samagotchi", "last_ask.json"))
      expect(JSON.parse(File.read(path))).to eq("session_id" => id, "at" => "2026-11-28T00:00:00.000Z")
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(Dir.glob(File.join(@tmp, "samagotchi", "*.tmp"))).to be_empty
      expect(described_class.recorded(state_dir: state_dir)).to eq(id)
    end

    it "reads nothing from a missing, corrupt or foreign file" do
      expect(described_class.recorded(state_dir: state_dir)).to be_nil
      path = described_class.path(state_dir: state_dir)
      File.write(path, "{not json")
      expect(described_class.recorded(state_dir: state_dir)).to be_nil
      File.write(path, JSON.generate("session_id" => "../etc"))
      expect(described_class.recorded(state_dir: state_dir)).to be_nil
      File.write(path, JSON.generate(%w[a b]))
      expect(described_class.recorded(state_dir: state_dir)).to be_nil
    end

    it "never fails the ask: a write that can't happen is logged" do
      id = make.id
      allow(Samagotchi::AtomicFile).to receive(:write).and_raise(Errno::EACCES)
      expect(Samagotchi::Log).to receive(:warn).with(:web, "last_ask_write_failed", hash_including(:msg))
      expect { described_class.record(id, state_dir: state_dir) }.not_to raise_error
    end
  end

  describe ".target" do
    it "is the recorded session while it is there" do
      a = make
      make
      described_class.record(a.id, state_dir: state_dir)
      expect(described_class.target(state_dir: state_dir)).to eq(a.id)
    end

    it "keeps a continued session's id (the ask follows the chain to its newest link)" do
      old = make
      Samagotchi::ArchiveStore.archive(old.id, state_dir: state_dir)
      make(continues: old.id)
      described_class.record(old.id, state_dir: state_dir)
      expect(described_class.target(state_dir: state_dir)).to eq(old.id)
    end

    it "falls back for an archived session nothing continues, and for a deleted one" do
      newest = make(updated_at: Time.now - 60)
      archived = make
      Samagotchi::ArchiveStore.archive(archived.id, state_dir: state_dir)
      described_class.record(archived.id, state_dir: state_dir)
      expect(described_class.target(state_dir: state_dir)).to eq(newest.id)

      gone = make
      described_class.record(gone.id, state_dir: state_dir)
      File.delete(Samagotchi::Session.session_file(gone.id, state_dir: state_dir))
      expect(described_class.target(state_dir: state_dir)).to eq(newest.id)
    end

    it "falls back to the newest of the owner's own sessions: no scratch, delegate, agent-driven, test or archived one" do
      now = Time.now
      mine = make(updated_at: now - 300)
      make(updated_at: now - 400)
      make(updated_at: now - 10, scratch: true)
      make(updated_at: now - 20, delegate: true, parent_id: mine.id)
      make(updated_at: now - 30, driver: "agent:claude")
      make(updated_at: now - 40, test_run: true)
      make(updated_at: now - 50).tap { |s| Samagotchi::ArchiveStore.archive(s.id, state_dir: state_dir) }

      expect(described_class.target(state_dir: state_dir)).to eq(mine.id)
    end

    it "is nil with no session to ask" do
      make(scratch: true)
      expect(described_class.target(state_dir: state_dir)).to be_nil
    end
  end
end
