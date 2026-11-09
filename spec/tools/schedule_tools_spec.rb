# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "spec_helper"
require "samagotchi/tools/schedule_task"
require "samagotchi/tools/list_schedules"
require "samagotchi/tools/cancel_schedule"
require "samagotchi/schedules"
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
    Dir.mktmpdir("schedule-task") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      answer = described_class.call(nil, title: "Monday audit", prompt: "Audit the queue",
                                   weekday: 1, time: "09:00", peers: peers(dir, id))

      entry = store(dir).entries.first
      expect(answer).to include("Scheduled #{entry.id}", "chain · #{id[0, 8]}", "Mon 09:00", "chi schedule list")
      expect([entry.anchor, entry.head, entry.title, entry.mode]).to eq([id, id, "Monday audit", "chain"])
    end
  end

  it "takes the prompt from the tool's content when prompt: is not given" do
    Dir.mktmpdir("schedule-task") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      described_class.call("Check the build", every: "30m", peers: peers(dir, id))

      entry = store(dir).entries.first
      expect([entry.prompt, entry.mode, entry.recurrence_words]).to eq(["Check the build", "chain", "every 30m"])
    end
  end

  it "treats an empty argument as absent, the way models send unused fields" do
    Dir.mktmpdir("schedule-task") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      answer = described_class.call(nil, prompt: "Audit", every: "", weekday: 3, time: "10:00", peers: peers(dir, id))

      entry = store(dir).entries.first
      expect(answer).to include("Wed 10:00")
      expect(entry.recurrence).to eq({ kind: "weekday", weekday: 3, time: "10:00" })
    end
  end

  it "answers an error for a bad recurrence, a blank prompt and a session it cannot name" do
    Dir.mktmpdir("schedule-task") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id

      expect(described_class.call(nil, every: "1d", weekday: 1, time: "09:00", prompt: "x", peers: peers(dir, id)))
        .to eq("Error: give one of every, weekday or date, not more")
      expect(described_class.call(nil, every: "1x", prompt: "x", peers: peers(dir, id)))
        .to eq("Error: every needs an interval like 30m, 2h or 1d, got 1x")
      expect(described_class.call(nil, every: "0m", prompt: "x", peers: peers(dir, id)))
        .to eq("Error: every must be at least 1s, got 0m")
      expect(described_class.call(nil, prompt: "   ", every: "1h", peers: peers(dir, id)))
        .to eq("Error: a schedule needs a prompt")
      expect(described_class.call(nil, prompt: "x", every: "1h", peers: peers(dir, nil)))
        .to eq("Error: this session's id is not known here")
      expect(described_class.call(nil, prompt: "x", every: "1h", peers: peers(dir, "zzzzzzzz")))
        .to eq("Error: no session zzzzzzzz")
    end
  end

  # A schedule's prompt fires from a schedule, never a person: a shell line
  # would be refused at every firing (CommandIntake), so the add says so.
  it "refuses a prompt that starts with ! up front, and takes a /word one (it will be the model's text)" do
    Dir.mktmpdir("schedule-task") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id

      expect(described_class.call(nil, prompt: "  !touch x", every: "1h", peers: peers(dir, id)))
        .to eq("Error: #{Samagotchi::CommandIntake::REFUSED}")
      expect(store(dir).entries).to be_empty
      expect(described_class.call(nil, prompt: "/model x", every: "1h", peers: peers(dir, id))).not_to start_with("Error:")
    end
  end

  it "refuses a scratch session up front" do
    Dir.mktmpdir("schedule-task") do |root|
      dir = File.join(root, "sessions")
      now = Time.now.utc.iso8601
      scratch = Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                                        working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                                        status: "idle", scratch: true, messages: [])
      scratch.save(state_dir: dir)

      expect(described_class.call(nil, prompt: "x", every: "1h", peers: peers(dir, scratch.id)))
        .to include("a scratch session is deleted")
    end
  end

  it "refuses a schedule the chain already has, naming the one to cancel" do
    Dir.mktmpdir("schedule-task") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      schedules = store(dir)
      first = schedules.add(target: id, prompt: "Audit the queue", title: "Audit",
                            recurrence: Samagotchi::Schedules.recurrence(every: "1h"))

      answer = described_class.call(nil, prompt: "Audit the queue", every: "1h", peers: peers(dir, id))
      expect(answer).to include("Error: #{first.id} already schedules this")
      expect(answer).to include("chi schedule cancel #{first.id}")
      expect(schedules.entries.size).to eq(1)

      # The same title is a duplicate even with another prompt.
      expect(described_class.call(nil, prompt: "Something else", every: "3h", title: "Audit", peers: peers(dir, id)))
        .to include("already schedules this")
      # A different prompt and recurrence is a different schedule.
      expect(described_class.call(nil, prompt: "Check the build", every: "2h", peers: peers(dir, id)))
        .to start_with("Scheduled ")
    end
  end

  it "caps how many schedules one chain and one machine hold" do
    Dir.mktmpdir("schedule-task") do |root|
      dir = File.join(root, "sessions")
      id = session(dir).id
      schedules = store(dir)

      with_env("SAMAGOTCHI_SCHEDULE_MAX_PER_SESSION" => "2") do
        described_class.call(nil, prompt: "One", every: "1h", peers: peers(dir, id))
        described_class.call(nil, prompt: "Two", every: "2h", peers: peers(dir, id))
        expect(described_class.call(nil, prompt: "Three", every: "3h", peers: peers(dir, id)))
          .to eq("Error: this chain has 2 schedules, the limit is 2 (schedule.max_per_session)")
      end

      with_env("SAMAGOTCHI_SCHEDULE_MAX_TOTAL" => "2") do
        other = session(dir).id
        expect(described_class.call(nil, prompt: "Elsewhere", every: "1d", peers: peers(dir, other)))
          .to eq("Error: this machine has 2 schedules, the limit is 2 (schedule.max_total)")
        expect(schedules.entries.size).to eq(2)
      end
    end
  end
