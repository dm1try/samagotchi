# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "samagotchi/hooks"

RSpec.describe Samagotchi::Hooks::Loader do
  let(:hooks_dir) { Dir.mktmpdir("hooks-loader-") }

  after { FileUtils.rm_rf(hooks_dir) }

  def write_hook(basename, body)
    File.write(File.join(hooks_dir, basename), body)
  end

  def load(entries, event: "before_turn")
    described_class.load({ "hooks" => { "hooks_dir" => hooks_dir, event => entries } })
  end

  it "labels a config hook's events by its file" do
    write_hook("label_probe.rb", "class LabelProbe; def call(e); e[:seen] = e[:hook]; end; end")
    registry = load([{ "path" => "label_probe.rb" }])
    event = { type: :before_turn }
    registry.fire(:before_turn, event)
    expect(event[:seen]).to eq("label_probe.rb (config)")
  end

  it "passes an entry's settings to a hook whose initialize takes an argument" do
    write_hook("threshold_probe.rb", "class ThresholdProbe; def initialize(s = {}); @s = s; end; def call(e); e[:settings] = @s; end; end")
    registry = load([{ "path" => "threshold_probe.rb", "settings" => { "threshold" => 2 } }])
    event = { type: :before_turn }
    registry.fire(:before_turn, event)
    expect(event[:settings]).to eq({ "threshold" => 2 })
  end

  it "builds one instance per [path, settings]: two entries with different settings get two" do
    write_hook("pair_probe.rb", "class PairProbe; def initialize(s = {}); @s = s; end; def call(e); (e[:seen] ||= []) << @s['n']; end; end")
    registry = load([{ "path" => "pair_probe.rb", "settings" => { "n" => 1 } }, { "path" => "pair_probe.rb", "settings" => { "n" => 2 } }])
    event = { type: :before_turn }
    registry.fire(:before_turn, event)
    expect(event[:seen]).to eq([1, 2])
  end

  it "gives a hook with no settings: an empty hash, and builds a bare class without one" do
    write_hook("empty_probe.rb", "class EmptyProbe; def initialize(s); @s = s; end; def call(e); e[:settings] = @s; end; end")
    write_hook("bare_probe.rb", "class BareProbe; def call(e); e[:bare] = true; end; end")
    registry = load([{ "path" => "empty_probe.rb" }, { "path" => "bare_probe.rb" }])
    event = { type: :before_turn }
    registry.fire(:before_turn, event)
    expect(event).to include(settings: {}, bare: true)
  end
end
