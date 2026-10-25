# frozen_string_literal: true

require "samagotchi/hooks/loader"
require "samagotchi/memory_paths"
require "samagotchi/paths"
require "samagotchi/system_one/self_protect"

# System 1 may never answer for a call that changes chi itself: config.yml,
# the hooks dir, the installed bundles, the guardrails store (approvals.json,
# judgments.jsonl), and the rules through which an agent answers chi's own
# questions. The memories dir is not one of them: reading and appending a
# memory file stays eligible (docs/guardrails.md, "System 1").
RSpec.describe Samagotchi::SystemOne::SelfProtect do
  S = described_class

  def config_path = Samagotchi::ConfigFile.global_path
  def hooks_dir = Samagotchi::Hooks::Loader.hooks_dir
  def bundles_dir = Samagotchi::MemoryPaths.bundles_dir
  def store_dir = File.join(Samagotchi::Paths.state_dir, "guardrails")
  def memories_dir = Samagotchi::MemoryPaths.system_dir

  it "refuses an edit or write of config.yml" do
    expect(S.refuse?({ "tool" => "edit", "paths" => [config_path] })).to be true
    expect(S.refuse?({ "tool" => "write", "paths" => [config_path] })).to be true
    expect(S.refuse?({ "tool" => "write", "paths" => [config_path, "notes.md"] })).to be true
  end

  it "refuses anything under the hooks dir, the bundles dir or the guardrails store" do
    expect(S.refuse?({ "tool" => "write", "paths" => [File.join(hooks_dir, "before_tool_call.rb")] })).to be true
    expect(S.refuse?({ "tool" => "write", "paths" => [File.join(bundles_dir, "guardrails", "rules.yml")] })).to be true
    expect(S.refuse?({ "tool" => "edit", "paths" => [File.join(store_dir, "approvals.json")] })).to be true
    expect(S.refuse?({ "tool" => "write", "paths" => [File.join(store_dir, "judgments.jsonl")] })).to be true
  end

  it "refuses a command that names one of those paths" do
    expect(S.refuse?({ "tool" => "execute", "command" => "cat #{store_dir}/judgments.jsonl" })).to be true
    expect(S.refuse?({ "tool" => "task_create", "command" => "sed -i 's/x/y/' #{hooks_dir}/hook.rb" })).to be true
    expect(S.refuse?({ "tool" => "execute", "command" => "rm #{config_path}" })).to be true
    expect(S.refuse?({ "tool" => "execute", "command" => "echo #{bundles_dir}/guardrails/rules.yml" })).to be true
  end

  it "refuses the `~` spelling of chi's config file, not only the resolved one" do
    expect(S.refuse?({ "tool" => "execute", "command" => "cat ~/.config/samagotchi/config.yml" })).to be true
    expect(S.refuse?({ "tool" => "execute", "command" => "cp ~/.config/samagotchi/hooks/x.rb /tmp" })).to be true
  end

  it "leaves the memories dir alone: a memory file is not a control file" do
    memory = File.join(memories_dir, "notes.md")
    expect(S.refuse?({ "tool" => "memory_write", "paths" => [memory] })).to be false
    expect(S.refuse?({ "tool" => "execute", "command" => "cat ~/.config/samagotchi/memories/notes.md" })).to be false
    expect(S.refuse?({ "tool" => "edit", "paths" => [File.join(memories_dir, "projects", "a_1234", "index.md")] })).to be false
  end

  it "allows a call on an ordinary repo file" do
    expect(S.refuse?({ "tool" => "edit", "paths" => [File.join(Dir.pwd, "lib", "samagotchi", "config.rb")] })).to be false
    expect(S.refuse?({ "tool" => "execute", "command" => "git push origin main" })).to be false
    expect(S.refuse?({ "tool" => "execute", "command" => "rg samagotchi lib" })).to be false
  end

  it "refuses the rules that answer chi's own questions, however the user lists them" do
    %w[chi-answer-piped chi-answer-http chi-broadcast].each do |rule|
      expect(S.refuse?({ "tool" => "execute", "command" => "chi answer #{rule}", "rule" => rule })).to be true
    end
  end

  it "says nothing about an ask with no facts" do
    expect(S.refuse?({})).to be false
    expect(S.refuse?(nil)).to be false
  end
end
