# frozen_string_literal: true

require "samagotchi/system_prompt"
require "samagotchi/prompt_part"
require "samagotchi/model_profile"
require "samagotchi/tools/registry"
require "tmpdir"

RSpec.describe Samagotchi::PromptPart do
  it "round-trips through the file's record and drops what has no kind" do
    part = described_class.build(kind: :notes, label: "model_notes_a", ref: "model_notes_a", chars: 41)
    expect(part.tokens).to eq(11)
    expect(described_class.from_h(part.to_file)).to eq(part)
    expect(described_class.from_h(part.to_h)).to eq(part)
    expect(described_class.list([part.to_file, { "label" => "x" }, nil, "junk"])).to eq([part])
  end

  it "round-trips its scope, and leaves the key out without one (an older chi's record reads as before)" do
    scoped = described_class.build(kind: :preloads, label: "x", ref: "x", chars: 8, scope: "project")
    expect(scoped.to_file).to include("scope" => "project")
    expect(described_class.from_h(scoped.to_file)).to eq(scoped)
    expect(described_class.from_h(scoped.to_h)).to eq(scoped)
    bare = described_class.build(kind: :base, label: "base prompt", chars: 8)
    expect(bare.scope).to be_nil
    expect(bare.to_h).not_to have_key(:scope)
    expect(bare.to_file.keys).to eq(%w[kind label chars tokens ref])
    old = described_class.from_h({ "kind" => "notes", "label" => "x", "chars" => 8, "tokens" => 2, "ref" => "x" })
    expect(old.scope).to be_nil
    expect(old.to_file).to eq({ "kind" => "notes", "label" => "x", "chars" => 8, "tokens" => 2, "ref" => "x" })
  end
end

RSpec.describe Samagotchi::PromptPart, "place fields and keys" do
  it "round-trips at, len, lead, digest, head and params, and leaves out the ones it has none of" do
    part = described_class.build(kind: :preloads, label: "x", ref: "x", chars: 8, at: 10, len: 12, lead: 4, digest: "abc123abc123",
                                 head: "0123456789abcdef", params: { requested_scope: nil, project_dir: "/m/p" })
    expect(part.params).to eq({ requested_scope: nil, project_dir: "/m/p" })
    file = JSON.parse(JSON.generate(part.to_file))
    expect(file).to include("at" => 10, "len" => 12, "lead" => 4, "digest" => "abc123abc123", "head" => "0123456789abcdef",
                            "params" => { "requested_scope" => nil, "project_dir" => "/m/p" })
    again = described_class.from_h(file)
    expect(again.to_file).to eq(file)
    expect(described_class.build(kind: :base, label: "base prompt", chars: 8).to_file.keys).to eq(%w[kind label chars tokens ref])
    # Junk in a hand-edited file reads as none.
    junk = described_class.from_h(file.merge("at" => "10", "params" => "x"))
    expect([junk.at, junk.params]).to eq([nil, nil])
  end

  it "keys each part from the parts list alone, as the page does (spec/shared/prompt_part_keys.json)" do
    fixture = JSON.parse(File.read(File.expand_path("shared/prompt_part_keys.json", __dir__)))
    expect(described_class.keys(fixture["parts"])).to eq(fixture["keys"])
  end
end

