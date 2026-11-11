# frozen_string_literal: true

require "spec_helper"
require "samagotchi/objectives"

RSpec.describe Samagotchi::Objectives::Backing do
  let(:list) { Samagotchi::Objectives::List.new.set([{ text: "Specs pass" }, { text: "Docs" }]) }
  let(:list_note) do
    Samagotchi::ContextNote.message(note_id: "n1", text: list.text, source: Samagotchi::Objectives::SOURCE,
                                    header: Samagotchi::ContextNote::OBJECTIVES_HEADER, objectives: list.to_payload)
  end

  def prompt(text = "go") = { role: "user", content: text, turn_id: "t-#{text}", turn_start: true }

  # A chat host's step: one call and its saved result, the runner's "[name]" lead on it.
  def step(id, name, args, output)
    [{ role: "model", content: "", tool_calls: [{ id: id, name: name, arguments: args }] },
     { role: "tool_response", content: "[#{name}]\n#{output}", tool_call_id: id, tool_ids: ["t#{id}"] }]
  end

  def edit(id) = step(id, "edit", { path: "a.rb", old_string: "a", new_string: "b" }, "Edited a.rb")
  def rspec(id, exit_code = 0) = step(id, "execute", { command: "bundle exec rspec" }, "3 examples\nexit: #{exit_code}")
  def done(id, obj = "O1", state = "done") = step(id, "objectives", { id: obj, note: "green", state: state }, "Recorded a move on #{obj}.")

  def backing(*entries, id: "O1") = Samagotchi::Objectives.build([list_note, prompt, *entries.flatten(1)]).moves.fetch(id).backing

  it "is clean after edit, a command that passed, then done" do
    expect(backing(edit("a"), rspec("b"), done("c")))
      .to have_attributes(edits: 1, command: "ok", edited_after_command: false, unbacked: false)
  end

  it "flags a done move edited after the last command that checked an earlier edit" do
    b = backing(edit("a"), rspec("b"), edit("c"), done("d"))
    expect(b).to have_attributes(edits: 2, command: "ok", edited_after_command: true, unbacked: true)
    expect(b.flag_words).to eq("not backed: edited after the last command ran")
  end

  it "doesn't flag an edit after a command that ran before any edit: it checked nothing of the turn's" do
    search = step("a", "execute", { command: "rg foo" }, "a.rb:1:foo\nexit: 0")
    expect(backing(search, edit("b"), done("c"))).to have_attributes(command: "ok", edited_after_command: false, unbacked: false)
    expect(backing(rspec("a"), edit("b"), done("c"))).to have_attributes(edited_after_command: false, unbacked: false)
  end

  it "flags a done move whose last command failed" do
    b = backing(edit("a"), rspec("b", 1), done("c"))
    expect(b).to have_attributes(command: "failed", unbacked: true)
    expect(b.flag_words).to eq("not backed: the last command failed")
  end

  it "flags nothing with no runs, nor an edit-only turn" do
    expect(backing(done("a"))).to have_attributes(edits: 0, command: nil, edited_after_command: false, unbacked: false)
    expect(backing(edit("a"), done("b"))).to have_attributes(edits: 1, command: nil, unbacked: false)
  end

  it "never flags a progress or blocked move" do
    %w[progress blocked].each do |state|
      expect(backing(rspec("a", 1), edit("b"), done("c", "O1", state)).unbacked).to be(false)
    end
  end

  it "doesn't let a later turn's move inherit an earlier turn's runs" do
    b = backing(rspec("a"), edit("b"), prompt("next"), done("c"))
    expect(b).to have_attributes(edits: 0, command: nil, unbacked: false)
  end

  it "drops a rolled-back turn's runs with its move" do
    kept = [list_note, prompt, *done("a")]
    rolled = [*kept, prompt("bad"), *rspec("b", 1), *done("c")]
    expect(Samagotchi::Objectives.build(rolled).moves.fetch("O1").backing.unbacked).to be(true)
    expect(Samagotchi::Objectives.build(kept).moves.fetch("O1").backing.unbacked).to be(false)
  end

  it "reads a later command over an earlier one, and a later edit's flag goes with a new command" do
    expect(backing(rspec("a", 1), edit("b"), rspec("c"), done("d")))
      .to have_attributes(edits: 1, command: "ok", edited_after_command: false, unbacked: false)
  end

  it "counts no failed, denied or interrupted edit, and no command that didn't finish" do
    runs = [step("a", "edit", { path: "a.rb" }, "Error: old_string not found"),
            step("h", "edit", { path: "a.rb" }, "Error: denied by guardrail (rule x, core): no"),
            step("b", "execute", { command: "rspec" }, "Error: command stopped by the user"),
            step("c", "execute", { command: "rspec" }, "Still running at the 120s limit: moved to a background task, not killed.\nexit: 1"),
            step("d", "execute", { command: "rspec" }, "Error: denied by guardrail (rule x, core): no"),
            step("e", "task_wait", { task_id: "k" }, "task_id: k\nstatus: running\nexit_code: \nwait_result: timeout\noutput_tail:\nstatus: failed"),
            step("f", "task_wait", { task_id: "k" }, "Error: no task k")]
    interrupted = [{ role: "model", content: "", tool_calls: [{ id: "i", name: "write", arguments: { path: "b.rb" } }] },
                   { role: "tool_response", content: Samagotchi::ToolResponse.interrupted_text("write"), tool_call_id: "i", tool_ids: ["ti"] }]
    expect(backing(*runs, interrupted, done("g")))
      .to have_attributes(edits: 0, command: nil, unbacked: false)
  end

  it "reads a task_wait's finished task as the command" do
    failed = step("a", "task_wait", { task_id: "k" }, "task_id: k\nstatus: failed\nexit_code: 1\nwait_result: exited\noutput_tail:\nboom")
    passed = step("b", "task_wait", { task_id: "k" }, "task_id: k\nstatus: completed\nexit_code: 0\noutput_tail:\nstatus: failed")
    expect(backing(edit("x"), failed, done("c")).command).to eq("failed")
    expect(backing(edit("x"), passed, done("c"))).to have_attributes(command: "ok", unbacked: false)
  end

  it "reads a grep that found nothing as a command that passed" do
    expect(backing(step("a", "execute", { command: "grep x a.rb" }, "exit: 1 (no output)"), done("b")).command).to eq("ok")
  end

  it "reads a kernel host's turn too" do
    call = ->(name, params) { "<tool_call>\n<function=#{name}>\n#{params.map { |k, v| "<parameter=#{k}>\n#{v}\n</parameter>\n" }.join}</function>\n</tool_call>" }
    entries = [{ role: "model", content: call.call("execute", command: "rspec") }, { role: "tool_response", content: "[execute]\nexit: 1", tool_ids: ["t1"] },
               { role: "model", content: call.call("objectives", id: "O1", note: "green", state: "done") },
               { role: "tool_response", content: "[objectives]\nRecorded a move on O1.", tool_ids: ["t2"] }]
    expect(backing(entries)).to have_attributes(command: "failed", unbacked: true)
  end

  it "reads runs before the move in its own batch" do
    call = ->(name, params) { "<tool_call>\n<function=#{name}>\n#{params.map { |k, v| "<parameter=#{k}>\n#{v}\n</parameter>\n" }.join}</function>\n</tool_call>" }
    batch = { role: "model", content: "#{call.call("execute", command: "rspec")}\n#{call.call("objectives", id: "O1", note: "n", state: "done")}" }
    results = { role: "tool_response", content: "[execute]\nexit: 1#{Samagotchi::ToolResponse::SEPARATOR}[objectives]\nRecorded a move on O1.",
                tool_ids: %w[t1 t2] }
    expect(backing([batch], [results])).to have_attributes(command: "failed", unbacked: true)
  end

  it "puts the backing in the view and the flag in /objectives' words" do
    built = Samagotchi::Objectives.build([list_note, prompt, *edit("x"), *rspec("a"), *edit("b"), *done("c")])
    expect(built.to_view(pending: false)[:items].first["move"]["backing"])
      .to eq("edits" => 2, "command" => "ok", "edited_after_command" => true, "unbacked" => true)
  end
end
