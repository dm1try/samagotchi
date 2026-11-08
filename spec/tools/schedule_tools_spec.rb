# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "spec_helper"
require "samagotchi/tools/schedule_task"
require "samagotchi/tools/list_schedules"
require "samagotchi/tools/cancel_schedule"
require "samagotchi/session"

# The schedule tools (docs/scheduling.md): what the model can register, list and
# cancel, and the errors it gets back. The owner-voiced denial for a participant's
# turn is spec/guardrails/pair_boundary_spec.rb.
RSpec.describe Samagotchi::Tools::ScheduleTask do
  def session(state_dir)
    now = Time.now.utc.iso8601
    Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                            working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                            status: "idle", messages: [{ role: "user", content: "the routine" }])
                            .tap { |saved| saved.save(state_dir: state_dir) }
  end

  def peers(state_dir, session_id)
    Struct.new(:session_id, :state_dir).new(session_id, state_dir)
  end

  def store(state_dir)
    Samagotchi::Schedules.new(state_dir: state_dir)
  end

  it "registers a schedule anchored at the session the model is in" do
    Dir.mktmpdir("schedule-task") do |dir|
      id = session(dir).id
      answer = described_class.call(nil, title: "Monday audit", prompt: "Audit the queue",
                                   weekday: 1, time: "09:00", peers: peers(dir, id))

      entry = store(dir).entries.first
      expect(answer).to include("Scheduled #{entry.id}", "chain · #{id[0, 8]}", "Mon 09:00", "chi schedule list")
      expect([entry.anchor, entry.head, entry.title, entry.mode]).to eq([id, id, "Monday audit", "chain"])
    end
  end

  it "takes the prompt from the tool's content when prompt: is not given" do
    Dir.mktmpdir("schedule-task") do |dir|
      id = session(dir).id
      described_class.call("Check the build", every: "30m", peers: peers(dir, id))

      entry = store(dir).entries.first
      expect([entry.prompt, entry.mode, entry.recurrence_words]).to eq(["Check the build", "chain", "every 30m"])
    end
  end

  it "answers an error for a bad recurrence, a blank prompt and a session it cannot name" do
    Dir.mktmpdir("schedule-task") do |dir|
      id = session(dir).id

      expect(described_class.call(nil, every: "1d", weekday: 1, time: "09:00", prompt: "x", peers: peers(dir, id)))
        .to eq("Error: give one of --every, --weekday or --date, not more")
      expect(described_class.call(nil, every: "1x", prompt: "x", peers: peers(dir, id)))
        .to eq("Error: every must be like 30m, 2h or 1d, got 1x")
      expect(described_class.call(nil, prompt: "   ", every: "1h", peers: peers(dir, id)))
        .to eq("Error: a schedule needs a prompt")
      expect(described_class.call(nil, prompt: "x", every: "1h", peers: peers(dir, nil)))
        .to eq("Error: this session's id is not known here")
      expect(described_class.call(nil, prompt: "x", every: "1h", peers: peers(dir, "zzzzzzzz")))
        .to eq("Error: no session zzzzzzzz")
    end
  end

  it "refuses a scratch session up front" do
    Dir.mktmpdir("schedule-task") do |dir|
      now = Time.now.utc.iso8601
      scratch = Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                                        working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                                        status: "idle", scratch: true, messages: [])
      scratch.save(state_dir: dir)

      expect(described_class.call(nil, prompt: "x", every: "1h", peers: peers(dir, scratch.id)))
        .to include("a scratch session is deleted")
    end
  end
end

RSpec.describe Samagotchi::Tools::ListSchedules do
  def peers(state_dir)
    Struct.new(:session_id, :state_dir).new(nil, state_dir)
  end

  it "says when there are none" do
    Dir.mktmpdir("schedule-list") do |dir|
      expect(described_class.call(nil, peers: peers(dir))).to eq("No schedules.")
    end
  end

  it "prints one line per enabled schedule, with the skips and the disabled ones on request" do
    Dir.mktmpdir("schedule-list") do |dir|
      now = Time.now.utc.iso8601
      anchor = Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                                       working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                                       status: "idle", messages: []).tap { |saved| saved.save(state_dir: dir) }.id
      schedules = Samagotchi::Schedules.new(state_dir: dir)
      entry = schedules.add(target: anchor, prompt: "Audit", title: "Audit",
                            recurrence: Samagotchi::Schedules.recurrence(every: "1h"))
      other = schedules.add(target: anchor, prompt: "Weekly",
                            recurrence: Samagotchi::Schedules.recurrence(weekday: 3, time: "18:00"))
      schedules.disable(other.id)

      lines = described_class.call(nil, peers: peers(dir)).split("\n")
      expect(lines.size).to eq(1)
      expect(lines.first).to include(entry.id.to_s, "chain · #{anchor[0, 8]}", "every 1h")

      with_disabled = described_class.call(nil, include_disabled: true, peers: peers(dir)).split("\n")
      expect(with_disabled.size).to eq(2)
      expect(with_disabled.last).to include("disabled after 0 failures")
    end
  end

  it "reads include_disabled from a string too" do
    Dir.mktmpdir("schedule-list") do |dir|
      now = Time.now.utc.iso8601
      anchor = Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                                       working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                                       status: "idle", messages: []).tap { |saved| saved.save(state_dir: dir) }.id
      schedules = Samagotchi::Schedules.new(state_dir: dir)
      schedules.disable(schedules.add(target: anchor, prompt: "Audit", recurrence: Samagotchi::Schedules.recurrence(every: "1h")).id)

      expect(described_class.call(nil, include_disabled: "true", peers: peers(dir)).split("\n").size).to eq(1)
      expect(described_class.call(nil, peers: peers(dir))).to eq("No schedules.")
    end
  end
end

RSpec.describe Samagotchi::Tools::CancelSchedule do
  def peers(state_dir)
    Struct.new(:session_id, :state_dir).new(nil, state_dir)
  end

  it "cancels by id, a prefix or the title" do
    Dir.mktmpdir("schedule-cancel") do |dir|
      now = Time.now.utc.iso8601
      anchor = Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                                       working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                                       status: "idle", messages: []).tap { |saved| saved.save(state_dir: dir) }.id
      schedules = Samagotchi::Schedules.new(state_dir: dir)
      entry = schedules.add(target: anchor, prompt: "Audit", title: "Audit",
                            recurrence: Samagotchi::Schedules.recurrence(every: "1h"))

      expect(described_class.call("Audit", peers: peers(dir))).to eq("Cancelled #{entry.id} (Audit).")
      expect(schedules.entries).to be_empty

      other = schedules.add(target: anchor, prompt: "Weekly", recurrence: Samagotchi::Schedules.recurrence(every: "1d"))
      expect(described_class.call(other.id[0, 6], peers: peers(dir))).to eq("Cancelled #{other.id} (every 1d).")
      expect(schedules.entries).to be_empty
    end
  end

  it "names what it needs and says when nothing matches" do
    Dir.mktmpdir("schedule-cancel") do |dir|
      expect(described_class.call("", peers: peers(dir))).to eq("Error: cancel_schedule needs the schedule's id or title")
      expect(described_class.call("gone", peers: peers(dir))).to eq("No schedule named gone.")
    end
  end
end
