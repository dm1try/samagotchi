# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "spec_helper"
require "samagotchi/schedules"

# A schedule's condition (`--if CMD`, Schedules::ConditionPart,
# docs/scheduling.md "Conditions (--if)"): the store and its compat codec.
RSpec.describe Samagotchi::Schedules::ConditionPart do
  let(:now) { Time.utc(2026, 11, 25, 12) }

  around do |example|
    Dir.mktmpdir("schedules-condition") do |root|
      @dir = File.join(root, "sessions")
      example.run
    end
  end

  def session
    stamp = Time.now.utc.iso8601
    Samagotchi::Session.new(
      id: SecureRandom.uuid, mode: "assist", model_name: "main:m", working_directory: Dir.tmpdir,
      created_at: stamp, updated_at: stamp, status: "idle", messages: [{ role: "user", content: "the routine" }]
    ).tap { |saved| saved.save(state_dir: @dir) }
  end

  def store(clock: -> { now }) = Samagotchi::Schedules.new(state_dir: @dir, clock: clock)
  def every(interval) = Samagotchi::Schedules.recurrence(every: interval)
  def raw(schedules) = JSON.parse(File.read(schedules.path))
  def raw_entry(schedules, id) = raw(schedules)["schedules"].find { |entry| entry["id"] == id }

  # 0.188.0's Entry#due? (lib/samagotchi/schedules.rb at v0.188.0), on the
  # stored next_due as that chi reads it: the member as the file has it.
  def due_on_0_188?(stored, at)
    Time.iso8601(stored["next_due"].to_s) <= at
  rescue ArgumentError
    false
  end

  it "stores the owner's command with who set it and when, and reads it back with the real next_due" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "test -f /tmp/x")

    expect(entry.condition).to eq(cmd: "test -f /tmp/x", by: "cli", set_at: now.iso8601)
    stored = schedules.lookup(entry.id)
    expect(stored.condition).to eq(entry.condition)
    expect(stored.next_due).to eq((now + 300).utc.iso8601)
    expect(stored.extra).not_to have_key(described_class::CONDITION_NEXT_DUE)
  end

  # Compat N-1: 0.188.0 would fire a condition entry whatever CMD says. Its
  # due? can't parse a null next_due, so it never fires it; the entry still
  # reads (null is present, not missing) and stays enabled.
  it "hides next_due from 0.188.0, whose due? and format then never fire it but still read it" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "exit 1")

    stored = raw_entry(schedules, entry.id)
    expect(stored["next_due"]).to be_nil
    expect(stored[described_class::CONDITION_NEXT_DUE]).to eq((now + 300).utc.iso8601)
    expect(stored["condition"]).to eq("cmd" => "exit 1", "by" => "cli", "set_at" => now.iso8601)
    [now + 300, now + (86_400 * 365)].each { |at| expect(due_on_0_188?(stored, at)).to be(false) }

    older = Samagotchi::StateFormat.new(
      version: Samagotchi::Schedules::VERSION,
      members: Samagotchi::Schedules::FORMAT.members.reject { |member| member.name == :condition },
      document_members: Samagotchi::Schedules::FORMAT.document_members
    )
    record = older.read(raw(schedules), collection: "schedules").entries.first
    expect(record).to be_readable
    expect(record.attributes).to include(next_due: nil, enabled: true)
    expect(record.extra).to include("condition", described_class::CONDITION_NEXT_DUE)
  end

  it "keeps the codec through every write: a change, an enable, a disable" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "exit 1")
    schedules.disable(entry.id)
    schedules.enable(entry.id)
    schedules.edit(entry.id, title: "Gate")

    stored = raw_entry(schedules, entry.id)
    expect([stored["next_due"], stored[described_class::CONDITION_NEXT_DUE]]).to eq([nil, (now + 300).utc.iso8601])
    expect(schedules.lookup(entry.id)).to have_attributes(next_due: (now + 300).utc.iso8601, title: "Gate")
  end

  it "takes a real next_due an older chi wrote since over the hidden one" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "exit 1")
    data = raw(schedules)
    data["schedules"].first["next_due"] = (now + 60).utc.iso8601
    File.write(schedules.path, JSON.generate(data))

    expect(schedules.lookup(entry.id).next_due).to eq((now + 60).utc.iso8601)
    schedules.edit(entry.id, title: "Gate")
    stored = raw_entry(schedules, entry.id)
    expect([stored["next_due"], stored[described_class::CONDITION_NEXT_DUE]]).to eq([nil, (now + 60).utc.iso8601])
  end

  it "drops the condition with --no-if, storing the real next_due again with no shadow key" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"), condition: "exit 1")
    edited = schedules.edit(entry.id, condition: :none)

    expect(edited.condition).to be_nil
    stored = raw_entry(schedules, entry.id)
    expect(stored["next_due"]).to eq((now + 300).utc.iso8601)
    expect(stored).not_to have_key(described_class::CONDITION_NEXT_DUE)
    expect(stored["condition"]).to be_nil
    expect(edited.history.last).to include(status: "edited", detail: "condition")
  end

  it "sets, changes and keeps a condition by its command on edit" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"))
    expect(raw_entry(schedules, entry.id)["next_due"]).to eq((now + 300).utc.iso8601)

    expect(schedules.edit(entry.id, condition: "exit 0").condition).to include(cmd: "exit 0", by: "cli")
    expect { schedules.edit(entry.id, condition: "exit 0") }.to raise_error(Samagotchi::Schedules::Usage, "nothing to change")
    expect(schedules.edit(entry.id, condition: "exit 1").condition[:cmd]).to eq("exit 1")
    expect { schedules.edit(entry.id, condition: :none) }.not_to raise_error
    expect { schedules.edit(entry.id, condition: :none) }.to raise_error(Samagotchi::Schedules::Usage, "nothing to change")
  end

  it "refuses a blank command, more than one line, more than 1 KiB, and a --date one-off either way" do
    schedules = store
    target = session.id
    date = Samagotchi::Schedules.recurrence(date: (now + 3600).localtime.strftime("%Y-%m-%dT%H:%M"))
    add = ->(cmd, recurrence: every("5m")) { schedules.add(target: target, prompt: "Check", recurrence: recurrence, condition: cmd) }

    expect { add.call("  ") }.to raise_error(Samagotchi::Schedules::Usage, "--if needs a command")
    ["a\nb", "a\rb", "a\0b"].each { |cmd| expect { add.call(cmd) }.to raise_error(Samagotchi::Schedules::Usage, /one line/) }
    expect { add.call("x" * 1025) }.to raise_error(Samagotchi::Schedules::Usage, /1025 bytes; the limit is 1024/)
    expect { add.call("x" * 1024) }.not_to raise_error
    expect { add.call("exit 0", recurrence: date) }.to raise_error(Samagotchi::Schedules::Usage, /--date one-off can't have --if/)

    gated = schedules.add(target: target, prompt: "Other", recurrence: every("1h"), condition: "exit 0")
    expect { schedules.edit(gated.id, recurrence: date) }.to raise_error(Samagotchi::Schedules::Usage, /--date one-off/)
    dated = schedules.add(target: target, prompt: "Once", recurrence: date)
    expect { schedules.edit(dated.id, condition: "exit 0") }.to raise_error(Samagotchi::Schedules::Usage, /--date one-off/)
    expect(schedules.edit(gated.id, recurrence: date, condition: :none).condition).to be_nil
  end

  it "still protects the schedule's sessions while next_due is hidden" do
    schedules = store
    anchor = session.id
    schedules.add(target: anchor, prompt: "Check", recurrence: every("5m"), condition: "exit 1")

    expect(schedules.protected_ids).to include(anchor)
    expect(schedules.hold(anchor)).to have_attributes(reason: :scheduled)
  end

  it "keeps a condition that isn't an object as it is, still hiding next_due: it gates, never fires unchecked" do
    schedules = store
    entry = schedules.add(target: session.id, prompt: "Check", recurrence: every("5m"))
    data = raw(schedules)
    data["schedules"].first["condition"] = "exit 0"
    File.write(schedules.path, JSON.generate(data))

    expect(schedules.lookup(entry.id).condition).to eq("exit 0")
    schedules.edit(entry.id, title: "Gate")
    expect(raw_entry(schedules, entry.id)).to include("next_due" => nil, "condition" => "exit 0")
  end
end
