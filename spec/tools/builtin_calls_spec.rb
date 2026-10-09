# frozen_string_literal: true

require "samagotchi/tools/builtin_calls"
require "samagotchi/tools/builtins"

RSpec.describe Samagotchi::Tools::BuiltinCalls do
  it "has a row for every built-in tool, and only those" do
    classes = Samagotchi::Tools::Builtins::CLASSES + Samagotchi::Tools::Builtins::LAYER_CLASSES
    expect(described_class.rows.keys).to match_array(classes.map { |klass| klass::NAME })
  end

  it "names only real schema properties in its overrides" do
    expect { described_class.rows }.not_to raise_error
    bad = { name: "x", parameters: { properties: { path: {} } } }
    stub_const("#{described_class}::OVERRIDES", { "x" => { verbatim: %w[nope] } })
    expect { described_class.row_for(bad) }.to raise_error(ArgumentError, /nope/)
  end

  it "never lets a property named name replace the call's name" do
    %w[memory_read memory_write register_reminder cancel_reminder].each do |tool|
      expect(described_class.build(tool, { "name" => "n", "scope" => "project" })[:name]).to eq(tool)
    end
  end

  it "puts the main argument in content and the rest in their own fields, nil when absent" do
    expect(described_class.build("execute", { "command" => " ls ", "cwd" => "web" }))
      .to eq(name: "execute", content: "ls", path: nil, scope: nil, description: nil, cwd: "web")
    expect(described_class.build("execute", { "command" => "ls", "description" => " List files " })[:description])
      .to eq("List files")
    expect(described_class.build("read", { "path" => "a.rb" }))
      .to eq(name: "read", content: "a.rb", path: nil, scope: nil, start_line: nil, end_line: nil)
    expect(described_class.build("memory_write", { "name" => "n", "body" => " c ", "scope" => "system" }))
      .to eq(name: "memory_write", content: " c ", path: "n", scope: "system", description: nil, current_model_only: nil,
             remove: nil)
    expect(described_class.build("task_list", {})).to eq(name: "task_list", content: "", path: nil, scope: nil)
  end

  it "tries a property's aliases in order after it" do
    expect(described_class.build("task_wait", { "task_id" => "B", "id" => "A" })[:content]).to eq("A")
    expect(described_class.build("task_wait", { "task_id" => "B" })[:content]).to eq("B")
    expect(described_class.build("write", { "path" => "a", "text" => "t" })[:content]).to eq("t")
  end

  it "keeps verbatim values as given and strips the others" do
    call = described_class.build("task_create", { "command" => " sleep 5 ", "env" => " A=1 ", "cwd" => " web " })
    expect(call).to include(content: "sleep 5", env: " A=1 ", cwd: "web")
    expect(described_class.build("read", { "path" => "a", "start_line" => 3 })[:start_line]).to eq(3)
  end

  it "normalizes ask_user_question's options when they read as options, and keeps them otherwise" do
    expect(described_class.build("ask_user_question", { "question" => "Q?", "options" => '["a","b"]' }))
      .to include(content: "Q?", question: "Q?", options: %w[a b])
    expect(described_class.build("ask_user_question", { "question" => "Q?", "options" => "]" })[:options]).to eq("]")
  end

  it "gives a tool that isn't built in its arguments whole, with their JSON as content whatever the format" do
    args = { "text" => "hi", "times" => 3 }
    json = '{"text":"hi","times":3}'
    expect(described_class.build("echo_args", args, raw: "text:hi,times:3"))
      .to eq(name: "echo_args", content: json, path: nil, scope: nil, args: args)
    expect(described_class.build("echo_args", args)[:content]).to eq(json)
  end

  it "keeps the raw text as content when no argument could be read from it" do
    expect(described_class.build("echo_args", {}, raw: "garbled body")[:content]).to eq("garbled body")
    expect(described_class.build("echo_args", {})[:content]).to eq("{}")
  end

  it "says which are built in and how Gemma's fallback finds the main argument" do
    expect(described_class.row("edit")).not_to be_nil
    expect(described_class.row("echo_args")).to be_nil
    expect(described_class.row("task_wait").fallback_keys).to eq(%w[id task_id])
    expect(described_class.row("list_sessions")).to have_attributes(fallback: :prefix, fallback_keys: %w[cwd])
    expect(described_class.row("ask_user_question").fallback).to eq(:raw)
  end

  describe "the bash → execute alias" do
    it "runs a bash call shaped like execute as execute, remembering the model's spelling" do
      expect(described_class.build("bash", { "command" => "ls", "description" => "list files" }))
        .to eq(name: "execute", content: "ls", path: nil, scope: nil, description: "list files", cwd: nil,
               called_as: "bash")
    end

    it "recognizes the model's spelling case-insensitively" do
      expect(described_class.build("Bash", { "command" => "ls" })[:name]).to eq("execute")
      expect(described_class.build("BASH", { "command" => "ls" })[:called_as]).to eq("BASH")
    end

    it "passes a bash call that isn't execute-shaped through untouched, so it stays an unknown tool" do
      expect(described_class.build("bash", { "cmd" => "ls" }))
        .to eq(name: "bash", content: %({"cmd":"ls"}), path: nil, scope: nil, args: { "cmd" => "ls" })
      expect(described_class.build("bash", { "command" => "ls", "nope" => 1 })[:name]).to eq("bash")
      expect(described_class.build("bash", { "command" => 5 })[:name]).to eq("bash")
    end
  end
end
