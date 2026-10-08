# frozen_string_literal: true

require "samagotchi/model_notes"
require "samagotchi/model_overlay"
require "tmpdir"

RSpec.describe Samagotchi::ModelNotes do
  let(:tmp) { Dir.mktmpdir("model-notes") }
  let(:system_dir) { Samagotchi::Tools::MemoryRead.memories_dir("system") }
  let(:project_dir) { Samagotchi::Tools::MemoryRead.memories_dir("project") }

  around do |example|
    with_config_home(File.join(tmp, "config")) do
      with_env("XDG_STATE_HOME" => File.join(tmp, "state")) { example.run }
    end
  end

  after { FileUtils.remove_entry(tmp) }

  before { described_class.reset_warnings! }

  def write(dir, name, text)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{name}.md"), text)
  end

  def notes(name, small: -> { false }, muted: [], fallback_key: nil)
    described_class.for(name: name, key: Samagotchi::ModelOverlay.key_for(name), muted: muted, small: small,
                        fallback_key: fallback_key)
  end

  def names(...) = notes(...).map(&:name)

  it "loads a note whose models: glob matches the bare name or the key, without its models: line" do
    write(system_dir, "model_notes_deepseek", "models: deepseek/*\nExplore briefly.\n")
    write(system_dir, "model_notes_keyed", "models: *-v4-1-*\nKeyed.\n")
    write(system_dir, "model_notes_gemma", "models: gemma-*\nGemma.\n")

    list = notes("deepseek/deepseek-v4.1-flash")
    expect(list.map(&:name)).to eq(%w[model_notes_deepseek model_notes_keyed])
    note = list.first
    expect(note.scope).to eq("system")
    expect(note.body).to eq("Explore briefly.")
    expect(note.chars).to eq(16)
    expect(note.digest).to match(/\A\h{12}\z/)
  end

  it "takes |-separated entries and small (asked only for a small entry, once)" do
    write(system_dir, "model_notes_a", "models: gemma-*|small\nA.\n")
    write(system_dir, "model_notes_b", "models: small\nB.\n")
    calls = 0
    small = lambda {
      calls += 1
      true
    }
    expect(names("qwen3.6-27b", small: small)).to eq(%w[model_notes_a model_notes_b])
    expect(calls).to eq(1)
    expect(names("qwen3.6-27b", small: -> { false })).to eq([])
  end

  it "defaults small to guardrails.small_models" do
    write(system_dir, "model_notes_small", "models: small\nSmall.\n")
    allow(Samagotchi::Config).to receive(:get).and_call_original
    allow(Samagotchi::Config).to receive(:get).with("guardrails.small_models").and_return("auto")
    expect(described_class.for(name: "Qwen3-8B", key: "qwen3-8b").map(&:name)).to eq(%w[model_notes_small])
    expect(described_class.for(name: "Llama-3.3-70B", key: "llama-3-3-70b")).to eq([])
  end

  it "stacks every match: the system scope, then the project's, by name within a scope" do
    write(project_dir, "model_notes_a", "models: *\nProject A.\n")
    write(system_dir, "model_notes_b", "models: *\nSystem B.\n")
    write(system_dir, "model_notes_a", "models: *\nSystem A.\n")
    list = notes("m")
    expect(list.map { |n| [n.scope, n.name] }).to eq([%w[system model_notes_a], %w[system model_notes_b],
                                                      %w[project model_notes_a]])
    expect(list.last.body).to eq("Project A.")
  end

  it "loads only files whose name starts with model_notes_ as written (a case-insensitive disk globs MODEL_NOTES_x.md too)" do
    write(system_dir, "MODEL_NOTES_upper", "models: *\nUpper.\n")
    write(system_dir, "Model_notes_mixed", "models: *\nMixed.\n")
    write(system_dir, "model_notes_lower", "models: *\nLower.\n")
    expect(names("m")).to eq(%w[model_notes_lower])
    text = "- **model_notes_upper** · 9 B\n- **model_notes_lower** · 9 B\n"
    expect(described_class.filter_index(text, "system")).to eq("- **model_notes_upper** · 9 B\n")
  end

  it "matches nothing without a model name" do
    write(system_dir, "model_notes_all", "models: *\nAll.\n")
    expect(described_class.for(name: nil, key: nil)).to eq([])
  end

  it "leaves out a muted note" do
    write(system_dir, "model_notes_a", "models: *\nA.\n")
    write(system_dir, "model_notes_b", "models: *\nB.\n")
    expect(names("m", muted: ["model_notes_a"])).to eq(%w[model_notes_b])
  end

  it "skips a note without a valid models: first line, warning once naming the file" do
    write(system_dir, "model_notes_bad", "Explore briefly.\nmodels: *\n")
    write(system_dir, "model_notes_empty", "models:  | \nNothing.\n")
    expect(Samagotchi::Log).to receive(:warn).with(:memory, "model_note_skipped", hash_including(echo: /model_notes_bad\.md/)).once
    expect(Samagotchi::Log).to receive(:warn).with(:memory, "model_note_skipped", hash_including(echo: /model_notes_empty\.md/)).once
    expect(names("m")).to eq([])
    expect(names("m")).to eq([])
  end

  it "appends the note's model overlay (memory_read's), never loading the overlay file as a note" do
    write(system_dir, "model_notes_a", "models: *\nA.\n")
    write(system_dir, "model_notes_a.m", "Overlay for m.\n")
    write(system_dir, "model_notes_a.other", "Overlay for other.\n")
    list = notes("m")
    expect(list.map(&:name)).to eq(%w[model_notes_a])
    expect(list.first.body).to include("A.", "Model-specific guidance (m):", "Overlay for m.")
    expect(list.first.body).not_to include("Overlay for other.")
  end

  it "reads the fallback key's overlay when the key has none" do
    write(system_dir, "model_notes_a", "models: *\nA.\n")
    write(system_dir, "model_notes_a.typed", "Typed overlay.\n")
    expect(notes("m", fallback_key: "typed").first.body).to include("Typed overlay.")
  end

  it "reads a note's overlay from the env it is given, not the process's (chi self)" do
    other = File.join(tmp, "other")
    other_system = File.join(other, "samagotchi", "memories")
    write(system_dir, "model_notes_a", "models: *\nA.\n")
    write(system_dir, "model_notes_a.m", "Overlay from the process ENV.\n")
    write(other_system, "model_notes_a", "models: *\nA.\n")
    write(other_system, "model_notes_a.m", "Overlay from the given env.\n")

    list = described_class.for(name: "m", key: "m", env: { "XDG_CONFIG_HOME" => other }, warn: false)

    expect(list.map(&:name)).to eq(%w[model_notes_a])
    expect(list.first.body).to include("Overlay from the given env.")
    expect(list.first.body).not_to include("Overlay from the process ENV.")
  end

  it "skips a dotted name that isn't an overlay, with a warning" do
    write(system_dir, "model_notes_qwen3.6", "models: *\nDotted.\n")
    expect(Samagotchi::Log).to receive(:warn).with(:memory, "model_note_skipped", hash_including(echo: /model_notes_qwen3\.6\.md.*dot/))
    expect(names("m")).to eq([])
  end

  it "warns once when a note or all the notes are large, and still loads them" do
    write(system_dir, "model_notes_a", "models: *\n#{"a" * 1_600}\n")
    write(system_dir, "model_notes_b", "models: *\n#{"b" * 1_500}\n")
    expect(Samagotchi::Log).to receive(:warn).with(:memory, "model_notes_large", hash_including(echo: /model_notes_a.*1600/)).once
    expect(Samagotchi::Log).to receive(:warn).with(:memory, "model_notes_large", hash_including(echo: /3100/)).once
    expect(names("m")).to eq(%w[model_notes_a model_notes_b])
    expect(names("m")).to eq(%w[model_notes_a model_notes_b])
  end

  it "gives no size warning with warn: false (a read-only report)" do
    write(system_dir, "model_notes_a", "models: *\n#{"a" * 3_100}\n")
    expect(Samagotchi::Log).not_to receive(:warn)
    expect(described_class.for(name: "m", key: "m", warn: false).map(&:name)).to eq(%w[model_notes_a])
  end

  describe ".filter_index" do
    it "drops the lines of the notes that load and keeps every other byte" do
      write(system_dir, "model_notes_deepseek", "models: deepseek-*\nDeepSeek.\n")
      write(system_dir, "model_notes_bare", "models: *\nBare.\n")
      write(system_dir, "model_notes_x", "models: *\nX.\n")
      write(system_dir, "model_notes_x.m", "Overlay.\n")
      text = "# Index\n- **tips** · 10 B · 2026-10-08 · tips\n- **model_notes_deepseek** · 40 B · 2026-10-08 · DeepSeek\n" \
             "model_notes_bare\nmodel_notes_x.m\n- **identity** · 9 B\n"
      expect(described_class.filter_index(text, "system"))
        .to eq("# Index\n- **tips** · 10 B · 2026-10-08 · tips\nmodel_notes_x.m\n- **identity** · 9 B\n")
    end

    it "keeps the line of a model_notes_ memory without a models: line, or without a file in that scope" do
      write(system_dir, "model_notes_todo", "my plain notes\n")
      write(project_dir, "model_notes_elsewhere", "models: *\nElsewhere.\n")
      text = "- **model_notes_todo** · 15 B · todo list\n- **model_notes_elsewhere** · 20 B\n"
      expect(described_class.filter_index(text, "system")).to eq(text)
      expect(described_class.filter_index("- **model_notes_elsewhere** · 20 B\n", "project")).to eq("")
    end

    it "leaves a text without model notes as it is" do
      text = "No memories stored yet."
      expect(described_class.filter_index(text, "system")).to equal(text)
      expect(described_class.filter_index(nil, "system")).to be_nil
    end
  end

  it "takes a models: line after a BOM, in any case" do
    write(system_dir, "model_notes_bom", "\uFEFFModels: m\nBOM.\n")
    write(system_dir, "model_notes_upper", "MODELS: m\nUpper.\n")
    expect(notes("m").map(&:body)).to eq(%w[BOM. Upper.])
  end

  it "reads a note with a comma in its name from its own file, not as a list of names" do
    write(system_dir, "b", "IDENTITY TEXT\nline2\n")
    write(system_dir, "model_notes_a,b", "models: *\nREAL\n")
    list = notes("m")
    expect(list.map(&:name)).to eq(["model_notes_a,b"])
    expect(list.first.body).to eq("REAL")
  end
end
