# frozen_string_literal: true

require "tmpdir"
require "json"
require "samagotchi/reminder_carry"
require "samagotchi/reminder_store"

RSpec.describe Samagotchi::ReminderCarry do
  let(:dir) { Dir.mktmpdir("reminder-carry") }
  let(:sid) { "11111111-2222-3333-4444-555555555555" }
  let(:wall) { Time.utc(2026, 10, 27, 12, 0, 0) }
  let(:store) { Samagotchi::ReminderStore.new }
  let(:file) { File.join(dir, described_class::FILE) }

  after { FileUtils.rm_rf(dir) }

  def write_file(**fields)
    File.write(file, JSON.generate({ "session_id" => sid, "written_at" => wall.iso8601(3),
                                     "reminders" => [{ "id" => "a1", "name" => "health", "description" => "d",
                                                       "interval_minutes" => 5,
                                                       "next_fire_at" => wall.iso8601(3) }] }
                                     .merge(fields.transform_keys(&:to_s))))
  end

  describe ".write" do
    it "writes the reminders with the session id and its time, readable only by the owner" do
      store.register({ name: "health", description: "Check API", interval_minutes: 20 })
      expect(described_class.write(dir, session_id: sid, store: store, wall: wall)).to eq(1)

      data = JSON.parse(File.read(file))
      expect(data).to include("session_id" => sid, "written_at" => "2026-10-27T12:00:00.000Z")
      expect(data["reminders"].map { |r| r["name"] }).to eq(["health"])
      expect(File.stat(file).mode & 0o777).to eq(0o600)
    end

    it "writes no file, and removes an old one, when there are no reminders" do
      write_file
      expect(described_class.write(dir, session_id: sid, store: store, wall: wall)).to eq(0)
      expect(File.exist?(file)).to be(false)
    end
  end

  describe ".take" do
    it "answers the entries for the store and deletes the file" do
      write_file
      entries = described_class.take(dir, session_id: sid, wall: wall + 5)
      expect(store.restore(entries, wall: wall + 5)).to eq(["health"])
      expect(File.exist?(file)).to be(false)
    end

    it "is nothing without a file" do
      expect(described_class.take(dir, session_id: sid, wall: wall)).to be_nil
    end

    it "deletes without restoring when the session is stopped, the file is another session's, old or unreadable" do
      [[{}, { stopped: true }],
       [{ session_id: "99999999-2222-3333-4444-555555555555" }, {}],
       [{ written_at: (wall - described_class::WINDOW - 1).iso8601(3) }, {}],
       [{ written_at: (wall + described_class::WINDOW + 1).iso8601(3) }, {}],
       [{ written_at: "yesterday" }, {}],
       [nil, {}]].each do |fields, opts|
        fields.nil? ? File.write(file, "{not json") : write_file(**fields)
        expect(described_class.take(dir, session_id: sid, wall: wall, **opts)).to be_nil
        expect(File.exist?(file)).to be(false)
      end
    end

    it "logs a stopped session's drop at info, any other at warn" do
      allow(Samagotchi::Log).to receive(:info)
      allow(Samagotchi::Log).to receive(:warn)
      write_file
      described_class.take(dir, session_id: sid, wall: wall, stopped: true)
      write_file(written_at: (wall - 3600).iso8601(3))
      described_class.take(dir, session_id: sid, wall: wall)
      expect(Samagotchi::Log).to have_received(:info).with(:worker, "reminders_carry_dropped", why: :stopped)
      expect(Samagotchi::Log).to have_received(:warn).with(:worker, "reminders_carry_dropped", why: :stale)
    end
  end

  describe ".remove" do
    it "removes the file, and is quiet without one" do
      write_file
      described_class.remove(dir)
      expect(File.exist?(file)).to be(false)
      expect { described_class.remove(dir) }.not_to raise_error
    end
  end
end