end

RSpec.describe Samagotchi::Tools::ListSchedules do
  def session_here(state_dir)
    now = Time.now.utc.iso8601
    Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                            working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                            status: "idle", messages: []).tap { |saved| saved.save(state_dir: state_dir) }
  end

  def peers(state_dir)
    Struct.new(:session_id, :state_dir).new(nil, state_dir)
  end

  it "says when there are none" do
    Dir.mktmpdir("schedule-list") do |root|
      dir = File.join(root, "sessions")
      expect(described_class.call(nil, peers: peers(dir))).to eq("No schedules.")
    end
  end

  it "prints one line per enabled schedule, with the skips and the disabled ones on request" do
    Dir.mktmpdir("schedule-list") do |root|
      dir = File.join(root, "sessions")
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
    Dir.mktmpdir("schedule-list") do |root|
      dir = File.join(root, "sessions")
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

  it "lists only the schedules of this session's chain, and points at the machine-wide list" do
    Dir.mktmpdir("schedule-list") do |root|
      dir = File.join(root, "sessions")
      mine = session_here(dir).id
      other = session_here(dir).id
      schedules = Samagotchi::Schedules.new(state_dir: dir)
      entry = schedules.add(target: mine, prompt: "Audit", recurrence: Samagotchi::Schedules.recurrence(every: "1h"))
      theirs = schedules.add(target: other, prompt: "Someone else's", recurrence: Samagotchi::Schedules.recurrence(every: "2h"))
      here = Struct.new(:session_id, :state_dir).new(mine, dir)

      answer = described_class.call(nil, peers: here)
      expect(answer).to include(entry.id)
      expect(answer).not_to include(theirs.id)
      expect(answer.lines.last).to include("`chi schedule list` shows every schedule on this machine")

      expect(described_class.call(nil, all: true, peers: here)).to include(theirs.id)
    end
  end

  it "sees a schedule anchored at an earlier link of the chain" do
    Dir.mktmpdir("schedule-list") do |root|
      dir = File.join(root, "sessions")
      now = Time.now.utc.iso8601
      parent = Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                                       working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                                       status: "idle", messages: []).tap { |saved| saved.save(state_dir: dir) }.id
      child = Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                                      working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                                      status: "idle", continues: parent, messages: [])
                                      .tap { |saved| saved.save(state_dir: dir) }.id
      schedules = Samagotchi::Schedules.new(state_dir: dir)
      entry = schedules.add(target: parent, prompt: "Audit", recurrence: Samagotchi::Schedules.recurrence(every: "1h"))
      other = session_here(dir).id
      schedules.add(target: other, prompt: "Not ours", recurrence: Samagotchi::Schedules.recurrence(every: "2h"))

      answer = described_class.call(nil, peers: Struct.new(:session_id, :state_dir).new(child, dir))
      expect(answer).to include(entry.id)
      expect(answer.lines.size).to eq(2) # the entry and the pointer line
    end
  end
end

RSpec.describe Samagotchi::Tools::CancelSchedule do
  def session_here(state_dir)
    now = Time.now.utc.iso8601
    Samagotchi::Session.new(id: SecureRandom.uuid, mode: "assist", model_name: "main:m",
                            working_directory: Dir.tmpdir, created_at: now, updated_at: now,
                            status: "idle", messages: []).tap { |saved| saved.save(state_dir: state_dir) }
  end

  def peers(state_dir)
    Struct.new(:session_id, :state_dir).new(nil, state_dir)
  end

  it "cancels by id, a prefix or the title" do
    Dir.mktmpdir("schedule-cancel") do |root|
      dir = File.join(root, "sessions")
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
    Dir.mktmpdir("schedule-cancel") do |root|
      dir = File.join(root, "sessions")
      expect(described_class.call("", peers: peers(dir))).to eq("Error: cancel_schedule needs the schedule's id or title")
      expect(described_class.call("gone", peers: peers(dir))).to eq("No schedule named gone.")
    end
  end

  it "refuses a schedule of another session's chain, and takes it with all: true" do
    Dir.mktmpdir("schedule-cancel") do |root|
      dir = File.join(root, "sessions")
      mine = session_here(dir).id
      other = session_here(dir).id
      schedules = Samagotchi::Schedules.new(state_dir: dir)
      theirs = schedules.add(target: other, prompt: "Their routine", recurrence: Samagotchi::Schedules.recurrence(every: "1h"))
      here = Struct.new(:session_id, :state_dir).new(mine, dir)

      answer = described_class.call(theirs.id, peers: here)
      expect(answer).to include("belongs to another session's chain")
      expect(answer).to include("chi schedule cancel #{theirs.id}")
      expect(schedules.entries.size).to eq(1)

      expect(described_class.call(theirs.id, all: true, peers: here)).to eq("Cancelled #{theirs.id} (every 1h).")
      expect(schedules.entries).to be_empty
    end
  end
end
