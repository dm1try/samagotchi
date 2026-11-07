# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/toolkit_command"
require "samagotchi/plugin/context"
require "support/test_kernel"

# The readers off the turn thread (/toolkit, the snapshot's toolkit chip,
# a plugin's ctx.declared_tools and ctx.load_tools) read the Registry as the
# turn thread last published it (ToolkitBinding#publish!: the Engine's
# build, a turn's staged tool sets and toolkit apply), never the live one
# a turn's start is changing.
RSpec.describe Samagotchi::Engine, "published tools" do
  before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

  def build(**) = described_class.new(client: test_client, kernel: test_kernel, profile: "gemma4", **)

  def stage(engine, names)
    specs = names.map { |name| Samagotchi::Plugin::ToolSpec.build(name, "A late tool.") { "ok" } }
    engine.send(:stage_tools, "late-bundle", specs, nil)
  end

  def ctx(engine) = Samagotchi::Plugin::Context.new(bundle: "reader", label: "plugin.rb (bundle reader)", settings: {},
                                                    host: engine.send(:plugin_host))

  def plugin_names(names) = names.grep(/\A[pq]_/)

  it "never shows a reader a Registry half way through a turn's staged tool sets" do
    engine = build
    lean = Samagotchi::Toolkit.new(name: "lean")
    sets = [%w[p_a p_b p_c], %w[q_a q_b q_c]]
    rounds = 6
    halfway = Queue.new
    resume = Queue.new
    # The turn thread stops after the first tool of each set is registered
    # (the old set unregistered, the rest of the new one not yet), until a
    # reader has read.
    allow(engine.tools).to receive(:register).and_wrap_original do |original, name, **opts|
      entry = original.call(name, **opts)
      if sets.any? { |set| set.first == name }
        halfway << name
        pop!(resume, "the reader's read")
      end
      entry
    end

    seen = []
    reader = Thread.new do
      rounds.times do
        pop!(halfway, "the turn thread half way")
        explained = engine.toolkit_explained(lean)
        seen << { declared: plugin_names(ctx(engine).declared_tools),
                  left_out: plugin_names(explained.left_out), reachable: plugin_names(explained.reachable),
                  summary: plugin_names(engine.toolkit_explained.declared.map(&:name)) }
        resume << :read
      end
    end
    turn_thread = Thread.new do
      rounds.times do |round|
        stage(engine, sets[round % 2])
        engine.apply_staged_tools!
      end
    end
    join!(turn_thread, "the turn thread")
    join!(reader, "the reader")

    # Each read is the set the last round published, whole: none before
    # the first round's publish.
    expected = [[]] + Array.new(rounds - 1) { |round| sets[round % 2] }
    expect(seen.map { |read| read[:declared] }).to eq(expected)
    expect(seen.map { |read| read[:summary] }).to eq(expected)
    expect(seen.map { |read| read[:left_out] }).to eq(expected)
    expect(seen.map { |read| read[:reachable] }).to eq(expected)
  end

  it "shows ctx.declared_tools and ctx.load_tools a chi.replace_tools set from the apply at a turn's start, not before" do
    engine = build
    stage(engine, %w[p_late])
    expect(ctx(engine).declared_tools).not_to include("p_late")
    engine.apply_staged_tools!
    expect(ctx(engine).declared_tools).to include("p_late")

    # On lean, where call_tool reaches it: loadable from the apply on.
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    session.toolkit = Samagotchi::Toolkit.new(name: "lean")
    engine.session = session
    engine.send(:apply_toolkit!, session)
    stage(engine, %w[p_late p_later])
    expect(ctx(engine).load_tools(["p_later"])).to eq([])
    engine.apply_staged_tools!
    expect(ctx(engine).load_tools(["p_later"])).to eq(["p_later"])
  end

  it "doesn't list on a scratch session's /toolkit before its first turn the tools a scratch session doesn't offer" do
    engine = build(scratch: true)
    engine.session = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd)
    removed = [Samagotchi::Tools::Delegate::NAME, Samagotchi::Tools::DelegateResult::NAME,
               Samagotchi::Tools::SendNote::NAME]

    output, = Samagotchi::ToolkitCommand.new(engine: engine, save: ->(_) {}).run("")
    expect(engine.toolkit_explained.declared.map(&:name) & removed).to eq([])
    expect(output).not_to include(*removed)
    expect(ctx(engine).declared_tools).to include("execute")
  end
end
