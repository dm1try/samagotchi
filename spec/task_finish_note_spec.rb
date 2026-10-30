# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "time"
require "samagotchi/task_finish_note"

# The note a finished background task leaves in its session: a wake turn's
# first message, or a plain note (docs/internals/background-tasks.md).
RSpec.describe Samagotchi::TaskFinishNote do
  let(:dir) { Dir.mktmpdir("task-note") }
  let(:started) { Time.local(2026, 10, 19, 14, 14, 0) }
  let(:output_path) { File.join(dir, "output.log").tap { |p| File.write(p, (1..12).map { |i| "line #{i}\n" }.join) } }
  let(:exit_code_path) { File.join(dir, "exit_code").tap { |p| File.write(p, "0") } }
  let(:record) do
    Samagotchi::Tools::TaskRecord.running(id: "3f9a2c1d-0000-4000-8000-000000000000", command: "bundle exec rspec spec",
                                          cwd: dir, pid: 1, started_at: started.iso8601, output_path: output_path,
                                          exit_code_path: exit_code_path)
                                 .with(status: "completed", exit_code: 0, finished_at: (started + 900).iso8601)
  end
  let(:now) { Time.local(2026, 10, 19, 14, 20, 30) }

  before { File.utime(started + 372, started + 372, exit_code_path) }
  after { FileUtils.rm_rf(dir) }

  it "opens a wake turn: exit code, duration to the exit_code file, the hand-over, command, task_wait's text, the ask" do
    note = described_class.note(record, limit_sec: 120, wake: true, turn_id: "t1", cap: 10_000, now: now)

    expect(note).to include(note_id: "task-#{record.id}", source: "task 3f9a2c1d", header: "TASK FINISHED",
                            turn_start: true, turn_id: "t1", created_at: now.iso8601)
    expect(note[:text]).to start_with(
      "Background task 3f9a2c1d finished: exit 0 after 6m12s (handed over by execute at its 120s limit).\n" \
      "command: bundle exec rspec spec\n" \
      "task_id: #{record.id}\nstatus: completed\n"
    )
    expect(note[:text]).to include("output_tail:\nline 3\n").and include("line 12\n#{described_class::WAKE_TEXT}")
    expect(note[:text]).not_to include("line 2\n")

    message = Samagotchi::ContextNote.message(**note)
    expect(message[:content]).to start_with("[TASK FINISHED from task 3f9a2c1d, 14:20]\nBackground task")
  end

  it "says a message from the user handed the task over early, with the seconds the command had run" do
    note = described_class.note(record, limit_sec: nil, early_sec: 4, wake: true, turn_id: "t1", cap: 10_000, now: now)

    expect(note[:text]).to start_with(
      "Background task 3f9a2c1d finished: exit 0 after 6m12s (handed over by execute after 4s: a message from the user was waiting).\n"
    )
    expect(described_class.note(record, limit_sec: nil, wake: false, cap: 10_000, now: now)[:text]).not_to include("handed over")
  end

  it "has a plain variant without the turn start or the ask (queue mode, a spent budget, a note-only task)" do
    note = described_class.note(record, limit_sec: nil, wake: false, cap: 10_000, now: now)

    expect(note).not_to include(:turn_start, :turn_id)
    expect(note[:text]).to start_with("Background task 3f9a2c1d finished: exit 0 after 6m12s.\n")
    expect(note[:text]).not_to include("chi started this turn")
    expect(note[:text]).to end_with("line 12")
  end

  it "names a status without an exit code, and leaves the duration out when nothing says when it ended" do
    FileUtils.rm_f(exit_code_path)
    failed = record.with(status: "failed", exit_code: nil, finished_at: nil)

    text = described_class.note(failed, limit_sec: nil, wake: false, cap: 10_000, now: now)[:text]
    expect(text).to start_with("Background task 3f9a2c1d finished: failed.\n")
  end

  it "falls back to finished_at for the duration with no exit_code file" do
    FileUtils.rm_f(exit_code_path)

    text = described_class.note(record, limit_sec: nil, wake: false, cap: 10_000, now: now)[:text]
    expect(text).to start_with("Background task 3f9a2c1d finished: exit 0 after 15m00s.\n")
  end

  it "cuts task_wait's text to the cap as task_wait's result is cut, naming the log; the ask stays whole" do
    File.write(output_path, "#{"x" * 400}\n" * 10)

    text = described_class.note(record, limit_sec: nil, wake: true, cap: 1000, now: now)[:text]
    expect(text).to include(output_path).and end_with(described_class::WAKE_TEXT)
    expect(text.length).to be < 1000 + 600
  end

  it "names a task_create id by its random part, not the time it starts with" do
    timed = record.with(id: "20261019164550-0e055c67")
    note = described_class.note(timed, limit_sec: nil, wake: false, cap: 10_000, now: now)
    expect(note).to include(source: "task 0e055c67")
    expect(note[:text]).to start_with("Background task 0e055c67 finished")
  end

  it "formats durations" do
    expect(described_class.duration_text(45)).to eq("45s")
    expect(described_class.duration_text(372)).to eq("6m12s")
    expect(described_class.duration_text(3725)).to eq("1h02m")
  end
end
