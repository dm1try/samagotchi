# frozen_string_literal: true

require "spec_helper"
require "samagotchi/tool_view"

RSpec.describe Samagotchi::ToolView do
  let(:command) { "cd /p/app && rg -n foo lib |\n  head -20" }

  it "carries an execute's full command, whitespace kept, and its steps" do
    view = described_class.for("execute", { name: "execute", content: command })

    expect(view.to_h).to eq(command: command, cd: "/p/app", steps: [{ text: "rg -n foo lib", limit: "head 20" }])
  end

  it "has no steps for a command CommandSteps can't read (the fallback) or a cut one" do
    loop = "for f in *; do echo $f; done"
    expect(described_class.for("execute", { name: "execute", content: loop }).to_h).to eq(command: loop)
    cut = described_class.for("execute", { name: "execute", content: "ls && #{"x" * described_class::COMMAND_LIMIT}" })
    expect(cut.to_h.keys).to eq(%i[command truncated chars])
  end

  it "carries the model's description, tidied, and nothing for a blank one" do
    call = { name: "execute", content: "ls", description: "  List the\n files.  " }
    expect(described_class.for("execute", call).to_h).to eq(command: "ls", steps: [{ text: "ls" }], description: "List the files")
    expect(described_class.for("execute", call.merge(description: " ")).to_h).not_to have_key(:description)
    expect(described_class.for("execute", call.merge(description: 3)).to_h).not_to have_key(:description)
    expect(described_class.description({ description: "Wait for it..." })).to eq("Wait for it...")
    expect(described_class.description({ description: "x" * 400 }).length).to eq(described_class::DESCRIPTION_LIMIT)
  end

  it "cuts a description to a title at a word, whole when it fits" do
    short = "Count TODO and FIXME in the top 5 files"
    expect(described_class.description_title({ description: "#{short}." })).to eq(short)
    long = "Find the 3 largest top-level directories (excluding .git and node_modules) using find."
    expect(described_class.description_title({ description: long })).to eq("Find the 3 largest top-level directories (excluding .git…")
    expect(described_class.description_title({ description: "y" * 70 })).to eq("#{"y" * 59}…")
    expect(described_class.description_title({})).to be_nil
  end

  it "carries a task_create's command and its cwd" do
    view = described_class.for("task_create", { name: "task_create", content: "npm test", cwd: " web ", env: "A=1" })

    expect(view.to_h).to eq(command: "npm test", cwd: "web", steps: [{ text: "npm test" }])
  end

  it "carries an execute's cwd argument" do
    expect(described_class.for("execute", { name: "execute", content: "ls", cwd: "lib" }).to_h)
      .to eq(command: "ls", cwd: "lib", steps: [{ text: "ls" }])
  end

  it "cuts a command past the limit and says how long it was" do
    long = "x" * (described_class::COMMAND_LIMIT + 5)
    view = described_class.for("execute", { name: "execute", content: long })

    expect(view.command.length).to eq(described_class::COMMAND_LIMIT)
    expect(view.to_h).to include(truncated: true, chars: described_class::COMMAND_LIMIT + 5)
  end

  it "keeps a command exactly at the limit whole" do
    exact = "x" * described_class::COMMAND_LIMIT
    expect(described_class.for("execute", { name: "execute", content: exact }).to_h).to eq(command: exact, steps: [{ text: exact }])
  end

  it "has no view for the other tools" do
    %w[read write edit memory_read task_get web_fetch jira_search].each do |tool|
      expect(described_class.for(tool, { name: tool, content: "x", path: "a.rb" })).to be_nil
    end
  end

  it "carries a task_wait's task id (the web's stop-task button), and nothing for a blank one" do
    expect(described_class.for("task_wait", { name: "task_wait", content: " 20261004120000-0a1b2c3d " }).to_h)
      .to eq(task_id: "20261004120000-0a1b2c3d")
    expect(described_class.for("task_wait", { name: "task_wait", content: " " })).to be_nil
  end

  it "has no view for an empty command" do
    expect(described_class.for("execute", { name: "execute", content: " \n " })).to be_nil
    expect(described_class.for("execute", { name: "execute" })).to be_nil
    expect(described_class.for("execute", nil)).to be_nil
  end
end
