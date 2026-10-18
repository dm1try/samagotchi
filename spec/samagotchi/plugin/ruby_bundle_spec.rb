# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/memory_paths"
require "samagotchi/memory_bundle/installer"
require "support/thinking_off"
require "support/test_kernel"

# The ruby bundle (lib/samagotchi/bundles/ruby) installed and loaded by an
# Engine, its hint landing in the real conversation (its plugin alone:
# lib/samagotchi/bundles/ruby/spec/). The execute call is stubbed: what a
# real rspec run prints is the bundle's own spec's business.
RSpec.describe "The ruby bundle" do
  include_context "thinking off"

  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/ruby", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("ruby-") }
  let(:client) { test_client }
  let(:engine) { Samagotchi::Engine.new(client: client) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd) }
  let(:zero_examples) { "stdout:\n0 examples, 0 failures\n\nexit: 0" }

  after { FileUtils.rm_rf(tmpdir) }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    ENV["XDG_STATE_HOME"] = File.join(tmpdir, "state")
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
  end

  before do
    FileUtils.mkdir_p(Samagotchi::MemoryPaths.system_dir)
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    @installer = Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "ruby", scope: "system", strict: true)
    @installer.run
  end

  def steers
    session.messages.select { |m| (m[:kind] || m["kind"]).to_s == "steer" && (m[:source] || m["source"]).to_s == "ruby" }
  end

  it "installs cleanly and loads" do
    expect(@installer.warnings).to be_empty
    expect(engine.guardrail_failures.any?).to be(false)
  end

  it "steers the hint into the turn after an execute that ran rspec with no examples" do
    allow(Samagotchi::Tools::Execute).to receive(:call).and_return(zero_examples)
    replies = [%(<|tool_call>call:execute{command: "bundle exec rspec"}<tool_call|>), "done"]
    allow(client).to receive(:complete) { replies.shift || "done" }

    engine.run_turn(session, "go")

    expect(steers.map { |m| m[:content] })
      .to eq(["rspec ran 0 examples: check the path, the filter (-e/--tag) or the .rspec --pattern"])
  end
end
