# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_manager"
require "samagotchi/worker"
require "samagotchi/terminal_ui"
require "samagotchi/session_retention"

# "Is this session empty, so it goes?" as each place that deletes one asks
# it: the worker as it leaves (Worker#empty_session?), the REPL at /exit
# (TerminalUI#discard_on_exit?) and the retention sweep (SessionRetention.prune,
# sessions left empty an hour). One table of session states, one answer per
# asker; nil where that asker never meets the state.
RSpec.describe "discarding an empty session" do
  let(:tmpdir) { Dir.mktmpdir("session-discardable-spec") }
  let(:model) { Samagotchi::ModelProfile.required_model_name(nil) }
  let(:hour_ago) { Time.now - Samagotchi::SessionRetention::EMPTY_GRACE_SECONDS - 60 }

  after { FileUtils.rm_rf(tmpdir) }

  before { allow(Samagotchi::Session).to receive(:default_state_dir).and_return(tmpdir) }

  # A fresh session on the default model, its directory the worker's
  # skeleton; the row's block changes it, then it is saved (unless the row
  # says the REPL never saved it).
  def build(row)
    session = Samagotchi::Session.new_session(mode: "assist", model_name: model, working_directory: "/tmp",
                                              scratch: row.fetch(:scratch, false))
    session.messages << { role: "system", content: "You are chi." }
    dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
    %w[input output notes images].each { |sub| FileUtils.mkdir_p(File.join(dir, sub)) }
    %w[pid owner.lock bridge.json].each { |name| File.write(File.join(dir, name), "") }
    File.write(File.join(dir, "analytics.json"), JSON.generate("turns" => 0, "turn_records" => []))
    row[:change]&.call(session, dir)
    unless row[:unsaved]
      session.save(state_dir: tmpdir)
      path = File.join(tmpdir, "#{session.id}.json")
      File.utime(hour_ago, hour_ago, path)
    end
    session
  end

  def engine_double(row)
    double("engine", used_memory_names: row.fetch(:engine_memory, []))
  end

  def worker_says(row, session)
    worker = Samagotchi::Worker.new(session_id: session.id, state_dir: tmpdir,
                                    session_dir: Samagotchi::Session.session_dir(session.id, state_dir: tmpdir))
    worker.instance_variable_set(:@engine, engine_double(row))
    worker.instance_variable_set(:@default_model, model)
    worker.send(:empty_session?)
  end

  def repl_says(row, session)
    repl = Samagotchi::TerminalUI.allocate
    repl.instance_variable_set(:@engine, engine_double(row))
    repl.instance_variable_set(:@default_model_name, model)
    repl.instance_variable_set(:@effective_model_name, row.fetch(:repl_model, model))
    repl.send(:discard_on_exit?, session)
  end

  def sweep_says(session)
    result = Samagotchi::SessionRetention.prune(state_dir: tmpdir, days: 0, max_count: 0, keep_status: "none", dry_run: true)
    result[:deleted].include?(session.id)
  end

  rows = [
    { name: "fresh, on the default model", worker: true, repl: true, sweep: true },
    { name: "session.keep_empty", keep_empty: true, worker: false, repl: false, sweep: false },
    { name: "a conversation", change: ->(s, _) { s.messages << { role: "user", content: "hi" } },
      worker: false, repl: false, sweep: false },
    { name: "a context note", change: ->(s, _) { s.messages << { role: "system", kind: "note", content: "n" } },
      worker: false, repl: false, sweep: false },
    { name: "only a turn note (a first turn failed)",
      change: ->(s, _) { s.messages << Samagotchi::TurnNote.message("the previous turn failed before any answer") },
      worker: true, repl: true, sweep: true },
    { name: "a failed turn's last_prompt", change: ->(s, _) { s.last_prompt = "hi?" },
      worker: false, repl: false, sweep: false },
    { name: "a first prompt waiting", change: ->(s, _) { s.first_preview = "hello" },
      worker: false, repl: false, sweep: false },
    { name: "a pending question", change: ->(s, _) { s.pending_question = { question: "which?" } },
      worker: false, repl: false, sweep: false },
    { name: "memory saved as used", change: ->(s, _) { s.used_memory_names = ["notes"] },
      worker: false, repl: false, sweep: false },
    { name: "memory used in the Engine only", engine_memory: ["notes"], worker: false, repl: false, sweep: nil },
    { name: "saved on another model", change: ->(s, _) { s.model_name = "other/model" },
      worker: false, repl: false, sweep: false },
    { name: "the REPL on another model (/model, --model)", repl_model: "other/model", worker: nil, repl: false, sweep: nil },
    { name: "another mode", change: ->(s, _) { s.mode = "other" }, worker: false, repl: false, sweep: false },
    { name: "queued input", change: ->(_, d) { File.write(File.join(d, "input", "1.json"), "{}") },
      worker: false, repl: false, sweep: false },
    { name: "an image", change: ->(_, d) { File.write(File.join(d, "images", "a.png"), "") },
      worker: false, repl: false, sweep: false },
    { name: "a recorded turn",
      change: ->(_, d) { File.write(File.join(d, "analytics.json"), JSON.generate("turn_records" => [{ "id" => "t" }])) },
      worker: false, repl: false, sweep: false },
    { name: "archived", change: ->(_, d) { File.write(File.join(d, Samagotchi::ArchiveStore::FILE), "{}") },
      worker: false, repl: false, sweep: false },
    # The REPL deletes a scratch session before it asks; the sweep takes
    # one whatever is in it.
    { name: "a scratch session, empty", scratch: true, worker: true, repl: true, sweep: true },
    { name: "a scratch session, used", scratch: true, change: ->(s, _) { s.messages << { role: "user", content: "hi" } },
      worker: false, repl: false, sweep: true },
    { name: "never saved, empty", unsaved: true, worker: false, repl: true, sweep: nil },
    { name: "never saved, a conversation", unsaved: true,
      change: ->(s, _) { s.messages << { role: "user", content: "hi" } }, worker: false, repl: false, sweep: nil },
    { name: "never saved, a failed turn", unsaved: true, change: ->(s, _) { s.last_prompt = "hi?" },
      worker: false, repl: false, sweep: nil },
    { name: "never saved, queued input", unsaved: true,
      change: ->(_, d) { File.write(File.join(d, "input", "1.json"), "{}") }, worker: false, repl: false, sweep: nil }
  ].freeze

  rows.each do |row|
    it "answers for #{row[:name]}: worker #{row[:worker].inspect}, REPL #{row[:repl].inspect}, sweep #{row[:sweep].inspect}" do
      if row[:keep_empty]
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("session.keep_empty").and_return(true)
      end
      session = build(row)

      answers = {
        worker: row[:worker].nil? ? nil : worker_says(row, session),
        repl: row[:repl].nil? ? nil : repl_says(row, session),
        sweep: row[:sweep].nil? ? nil : sweep_says(session)
      }

      expect(answers).to eq(row.slice(:worker, :repl, :sweep))
    end
  end
end
