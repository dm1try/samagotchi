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
end