RSpec.describe Samagotchi::SystemPrompt, "#prompt_parts" do
  around do |example|
    Dir.mktmpdir do |tmp|
      @project = File.join(File.realpath(tmp), "project")
      FileUtils.mkdir_p(@project)
      File.write(File.join(@project, "AGENTS.md"), "This project builds widgets.\n")
      File.write(File.join(@project, "extra.md"), "Extra rules.\n")
      Dir.chdir(@project) { example.run }
    end
  end

  let(:identity_text) { "I am chi's identity." }
  let(:muted) { [] }

  before do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    allow(Samagotchi::ConfigFile).to receive(:appended_prompt_files).and_return(["extra.md"])
    allow(Samagotchi::BundleNeeds).to receive(:found?).and_call_original
    allow(Samagotchi::BundleNeeds).to receive(:found?).with("rg").and_return(true)
    allow(Samagotchi::LogPath).to receive(:resolve).and_return("/state/samagotchi.log")
    allow(Samagotchi::ToolDeclarations).to receive(:gemma_declarations).and_return("<GEMMA-DECL>")
    allow(Samagotchi::ToolDeclarations).to receive(:qwen_declarations).and_return("<QWEN-DECL>")
    allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil, **_overlay_keys|
      case name.to_s
      when "" then "# #{scope} index\n- **cfg_note** · #{scope} · 2026-09-01\n"
      when "identity" then identity_text
      else "BODY-#{name} (#{scope.inspect})"
      end
    end
  end

  def note(name, scope, body) = Samagotchi::ModelNotes::Note.new(name: name, scope: scope, body: body, chars: body.size, digest: "d")

  def plugin(bundle, name, text) = Samagotchi::Plugin::PromptSections::Built.new(bundle: bundle, name: name, text: text)

  def model = Samagotchi::SystemPrompt::ModelIdentity.new(ref: "box:m", host: "box.test:8080", key: "m")

  def builder(profile: Samagotchi::ModelProfile.gemma4, **opts)
    described_class.new(profile: -> { profile }, tools: -> { Samagotchi::Tools::Registry.new },
                        session: -> { Struct.new(:id, :parent_id).new("sid-1", nil) }, thinking: -> { :off },
                        model: -> { model }, muted_memory_names: muted, **opts)
  end

  def registry_with_tool
    Samagotchi::Tools::Registry.new.tap do |registry|
      registry.register("probe_tool", schema: { name: "probe_tool", description: "A probe.", parameters: { type: "object", properties: {} } },
                                      handler: ->(*) { "ok" })
    end
  end

  def by_kind(parts, kind) = parts.select { |part| part.kind == kind.to_s }

  # Every kind with one, two and three or more items, notes in two scopes, a
  # duplicate preload and one name in two scopes: what R1 (the items made
  # first-class) must keep byte for byte. The fixture was written by the
  # code before R1.
  describe "the parts golden" do
    let(:many_notes) do
      [note("model_notes_a", "system", "SYSTEM A"), note("model_notes_b", "system", "SYSTEM B\nline two"),
       note("model_notes_c", "project", "PROJECT C")]
    end
    let(:plugins) { [plugin("alpha", "one", "First."), plugin("beta", "two", "Second.\nTwo lines."), plugin("gamma", "three", "Third.\n")] }

    def golden_builds
      FileUtils.mkdir_p(File.join(@project, ".git"))
      FileUtils.mkdir_p(File.join(@project, "pkg", "inner"))
      File.write(File.join(@project, "pkg", "AGENTS.md"), "Pkg rules.\n\n\n")
      File.write(File.join(@project, "pkg", "inner", "AGENTS.md"), "Inner rules.")
      File.write(File.join(@project, "more.md"), "More.\n")
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[dup dup project/x system/x])
      allow(Samagotchi::ConfigFile).to receive(:appended_prompt_files).and_return(%w[../../extra.md ../../more.md])
      Dir.chdir(File.join(@project, "pkg", "inner")) do
        [[true, Samagotchi::ModelProfile.gemma4], [false, Samagotchi::ModelProfile.qwen36], [false, Samagotchi::ModelProfile.gemma4]].map do |chat, profile|
          prompt = builder(profile: profile, memories: %w[cli_note], model_notes: -> { many_notes }, participants: -> { true },
                           sections: -> { plugins })
          allow(prompt).to(receive(:tool_surface).and_wrap_original { |_orig, layers| Samagotchi::Tools::ToolSurface.for(registry_with_tool, layers: layers) })
          prompt.build(chat: chat)
          path_length_change = "#{Samagotchi::Paths.tilde(Samagotchi::MemoryPaths.system_dir)}/".length -
                               "~/.config/samagotchi/memories/".length
          parts = prompt.prompt_parts.map { |part| part.to_h.slice(:kind, :label, :chars, :tokens, :ref, :scope) }
          parts.each do |part|
            next unless part[:kind] == "base"

            part[:chars] -= path_length_change
            part[:tokens] = Samagotchi::PromptPart.tokens_for(part[:chars])
          end
          { chat: chat, profile: profile.name, parts: parts }
        end
      end
    end

    it "records the items where the builders render them: re-joined they are each section, the sections the prompt" do
      FileUtils.mkdir_p(File.join(@project, ".git"))
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[dup dup])
      [true, false].each do |chat|
        prompt = builder(profile: Samagotchi::ModelProfile.qwen36, memories: %w[cli_note], model_notes: -> { many_notes },
                         participants: -> { true }, sections: -> { plugins })
        built = prompt.built_for(chat: chat)
        built.parts.each do |section|
          expect(section.items.map(&:sent).join(section.join)).to eq(section.text), section.kind.to_s
          expect(section.items.map(&:kind).uniq).to eq([section.kind])
        end
        stable, volatile = built.parts.partition { |section| !%i[participants model location session].include?(section.kind) }
        expect(built.prompt).to eq("#{stable.map(&:text).join("\n")}\n#{volatile.map(&:text).join("\n")}")
        preloads = built.parts.find { |section| section.kind == :preloads }
        expect(preloads.items.map(&:ref)).to eq(%w[dup dup cli_note])
        notes = built.parts.find { |section| section.kind == :notes }
        expect(notes.items.map(&:lead)).to eq(["Model notes (for box:m, scope=system):\n\n## model_notes_a\n", "## model_notes_b\n",
                                               "Model notes (for box:m, scope=project):\n\n## model_notes_c\n"])
        expect(notes.items.map(&:text)).to eq(many_notes.map(&:body))
      end
    end

    it "keeps every build's prompt_parts as they were before R1" do
      path = File.expand_path("fixtures/prompt_parts/golden.json", __dir__)
      actual = JSON.pretty_generate(JSON.parse(JSON.generate(golden_builds)).each do |build|
        build["parts"].each do |part|
          part["ref"] = part["ref"]&.sub(@project, "<project>")
          # The temp folder's path (its length varies with the pid) is in the location lines only.
          part.merge!("chars" => 0, "tokens" => 0) if part["kind"] == "location"
        end
      end)
      if ENV["UPDATE_PROMPTS"] == "1"
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "#{actual}\n")
      end
      expect("#{actual}\n").to eq(File.read(path))
    end
  end

  # The sent slice: head[at, len] is lead + text for every item, on a chat
  # host, a native non-Gemma one (the declarations inside base: base's
  # slice without them) and Gemma (the declarations after the rstripped
  # prompt). Joins and headings belonging to no item fall outside.
  describe "where each part sits in the prompt" do
    let(:many_notes) do
      [note("model_notes_a", "system", "SYSTEM A"), note("model_notes_b", "system", "SYSTEM B"), note("model_notes_c", "project", "PROJECT C")]
    end
    let(:plugins) { [plugin("alpha", "one", "First."), plugin("beta", "two", "Second."), plugin("gamma", "three", "Third.\n")] }

    def built_with(profile, chat:, volatile: true)
      FileUtils.mkdir_p(File.join(@project, "pkg", "inner"))
      FileUtils.mkdir_p(File.join(@project, ".git"))
      File.write(File.join(@project, "pkg", "AGENTS.md"), "Pkg rules.\n\n\n")
      File.write(File.join(@project, "pkg", "inner", "AGENTS.md"), "Inner rules.")
      allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return(%w[dup dup project/x system/x])
      allow(Samagotchi::ConfigFile).to receive(:appended_prompt_files).and_return(%w[../../extra.md])
      Dir.chdir(File.join(@project, "pkg", "inner")) do
        prompt = builder(profile: profile, memories: %w[cli_note], model_notes: -> { many_notes }, participants: -> { volatile },
                         sections: -> { plugins }, **(volatile ? {} : { session: -> {}, model: -> {} }))
        allow(prompt).to(receive(:tool_surface).and_wrap_original { |_orig, layers| Samagotchi::Tools::ToolSurface.for(registry_with_tool, layers: layers) })
        allow(prompt).to receive(:project_location).and_return(nil) unless volatile
        prompt.built_for(chat: chat)
      end
    end

    def items_and_parts(built)
      items = built.parts.flat_map(&:items)
      parts = built.prompt_parts.drop(1)
      expect(parts.size).to eq(items.size)
      items.zip(parts)
    end

    def expect_slices(built, cut: nil)
      head = built.prompt
      digest = Samagotchi::PromptPart.digest_of(head, 16)
      items_and_parts(built).each do |item, part|
        expect([part.kind, part.label]).to eq([item.kind.to_s, item.label])
        expect(part.lead).to eq(item.lead.length)
        expect(part.head).to eq(digest)
        sent = item.sent
        sent = sent[0, part.len] if cut && part.at + sent.length > cut
        expect(head[part.at, part.len]).to eq(sent), "#{part.kind} #{part.label}"
        expect(head[part.at + part.lead, part.len - part.lead]).to eq(sent[item.lead.length..]) unless item.kind == :base
      end
    end

    it "chat: every item, 1, 2 and 3+ of a kind and two note scopes; the tools are not in the prompt" do
      built = built_with(Samagotchi::ModelProfile.gemma4, chat: true)
      expect_slices(built)
      kinds = built.prompt_parts.map(&:kind).tally
      expect(kinds).to include("identity" => 1, "notes" => 3, "preloads" => 5, "agents" => 3, "appended" => 1, "plugins" => 3, "indexes" => 2)
      tools = built.prompt_parts.first
      expect([tools.at, tools.len, tools.head]).to eq([nil, nil, nil])
      expect(tools.params["tools"]).to eq([{ "name" => "probe_tool", "chars" => JSON.generate(built.surface.schemas.first).length }])
      items_and_parts(built).each { |item, part| expect(part.digest).to eq(Samagotchi::PromptPart.digest_of(item.text)) }
      # A note's heading is the first note of its scope's lead; a join between items is in no span.
      notes = built.prompt_parts.select { |part| part.kind == "notes" }
      expect(built.prompt[notes[0].at, notes[0].lead]).to eq("Model notes (for box:m, scope=system):\n\n## model_notes_a\n")
      expect(built.prompt[(notes[0].at + notes[0].len), 2]).to eq("\n\n")
      expect(notes[1].at).to eq(notes[0].at + notes[0].len + 2)
      # chars is not the slice length: a section's first part is charged its joins.
      expect(notes[0].chars).not_to eq(notes[0].len)
    end

    it "native qwen36: the tools sit inside base's span, and base's slice without them is base's own text" do
      built = built_with(Samagotchi::ModelProfile.qwen36, chat: false)
      expect_slices(built)
      tools, base = built.prompt_parts.first(2)
      expect(built.prompt[tools.at, tools.len]).to eq("<QWEN-DECL>")
      expect(tools.at).to be_between(base.at, base.at + base.len)
      base_text = built.parts.first.text
      expect(base.digest).to eq(Samagotchi::PromptPart.digest_of(base_text.sub("<QWEN-DECL>", "")))
      expect(tools.params["tools"]).to eq([{ "name" => "probe_tool" }])
    end

    it "Gemma: the tools at the tail, after the rstrip; the last item is cut at the strip" do
      built = built_with(Samagotchi::ModelProfile.gemma4, chat: false, volatile: false)
      tools = built.prompt_parts.first
      cut = built.prompt.length - "<GEMMA-DECL>".length
      expect([tools.at, tools.len]).to eq([cut, "<GEMMA-DECL>".length])
      expect(built.prompt[tools.at, tools.len]).to eq("<GEMMA-DECL>")
      expect_slices(built, cut: cut)
      last_item, last = items_and_parts(built).last
      # The system index ends in a newline the rstrip took.
      expect(last_item.sent).to end_with("\n")
      expect(last.len).to eq(last_item.sent.rstrip.length)
      expect(tools.params["tools"].map(&:keys)).to eq([%w[name chars]])
    end
  end

  it "is [] before a build and after a reset" do
    prompt = builder
    expect(prompt.prompt_parts).to eq([])
    prompt.build(chat: true)
    expect(prompt.prompt_parts).not_to be_empty
    prompt.reset!
    expect(prompt.prompt_parts).to eq([])
  end

  context "with every kind of section (chat)" do
    let(:notes) { [note("model_notes_a", "system", "SYSTEM A"), note("model_notes_b", "system", "SYSTEM B"), note("model_notes_a", "project", "PROJECT A")] }
    let(:prompt) do
      builder(memories: %w[cli_note system/other], model_notes: -> { notes }, participants: -> { true },
              sections: -> { [plugin("alpha", "one", "First."), plugin("beta", "two", "Second.\nTwo lines.")] })
    end
    let(:text) { prompt.build(chat: true) }
    let(:built) { text && prompt.instance_variable_get(:@last) }
    let(:parts) { prompt.prompt_parts }

    it "has the tools first, then the sections in prompt order, one part per item" do
      text
      expect(parts.map { |part| [part.kind, part.ref] }).to eq(
        [["tools", nil], ["base", nil], ["identity", "identity"],
         ["notes", "model_notes_a"], ["notes", "model_notes_b"], ["notes", "model_notes_a"],
         ["preloads", "cli_note"], ["preloads", "other"],
         ["agents", File.join(@project, "AGENTS.md")], ["appended", File.join(@project, "extra.md")],
         ["plugins", "alpha/one"], ["plugins", "beta/two"],
         ["indexes", "project"], ["indexes", "system"],
         ["participants", nil], ["model", nil], ["location", nil], ["session", nil]]
      )
    end

    it "sums each section's parts to its text, and every part's tokens at the one ratio" do
      text
      built.parts.each do |section|
        expect(by_kind(parts, section.kind).sum(&:chars)).to eq(section.text.length), section.kind.to_s
      end
      expect(parts.map(&:tokens)).to eq(parts.map { |part| (part.chars / 4.0).ceil })
      # Chat: the tools part is the schemas as JSON, nothing taken from base.
      expect(by_kind(parts, :tools).first.chars).to eq(2)
      expect(by_kind(parts, :base).first.chars).to eq(built.parts.first.text.length)
    end

    it "puts a section's headings and joins into its first part" do
      text
      second = by_kind(parts, :notes)[1]
      expect(second.chars).to eq("## model_notes_b\nSYSTEM B".length)
      expect(by_kind(parts, :plugins)[1].chars).to eq(plugin("beta", "two", "Second.\nTwo lines.").prompt_text.length)
      expect(by_kind(parts, :indexes)[1].chars).to eq("System memories:\n# system index\n- **cfg_note** · system · 2026-09-01\n".length)
    end

    it "labels a file under the work tree by its path from the top" do
      allow(Samagotchi::MemoryPaths).to receive(:work_tree_root).and_return(@project)
      text
      expect(by_kind(parts, :agents).first.label).to eq("AGENTS.md")
      expect(by_kind(parts, :appended).first.label).to eq("extra.md")
    end

    it "labels a file by its path and a plugin by bundle and name" do
      text
      # No work tree here (not a git folder): the path with ~ for the home.
      expect(by_kind(parts, :agents).first.label).to end_with("AGENTS.md")
      expect(by_kind(parts, :plugins).map(&:label)).to eq(["alpha: one", "beta: two"])
      expect(by_kind(parts, :tools).first.label).to eq("0 declared")
    end
  end

  it "leaves out an identity that is muted or unreadable" do
    muted_parts = builder(muted_memory_names: ["identity"]).tap { |prompt| prompt.build(chat: true) }.prompt_parts
    expect(by_kind(muted_parts, :identity)).to be_empty

    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_wrap_original do |original, name, **options|
      name.to_s == "identity" ? "Error: unreadable" : original.call(name, **options)
    end
    unreadable = builder.tap { |prompt| prompt.build(chat: true) }.prompt_parts
    expect(by_kind(unreadable, :identity)).to be_empty
  end

  describe "the tools part" do
    it "native non-Gemma: moves the declarations' chars from the base part, not counted twice" do
      qwen = builder(profile: Samagotchi::ModelProfile.qwen36)
      text = qwen.build(chat: false)
      parts = qwen.prompt_parts
      built = qwen.instance_variable_get(:@last)
      expect(text).to include("<QWEN-DECL>")
      expect(by_kind(parts, :tools).first.chars).to eq("<QWEN-DECL>".length)
      expect(by_kind(parts, :base).first.chars).to eq(built.parts.first.text.length - "<QWEN-DECL>".length)
    end

    it "Gemma: the tail declarations are the tools part and the base part keeps its own text" do
      gemma = builder
      text = gemma.build(chat: false)
      parts = gemma.prompt_parts
      built = gemma.instance_variable_get(:@last)
      expect(text).to end_with("<GEMMA-DECL>")
      expect(by_kind(parts, :tools).first.chars).to eq("<GEMMA-DECL>".length)
      expect(by_kind(parts, :base).first.chars).to eq(built.parts.first.text.length)
    end
  end

  describe "happy builds" do
    it "never degrade to no parts: chat, native and Gemma builds with real content log no prompt_parts_failed" do
      expect(Samagotchi::Degrade).not_to receive(:note)
      notes = [note("model_notes_a", "system", "A")]
      [[true, Samagotchi::ModelProfile.gemma4], [false, Samagotchi::ModelProfile.qwen36], [false, Samagotchi::ModelProfile.gemma4]].each do |chat, profile|
        prompt = builder(profile: profile, memories: ["cli_note"], model_notes: -> { notes },
                         sections: -> { [plugin("alpha", "one", "First.")] })
        allow(prompt).to(receive(:tool_surface).and_wrap_original { |_orig, layers| Samagotchi::Tools::ToolSurface.for(registry_with_tool, layers: layers) })
        prompt.build(chat: chat)
        expect(prompt.prompt_parts.size).to be > 10
      end
    end

    it "chat tools part: the real schemas as JSON, one declared" do
      prompt = builder
      allow(prompt).to(receive(:tool_surface).and_wrap_original { |_orig, layers| Samagotchi::Tools::ToolSurface.for(registry_with_tool, layers: layers) })
      prompt.build(chat: true)
      surface = Samagotchi::Tools::ToolSurface.for(registry_with_tool, layers: [])
      tools = by_kind(prompt.prompt_parts, :tools).first
      expect(surface.schemas).not_to be_empty
      expect(tools.chars).to eq(JSON.generate(surface.schemas).length)
      expect(tools.label).to eq("#{surface.declared_names.size} declared")
    end
  end

  it "orders note parts as the text groups them by scope (system, project, system)" do
    notes = [note("model_notes_a", "system", "SA"), note("model_notes_p", "project", "PP"), note("model_notes_b", "system", "SB")]
    prompt = builder(model_notes: -> { notes })
    text = prompt.build(chat: true)
    parts = by_kind(prompt.prompt_parts, :notes)
    expect(parts.map(&:label)).to eq(%w[model_notes_a model_notes_b model_notes_p])
    expect(text.index("## model_notes_b")).to be < text.index("## model_notes_p")
    expect(parts[1].chars).to eq("## model_notes_b\nSB".length)
    expect(parts[2].chars).to eq("## model_notes_p\nPP".length)
  end

  it "gives each memory part its scope: identity system, a note its own, a preload the one asked for; others none" do
    notes = [note("model_notes_a", "system", "SA"), note("model_notes_p", "project", "PP")]
    prompt = builder(memories: %w[project/mine system/other], model_notes: -> { notes })
    prompt.build(chat: true)
    parts = prompt.prompt_parts
    expect(by_kind(parts, :identity).map(&:scope)).to eq(["system"])
    expect(by_kind(parts, :notes).map { |part| [part.ref, part.scope] }).to eq([%w[model_notes_a system], %w[model_notes_p project]])
    expect(by_kind(parts, :preloads).map { |part| [part.ref, part.scope] }).to eq([%w[mine project], %w[other system]])
    expect(parts.reject { |part| %w[identity notes preloads].include?(part.kind) }.map(&:scope).uniq).to eq([nil])
  end

  describe "a bare preload's scope: the one that answered (memory_read falls back project -> system)" do
    def read_result(name, scope)
      project_dir = "/mem/projects/p_1"
      path = scope == "project" ? "#{project_dir}/#{name}.md" : "/mem/#{name}.md"
      Samagotchi::Tools::MemoryRead::Result.new("BODY-#{name}", { name => { path: path, overlay_path: nil, requested_scope: nil,
                                                                            project_dir: project_dir } })
    end

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_wrap_original do |original, name, scope: nil, **keys|
        case name.to_s
        when "from_project" then read_result("from_project", "project")
        when "from_system" then read_result("from_system", "system")
        else original.call(name, scope: scope, **keys)
        end
      end
    end

    it "is project for one the project's memories answered, system for one that fell back" do
      prompt = builder(memories: %w[from_project from_system])
      text = prompt.build(chat: true)
      expect(by_kind(prompt.prompt_parts, :preloads).map { |part| [part.ref, part.scope] })
        .to eq([%w[from_project project], %w[from_system system]])
      expect(text).to include("memory name: from_project\nBODY-from_project")
    end
  end

  it "has no scope for a bare preload whose body has no read's record (a plain String)" do
    prompt = builder(memories: %w[cli_note])
    prompt.build(chat: true)
    expect(by_kind(prompt.prompt_parts, :preloads).map(&:scope)).to eq([nil])
  end

  it "counts a later item's own chars: the second preload, an AGENTS.md and an appended file" do
    prompt = builder(memories: %w[cli_note system/other])
    text = prompt.build(chat: true)
    parts = prompt.prompt_parts
    other = by_kind(parts, :preloads)[1]
    expect(other.chars).to eq("this memory is required by the user in the current context: memory name: other\nBODY-other (\"system\")".length)
    expect(text).to include("memory name: other\nBODY-other")
    agents = by_kind(parts, :agents).first
    appended = by_kind(parts, :appended).first
    agents_section = prompt.instance_variable_get(:@last).parts.find { |part| part.kind == :agents }
    appended_section = prompt.instance_variable_get(:@last).parts.find { |part| part.kind == :appended }
    expect(agents.chars).to eq(agents_section.text.length)
    expect(appended.chars).to eq(appended_section.text.length)
    expect(appended.chars).to be > "Extra rules.\n".length
  end
end
