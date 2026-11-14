# frozen_string_literal: true

require "samagotchi/testing/rspec"
require "samagotchi/inline_widgets"

# The inline-widgets plugin through the bundle test kit: its two prompt
# sections, where they are left out, and the examples they teach, each a block
# chi's own parse takes strictly (a model copies the example as it is).
RSpec.describe "The inline-widgets plugin", :bundle do
  EXAMPLE = /^```chi-ui\n(.*?)^```$/m

  def plugin(**host) = shipped_bundle("inline-widgets", host: { session_id: "s1", **host })

  def sections(bundle) = bundle.prompt_sections.to_h { |built| [built.name, built.text] }

  it "adds picks and walk to a worker session's prompt" do
    bundle = plugin
    expect(bundle.prompt_sections.map { |built| [built.bundle, built.name] })
      .to eq([%w[inline-widgets picks], %w[inline-widgets walk]])
    expect(bundle.prompt_text).to start_with("From inline-widgets (picks):\nThe web UI draws fenced ```chi-ui")
    expect(sections(bundle)["walk"]).to start_with("walk is the other ```chi-ui widget")
  end

  it "keeps each section under the prompt-section limit" do
    texts = sections(plugin)
    expect(texts["picks"].length).to be <= Samagotchi::Plugin::PromptSections::MAX
    expect(texts["walk"].length).to be <= Samagotchi::Plugin::PromptSections::MAX
  end

  it "teaches only examples chi's parse takes strictly" do
    texts = sections(plugin)
    { "picks" => "picks", "walk" => "walk" }.each do |name, type|
      examples = texts[name].scan(EXAMPLE).map(&:first)
      expect(examples.size).to eq(1), "#{name}: #{examples.size} examples"
      result = Samagotchi::InlineWidgets.parse(examples.first)
      expect(result.error).to be_nil, "#{name}: #{result.error}"
      expect(result).to be_ok
      expect(result).not_to be_lenient, "#{name}: needs the lenient pass"
      expect(result.type).to eq(type)
    end
  end

  it "teaches next: end in the walk, and keeps the quoting line in both" do
    texts = sections(plugin)
    walk = Samagotchi::InlineWidgets.parse(texts["walk"][EXAMPLE, 1]).data
    expect(walk["steps"].map { |step| step["next"] }).to include("end")
    texts.each_value { |text| expect(text).to end_with(%(Quote a value that starts with a quote or contains ": ".)) }
  end

  it "gives the same text at every build" do
    bundle = plugin
    once = bundle.prompt_text
    expect(bundle.prompt_text).to eq(once)
    expect(plugin(session_id: "s2").prompt_text).to eq(once)
  end

  it "adds nothing to a one-shot's prompt (-p --non-interactive)" do
    bundle = plugin(frontend: :non_interactive)
    expect(bundle.prompt_sections).to be_empty
    expect(bundle.prompt_text).to be_nil
  end

  it "adds nothing to a delegate child's prompt" do
    bundle = plugin
    allow(bundle.ctx).to receive(:delegate?).and_return(true)
    expect(bundle.prompt_sections).to be_empty
    expect(bundle.prompt_text).to be_nil
  end
end
