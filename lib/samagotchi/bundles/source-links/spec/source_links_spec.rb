# frozen_string_literal: true

require "samagotchi/testing/rspec"

# The source-links hook through the bundle test kit, on :question_asked: the
# refs in the reply that asks a question (and in the question itself) as
# refs on that reply. Its after_turn side is spec/samagotchi/bundles/
# source_links_spec.rb's.
RSpec.describe "The source-links bundle on a question", :bundle do
  let(:settings) do
    { "sources" => [{ "name" => "DEMO", "prefix" => "DEMO", "base_url" => "https://example.com/browse/" },
                    { "name" => "GH", "pattern" => '\bGH-(\d+)\b', "url" => "https://github.com/o/r/issues/{match}",
                      "kind" => "pr" }] }
  end

  def hook(config = settings) = shipped_bundle("source-links", settings: config)

  def ref(key, name: "DEMO", kind: "issue", url: "https://example.com/browse/#{key}")
    { match: key, kind: kind, target: { id: key }, label: "#{name} #{key}",
      actions: [{ id: "open", label: "Open in #{name}", url: url }] }
  end

  it "is one hook on both events" do
    bundle = hook
    expect(bundle.hook_names(:after_turn)).to eq([["source-links", "source_links.rb", 90]])
    expect(bundle.hook_names(:question_asked)).to eq([["source-links", "source_links.rb", 90]])
  end

  it "makes each ref in the reply that asks a ref on it, with its Open in action, once" do
    refs = hook.question_asked("DEMO-123 needs a call; DEMO-123 again, and GH-4.", question: { question: "Proceed?" })
    expect(refs).to eq([ref("DEMO-123"), ref("GH-4", name: "GH", kind: "pr", url: "https://github.com/o/r/issues/4")])
  end

  it "adds the refs in the question's own text and options (an approval's too), after the reply's" do
    bundle = hook
    refs = bundle.question_asked("Look at DEMO-1.", question: { "question" => "Close DEMO-2?", "options" => %w[DEMO-3 no] })
    expect(refs.map { |r| r[:match] }).to eq(%w[DEMO-1 DEMO-2 DEMO-3])
    approval = bundle.question_asked("Running it.", kind: "approval", question: { question: "Allow the fix for DEMO-9?" })
    expect(approval.map { |r| r[:match] }).to eq(%w[DEMO-9])
  end

  it "leaves a ref in code or in a markdown link out, and sends no note line" do
    bundle = hook
    refs = bundle.question_asked("`DEMO-1` and [DEMO-2](https://example.com/browse/DEMO-2), then DEMO-3?")
    expect(refs.map { |r| r[:match] }).to eq(%w[DEMO-3])
    expect(bundle.notices).to be_empty
  end

  it "attaches nothing without sources, or for a question that names none" do
    expect(hook({}).question_asked("DEMO-1?")).to eq([])
    expect(hook.question_asked("Which file should I read?", question: { question: "README or Gemfile?", options: %w[a b] })).to eq([])
  end
end
