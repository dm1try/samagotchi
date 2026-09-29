# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "tmpdir"

# Byte-for-byte snapshots of the whole system prompt Engine#system_prompt
# builds (the base prompt that prompt_snapshot_spec pins, plus the thinking
# token, rg guidance, AGENT.md, location, session, memory indexes, identity
# and preloaded memories) across the variants that change it: native vs chat
# host, thinking default vs off, rg or not, a delegated child, preloaded and
# muted memories, a scratch session. Machine-specific paths and ids are
# replaced with placeholders.
#
# Regenerate after an intended change with:
#   UPDATE_PROMPTS=1 bundle exec rspec spec/system_prompt_full_spec.rb
RSpec.describe "Full system prompt snapshots" do
  def fixture_dir = File.expand_path("fixtures/system_prompt_full", __dir__)

  def expect_snapshot(name, actual)
    path = File.join(fixture_dir, name)
    if ENV["UPDATE_PROMPTS"] == "1"
      FileUtils.mkdir_p(fixture_dir)
      File.write(path, actual)
    end
    expect(actual).to eq(File.read(path))
  end

  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: {
      "box" => { host: "box.test", port: 8080 },
      "oai" => { host: "oai.test", port: 8000, api: :openai }
    })
  end

  let(:config_memories) { [] }
  let(:warnings) { [] }

  around do |example|
    saved = %w[SAMAGOTCHI_THINKING_LEVEL SAMAGOTCHI_SKIP_AGENT_MD PATH].to_h { |k| [k, ENV[k]] }
    Dir.mktmpdir do |tmp|
      @tmp = File.realpath(tmp)
      @project = File.join(@tmp, "project")
      FileUtils.mkdir_p(@project)
      File.write(File.join(@project, "AGENT.md"), "This project builds widgets.\n")
      @bin = File.join(@tmp, "bin")
      FileUtils.mkdir_p(@bin)
      File.write(File.join(@bin, "rg"), "#!/bin/sh\n")
      File.chmod(0o755, File.join(@bin, "rg"))
      Dir.chdir(@project) { example.run }
    ensure
      saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end
  end

  before do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories) { config_memories }
    allow(Samagotchi::Tools::MemoryRead).to receive(:memories_dir).and_call_original
    allow(Samagotchi::Tools::MemoryRead).to receive(:memories_dir).with("project")
      .and_return(File.join(Dir.home, ".config", "samagotchi", "memories", "projects", "project_abc"))
    allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil|
      case name.to_s
      when ""
        "# #{scope} index\n- **cfg_note** · #{scope} · 2026-09-01\n- **hidden** · #{scope} · 2026-09-02\nhidden\n"
      when "identity" then "I am chi's identity."
      when /gone/ then "Error: memory '#{name}' not found"
      else "BODY-#{name} (#{scope.inspect})"
      end
    end
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    allow(Samagotchi::Log).to receive(:warn).with(:memory, anything, anything) { |_, what, **f| warnings << [what, f[:echo]] }
  end

  def with_rg(on)
    ENV["PATH"] = on ? "#{@bin}:/usr/bin:/bin" : "/usr/bin:/bin"
  end

  def engine(model, profile, **opts)
    Samagotchi::Engine.new(mode: :assist, host_registry: registry, model_name: model, profile: profile, **opts)
  end

  def session(parent_id: nil)
    s = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    s.parent_id = parent_id if parent_id
    s
  end

  # Placeholders for what differs per machine and run.
  def normalized(prompt, sess = nil)
    text = prompt.dup
    text = text.gsub(sess.id, "<SID>").gsub(sess.id[0, Samagotchi::Log::SID_LENGTH], "<SHORT_SID>") if sess
    text.gsub(SPEC_XDG_STATE_HOME, "<STATE>").gsub(@tmp, "<TMP>").gsub(Dir.home, "<HOME>")
  end

  it "gemma4 on a native host, default thinking, rg, AGENT.md, no session" do
    with_rg(true)
    expect_snapshot("gemma4_native.txt", normalized(engine("box:gemma-small", "gemma4").system_prompt))
  end

  it "gemma4 on a native host, thinking off, no rg, AGENT.md skipped" do
    with_rg(false)
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    ENV["SAMAGOTCHI_SKIP_AGENT_MD"] = "1"
    expect_snapshot("gemma4_native_off.txt", normalized(engine("box:gemma-small", "gemma4").system_prompt))
  end

  it "qwen36 on a native host, default thinking, with a session" do
    with_rg(true)
    e = engine("box:qwen-small", "qwen36")
    s = session
    e.session = s
    expect_snapshot("qwen36_native_session.txt", normalized(e.system_prompt, s))
  end

  it "qwen36 on a native host, thinking off" do
    with_rg(false)
    ENV["SAMAGOTCHI_THINKING_LEVEL"] = "off"
    expect_snapshot("qwen36_native_off.txt", normalized(engine("box:qwen-small", "qwen36").system_prompt))
  end

  it "qwen36 on a chat host, a delegated child session" do
    with_rg(true)
    e = engine("oai:m", "qwen36")
    s = session(parent_id: "parent-1234")
    e.session = s
    expect_snapshot("qwen36_chat_delegated.txt", normalized(e.system_prompt, s))
  end

  context "with preloaded memories" do
    let(:config_memories) { %w[cfg_note gone_config] }

    it "injects config + --memory preloads, skips a missing one with a warning" do
      with_rg(false)
      e = engine("box:gemma-small", "gemma4", memories: ["cli_note, system/sys_note", "cfg_note", "gone_cli"])
      expect(e.preloaded_memory_names).to eq(%w[cfg_note gone_config cli_note sys_note gone_cli])

      expect_snapshot("gemma4_preloaded.txt", normalized(e.system_prompt))
      expect(e.activated_memory_names).to eq(%w[cfg_note cli_note sys_note])
      expect(warnings).to eq([
        ["preload_failed", "Warning: memory 'gone_config' (from config memories:) could not be loaded (Error: memory 'gone_config' not found)"],
        ["preload_failed", "Warning: --memory 'gone_cli' could not be loaded (Error: memory 'gone_cli' not found)"]
      ])
    end

    it "leaves out muted memories: index lines, identity, a muted preload" do
      with_rg(false)
      e = engine("box:gemma-small", "gemma4", memories: ["cli_note"], muted_memories: %w[hidden identity cfg_note])
      expect(e.preloaded_memory_names).to eq(%w[gone_config cli_note])
      expect(warnings).to include(["preload_muted", "Warning: preloaded memory 'cfg_note' is muted for this session"])

      expect_snapshot("gemma4_muted.txt", normalized(e.system_prompt))
      expect(e.activated_memory_names).to eq(%w[cli_note])
    end
  end

  it "a scratch session (no delegate tools)" do
    with_rg(true)
    e = engine("box:gemma-small", "gemma4", scratch: true)
    s = session
    e.session = s
    expect_snapshot("gemma4_scratch.txt", normalized(e.system_prompt, s))
  end

  it "builds each loop's prompt once, and again after tools change" do
    with_rg(false)
    e = engine("box:gemma-small", "gemma4", memories: ["cli_note"])
    first = e.system_prompt
    expect(e.system_prompt).to equal(first)
    e.send(:tools_changed!)
    expect(e.system_prompt).to eq(first)
    expect(e.system_prompt).not_to equal(first)
    # Each build records the preload again (add_used_memory_names dedups).
    expect(e.activated_memory_names).to eq(%w[cli_note cli_note])
  end
end
