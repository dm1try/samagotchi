# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/working_set_own_changes"

# WorkingSet::OwnChanges: chi's latest own change per file, from the
# conversation's paired runs (memory_write by its output, edit and write by
# their FileRef path and stamp).
RSpec.describe Samagotchi::WorkingSet::OwnChanges do
  let(:dir) { Dir.mktmpdir("ws-own") }
  let(:system_dir) { File.join(dir, "memories").tap { |d| FileUtils.mkdir_p(d) } }
  let(:project_dir) { File.join(system_dir, "projects", "app_1").tap { |d| FileUtils.mkdir_p(d) } }
  let(:dirs) { { "project" => project_dir, "system" => system_dir } }
  let(:head) { { role: "system", content: "You are chi." } }

  after { FileUtils.rm_rf(dir) }

  def chat_call(id, name, args) = { id: id, name: name, arguments: args }
  def chat_model(*calls) = { role: "model", content: "", tool_calls: calls }

  def chat_result(id, name, text, tool_id, stamp: nil)
    { role: "tool_response", content: "[#{name}]\n#{text}", tool_call_id: id, tool_ids: [tool_id], tool_stamps: stamp && [stamp] }.compact
  end

  def saved(name, scope, bytes) = "Memory '#{name}' saved to #{scope} scope (#{bytes} bytes). File written: /x/#{name}.md Index line refreshed automatically."

  # One memory_write's call and result.
  def write_turn(id, args, output, tool_id = "t#{id}")
    [chat_model(chat_call(id, "memory_write", args)), chat_result(id, "memory_write", output, tool_id)]
  end

  def stamp_of(path)
    stat = File.stat(path)
    { path: path, mtime_ns: (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec, size: stat.size }
  end

  def of(conversation, cwd: dir) = described_class.of([head, { role: "user", content: "go" }, *conversation], cwd: cwd)

  it "keeps the latest of two writes of a memory, its step and its id" do
    changes = of([*write_turn("c1", { "name" => "style", "content" => "one", "scope" => "system" }, saved("style", "system", 3)),
                  *write_turn("c2", { "name" => "style", "content" => "two", "scope" => "system" }, saved("style", "system", 3))])
    change = changes.memory("system", "style")
    expect(change).to have_attributes(tool_id: "tc2", step: 2, op: "memory_write", content: "two")
    expect(changes.memory("project", "style")).to be_nil
  end

  it "counts no failed, denied or interrupted write" do
    args = { "name" => "style", "content" => "x", "scope" => "system" }
    changes = of([*write_turn("c1", args, "Error: content is required"),
                  *write_turn("c2", args, "Error: denied by the user"),
                  chat_model(chat_call("c3", "memory_write", args)),
                  { role: "tool_response", content: Samagotchi::ToolResponse.interrupted_text("memory_write"), tool_call_id: "c3", tool_ids: ["t3"] }])
    expect(changes).to be_empty
  end

  it "counts no description-only write, no index write, and no remove of a file already gone" do
    changes = of([*write_turn("c1", { "name" => "style", "description" => "d", "scope" => "system" },
                              "Memory 'style' description updated in system scope (file unchanged). Index line refreshed."),
                  *write_turn("c2", { "name" => "index", "content" => "- x", "scope" => "system" }, saved("index", "system", 3)),
                  *write_turn("c3", { "name" => "old", "remove" => true, "scope" => "system" },
                              "Memory 'old' had no file in system scope; its dangling index line was dropped.")])
    expect(changes).to be_empty
  end

  it "takes a remove that says removed from, and an overlay's key off its output (never the arguments)" do
    changes = of([*write_turn("c1", { "name" => "old", "remove" => true, "scope" => "system" },
                              "Memory 'old' removed from system scope: moved to /trash (`chi bundle trash` lists and empties it)."),
                  *write_turn("c2", { "name" => "style", "content" => "o", "scope" => "project", "current_model_only" => true },
                              "Model overlay 'style' for qwen3 saved to project scope (1 bytes). File written: /x/style.qwen3.md")])
    expect(changes.memory("system", "old")).to have_attributes(op: "remove", content: nil)
    expect(changes.memory("project", "style", key: "qwen3")).to have_attributes(op: "memory_write", content: "o")
    expect(changes.memory("project", "style")).to be_nil
  end

  it "counts a call_tool-wrapped memory_write, never a corrected one (ran as:)" do
    wrapped = [chat_model(chat_call("c1", "call_tool", { "tool" => "chi/memory_write",
                                                         "args" => { "name" => "style", "content" => "w", "scope" => "system" } })),
               chat_result("c1", "memory_write", saved("style", "system", 1), "t1")]
    expect(of(wrapped).memory("system", "style")).to have_attributes(content: "w")
    corrected = [chat_model(chat_call("c1", "memory_write", { "name" => "style", "content" => "w", "scope" => "system" })),
                 { role: "tool_response", content: "ran as: memory_write\n[memory_write]\n#{saved("style", "system", 1)}",
                   tool_call_id: "c1", tool_ids: ["t1"] }]
    expect(of(corrected)).to be_empty
  end

  it "maps a Locator file to its scope by the folder it sits in (a project's folder is inside the system one)" do
    project_file = File.join(project_dir, "style.md")
    changes = of([*write_turn("c1", { "name" => "style", "content" => "p", "scope" => "project" }, saved("style", "project", 1))])
    expect(changes.for_file(project_file, role: :base, dirs: dirs)).to have_attributes(content: "p")
    expect(changes.for_file(File.join(system_dir, "style.md"), role: :base, dirs: dirs)).to be_nil

    overlay = of([*write_turn("c1", { "name" => "style", "content" => "o", "scope" => "system", "current_model_only" => true },
                              "Model overlay 'style' for m saved to system scope (1 bytes). File written: /x")])
    expect(overlay.for_file(File.join(system_dir, "style.m.md"), role: :overlay, key: "m", dirs: dirs)).to have_attributes(content: "o")
    expect(overlay.for_file(File.join(system_dir, "style.md"), role: :base, dirs: dirs)).to be_nil
  end

  it "finds an edit of a file however its path is spelled (a symlinked folder), and the later of an edit and a memory_write" do
    real = File.join(dir, "real").tap { |d| FileUtils.mkdir_p(d) }
    link = File.join(dir, "link").tap { |l| File.symlink(real, l) }
    agents = File.join(real, "AGENTS.md").tap { |p| File.write(p, "Rules.\n") }
    conversation = [chat_model(chat_call("c1", "edit", { "path" => "AGENTS.md", "old_text" => "R", "new_text" => "r" })),
                    chat_result("c1", "edit", "Edited AGENTS.md", "t1", stamp: stamp_of(agents))]
    expect(of(conversation, cwd: link).for_file(agents, role: :base)).to have_attributes(op: "edit", tool_id: "t1")

    style = File.join(system_dir, "style.md").tap { |p| File.write(p, "x\n") }
    both = of([*write_turn("c1", { "name" => "style", "content" => "x\n", "scope" => "system" }, saved("style", "system", 2)),
               chat_model(chat_call("c2", "edit", { "path" => style, "old_text" => "x", "new_text" => "y" })),
               chat_result("c2", "edit", "Edited", "t2", stamp: stamp_of(style))])
    expect(both.for_file(style, role: :base, dirs: dirs)).to have_attributes(op: "edit")
  end

  it "says current per op: a write's content, a remove's absence, an edit's stamp" do
    style = File.join(system_dir, "style.md").tap { |p| File.write(p, "be brief\n") }
    changes = of([*write_turn("c1", { "name" => "style", "content" => "be brief\n", "scope" => "system" }, saved("style", "system", 9)),
                  *write_turn("c2", { "name" => "old", "remove" => true, "scope" => "system" }, "Memory 'old' removed from system scope: moved.")])
    write = changes.memory("system", "style")
    expect(changes.current?(write, style)).to be(true)
    File.write(style, "be terse\n")
    expect(changes.current?(write, style)).to be(false)
    File.delete(style)
    expect(changes.current?(write, style)).to be(false)

    old = File.join(system_dir, "old.md")
    expect(changes.current?(changes.memory("system", "old"), old)).to be(true)
    File.write(old, "back\n")
    expect(changes.current?(changes.memory("system", "old"), old)).to be(false)

    agents = File.join(dir, "AGENTS.md").tap { |p| File.write(p, "Rules.\n") }
    edited = of([chat_model(chat_call("c1", "edit", { "path" => agents, "old_text" => "R", "new_text" => "r" })),
                 chat_result("c1", "edit", "Edited", "t1", stamp: stamp_of(agents))]).file(agents)
    expect(changes.current?(edited, agents)).to be(true)
    File.write(agents, "Rules, and more.\n") # a size change: coarse timestamps can't hide it
    expect(changes.current?(edited, agents)).to be(false)
  end

  it "undoes chi's exact edits newest first back to a text (undoes_to?); a range edit, an empty new_text or a write stops it" do
    agents = File.join(dir, "AGENTS.md").tap { |p| File.write(p, "x") }
    edit = ->(id, args) { [chat_model(chat_call(id, "edit", { "path" => agents }.merge(args))), chat_result(id, "edit", "Edited", "t#{id}", stamp: stamp_of(agents))] }
    history = of([*edit.call("c1", { "old_text" => "beta", "new_text" => "beta, gamma" }),
                  *edit.call("c2", { "old_text" => "alpha", "new_text" => "alpha, delta" })]).file_history(agents)
    expect(history.map(&:tool_id)).to eq(%w[tc1 tc2])
    now = "alpha, delta\nbeta, gamma\n"
    expect(described_class.undoes_to?(now, "alpha\nbeta\n", history)).to be(true)
    expect(described_class.undoes_to?(now, "alpha, yours\nbeta\n", history)).to be(false)
    range = of(edit.call("c1", { "new_text" => "z", "start_line" => 1, "end_line" => 2 })).file_history(agents)
    expect(described_class.undoes_to?("z", "alpha", range)).to be(false)
    emptied = of(edit.call("c1", { "old_text" => "beta", "new_text" => "" })).file_history(agents)
    expect(described_class.undoes_to?("alpha\n", "alpha\nbeta\n", emptied)).to be(false)
  end

  it "gives from_runs (the runs WorkingSet.build already has) of's answer" do
    conversation = [head, *write_turn("c1", { "name" => "style", "content" => "a", "scope" => "system" }, saved("style", "system", 1))]
    runs = Samagotchi::LLMContextStale.paired_runs(conversation)
    from = described_class.from_runs(runs, conversation, cwd: dir)
    expect(from.memory("system", "style")).to eq(described_class.of(conversation, cwd: dir).memory("system", "style"))
  end
end
