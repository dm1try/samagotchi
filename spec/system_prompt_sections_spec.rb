# frozen_string_literal: true

require "samagotchi/system_prompt"
require "samagotchi/model_profile"
require "samagotchi/tools/registry"
require "tmpdir"

# Byte-for-byte snapshots of the pieces spec/system_prompt_full_spec.rb's
# goldens don't reach: appended files, plugins' sections, the participants
# line, model notes in two scopes, a Gemma prompt's tail declarations (and
# the rstrip before them) and a prompt without a volatile part. They hold
# the prompt's bytes still while its parts are built as sections.
#
# Regenerate after an intended change with:
#   UPDATE_PROMPTS=1 bundle exec rspec spec/system_prompt_sections_spec.rb
RSpec.describe Samagotchi::SystemPrompt, "section snapshots" do
  def fixture_dir = File.expand_path("fixtures/system_prompt_sections", __dir__)

  def expect_snapshot(name, actual)
    path = File.join(fixture_dir, name)
    if ENV["UPDATE_PROMPTS"] == "1"
      FileUtils.mkdir_p(fixture_dir)
      File.write(path, actual)
    end
    expect(actual).to eq(File.read(path))
  end

  let(:config_appended) { [] }

  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = File.realpath(tmp)
      @project = File.join(@tmp, "project")
      FileUtils.mkdir_p(@project)
      File.write(File.join(@project, "AGENTS.md"), "This project builds widgets.\n")
      File.write(File.join(@project, "extra.md"), "Extra rules.\n")
      File.write(File.join(@project, "more.md"), "More rules.\n")
      Dir.chdir(@project) { example.run }
    end
  end

  before do
    allow(Samagotchi::ConfigFile).to receive(:preloaded_memories).and_return([])
    allow(Samagotchi::ConfigFile).to receive(:appended_prompt_files) { config_appended }
    allow(Samagotchi::BundleNeeds).to receive(:found?).and_call_original
    allow(Samagotchi::BundleNeeds).to receive(:found?).with("rg").and_return(true)
    allow(Samagotchi::LogPath).to receive(:resolve).and_return("/state/samagotchi.log")
    allow(Samagotchi::ToolDeclarations).to receive(:gemma_declarations).and_return("<TOOLS-TAIL>")
    allow(Samagotchi::Tools::MemoryRead).to receive(:memories_dir).and_call_original
    allow(Samagotchi::Tools::MemoryRead).to receive(:memories_dir).with("project")
      .and_return(File.join(Dir.home, ".config", "samagotchi", "memories", "projects", "project_abc"))
    allow(Samagotchi::Tools::MemoryRead).to receive(:call) do |name, scope: nil, **_overlay_keys|
      case name.to_s
      when "" then "# #{scope} index\n- **cfg_note** · #{scope} · 2026-09-01\n"
      when "identity" then "I am chi's identity."
      else "BODY-#{name} (#{scope.inspect})"
      end
    end
  end

  def normalized(prompt)
    prompt.gsub(@tmp, "<TMP>").gsub(Dir.home, "<HOME>")
  end

  def note(name, scope, body) = Samagotchi::ModelNotes::Note.new(name: name, scope: scope, body: body, chars: body.size, digest: "d")

  def section(bundle, name, text) = Samagotchi::Plugin::PromptSections::Built.new(bundle: bundle, name: name, text: text)

  def model = Samagotchi::SystemPrompt::ModelIdentity.new(ref: "box:m", host: "box.test:8080", key: "m")

  def session = Struct.new(:id, :parent_id).new("sid-1234", nil)

  def build(profile: Samagotchi::ModelProfile.gemma4, chat: false, **opts)
    prompt = described_class.new(profile: -> { profile }, tools: -> { Samagotchi::Tools::Registry.new },
                                 session: -> {}, thinking: -> { :off }, **opts)
    [prompt, normalized(prompt.build(chat: chat))]
  end

  it "appended files from config and the command line, after AGENTS.md; a repeat and AGENTS.md itself are left out" do
    config_appended.push("extra.md")
    _, text = build(chat: true, appended_files: [File.join(@project, "more.md"), "extra.md", File.join(@project, "AGENTS.md")])
    expect_snapshot("appended.txt", text)
  end

  it "plugins' sections, sorted as given, between the kit and the memory indexes" do
    _, text = build(chat: true, sections: -> { [section("alpha", "one", "First."), section("beta", "two", "Second.\nTwo lines.")] })
    expect_snapshot("plugins.txt", text)
  end

  it "the participants line first in the volatile tail" do
    _, text = build(chat: true, participants: -> { true }, model: -> { model })
    expect_snapshot("participants.txt", text)
  end

  it "model notes in the system and the project scope, each under its heading" do
    notes = [note("model_notes_a", "system", "SYSTEM A"), note("model_notes_b", "system", "SYSTEM B"),
             note("model_notes_a", "project", "PROJECT A")]
    _, text = build(chat: true, model: -> { model }, model_notes: -> { notes })
    expect_snapshot("model_notes_two_scopes.txt", text)
  end

  it "a Gemma prompt declares its tools after the whole prompt, which is rstripped first" do
    _, text = build(chat: false, model: -> { model }, session: -> { session })
    expect(text).to end_with("sid=sid-1234)<TOOLS-TAIL>")
    expect_snapshot("gemma_tail.txt", text)
  end

  it "a Gemma prompt without a volatile part: the indexes' last newline is stripped before the declarations" do
    allow(Samagotchi::MemoryPaths).to receive(:lookup).and_raise(IOError, "no location")
    allow(Samagotchi::Log).to receive(:warn)
    _, text = build(chat: false)
    expect(text).to end_with("index\n- **cfg_note** · system · 2026-09-01<TOOLS-TAIL>")
    expect_snapshot("gemma_tail_no_volatile.txt", text)
  end

  it "a prompt without a volatile part is the stable part alone, with no stable length measured" do
    allow(Samagotchi::MemoryPaths).to receive(:lookup).and_raise(IOError, "no location")
    allow(Samagotchi::Log).to receive(:warn)
    prompt, text = build(chat: true)
    expect(text).not_to include("Current working directory:")
    expect(prompt.stable_length(prompt.build(chat: true))).to be_nil
    expect_snapshot("no_volatile.txt", text)
  end

  it "a chat prompt's stable length ends right before the volatile lines" do
    prompt, = build(chat: true, participants: -> { true }, model: -> { model })
    text = prompt.build(chat: true)
    expect(text[prompt.stable_length(text)..]).to start_with("Participants:")
  end
end
