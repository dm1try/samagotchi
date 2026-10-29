# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/plugin/api"
require "samagotchi/plugin/loader"
require "samagotchi/terminal_ui/formatting"

# chi.prompt_section / chi.prompt_changed! (docs/plugins.md, Prompt
# sections): plugin text in the system prompt's stable part, after the kit
# prompt and before the memory indexes, built only with the prompt.
RSpec.describe "chi.prompt_section" do
  let(:registry) do
    Samagotchi::HostRegistry.new(hosts_config: { "oai" => { host: "oai.test", port: 8000, api: :openai } })
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("(index)")
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
  end

  def engine(model = "oai:m")
    Samagotchi::Engine.new(host_registry: registry, model_name: model, profile: "qwen36").tap { |e| e.session = session }
  end

  # A plugin of +bundle+ registered into +e+ as the Loader does: the block
  # gets the Api (chi) before commit!.
  def plugin(e, bundle)
    label = "plugin.rb (bundle #{bundle})"
    context = Samagotchi::Plugin::Context.new(bundle: bundle, label: label, settings: {}, host: e.send(:plugin_host))
    registries = Samagotchi::Plugin::Registries.new(prompt_sections: e.instance_variable_get(:@prompt_sections),
                                                    prompt_changed: -> { e.prompt_changed! })
    api = Samagotchi::Plugin::Api.new(bundle: bundle, label: label, registries: registries, context: context)
    yield api
    api.commit!
    api
  end

  def stable(e)
    prompt = e.system_prompt
    prompt[0, e.instance_variable_get(:@prompt_builder).stable_length(prompt)]
  end

  it "adds nothing when every block gives nil: the prompt is byte-identical to one without plugins" do
    plain = engine.system_prompt
    e = engine
    plugin(e, "tone") { |chi| chi.prompt_section("tone") { nil } }
    expect(e.system_prompt).to eq(plain)
    expect(e.instance_variable_get(:@prompt_builder).prompt_sections).to eq([])
  end

  it "puts the sections, sorted by (bundle, name), after the kit prompt and before the memory indexes, in the stable part" do
    e = engine
    e.tools.toolkit = Samagotchi::Toolkit::Resolved.new(name: "terse", all_core: true, prompt: "- Be concise")
    plugin(e, "tone") { |chi| chi.prompt_section("tone") { "Answer in plain words.\n" } }
    plugin(e, "alpha") do |chi|
      chi.prompt_section("zeta") { "Z" }
      chi.prompt_section("eta") { "E" }
    end

    expect(stable(e)).to include("- Be concise\nFrom alpha (eta):\nE\n\nFrom alpha (zeta):\nZ\n\n" \
                                 "From tone (tone):\nAnswer in plain words.\nProject memories:\n(index)")
    stub_request(:get, %r{\Ahttp://oai\.test:8000/}).to_return(status: 404)
    expect(e.stats_snapshot[:prompt_sections]).to eq([{ bundle: "alpha", name: "eta" }, { bundle: "alpha", name: "zeta" },
                                                      { bundle: "tone", name: "tone" }])
  end

  it "runs the block once per build, gives the same bytes for the same text, and rebuilds after prompt_changed!" do
    calls = 0
    text = "concise"
    e = engine
    api = plugin(e, "tone") do |chi|
      chi.prompt_section("tone") do
        calls += 1
        text
      end
    end

    first = e.system_prompt
    e.system_prompt
    expect(calls).to eq(1)

    api.prompt_changed!
    expect(e.system_prompt).to eq(first)
    expect(calls).to eq(2)

    text = "detailed"
    api.prompt_changed!
    expect(e.system_prompt).to include("From tone (tone):\ndetailed\n")
    expect(calls).to eq(3)
  end

  it "evaluates the block again with the new ctx.model after /model" do
    e = engine
    plugin(e, "tone") { |chi| chi.prompt_section("tone") { |ctx| "for #{ctx.model}" } }
    expect(e.system_prompt).to include("From tone (tone):\nfor oai:m\n")

    e.switch_model!("oai:other")
    expect(e.system_prompt).to include("From tone (tone):\nfor oai:other\n")
  end

  it "keeps the last good text on a raise, a non-String or oversize text, with one warn per problem; none before any good text" do
    allow(Samagotchi::Log).to receive(:warn).and_call_original
    value = -> { raise "boom" }
    e = engine
    api = plugin(e, "tone") { |chi| chi.prompt_section("tone") { value.call } }

    expect(e.system_prompt).not_to include("From tone")

    value = -> { "good" }
    api.prompt_changed!
    expect(e.system_prompt).to include("From tone (tone):\ngood\n")

    [-> { raise "boom" }, -> { :concise }, -> { "x" * 2001 }].each do |bad|
      value = bad
      2.times do
        api.prompt_changed!
        expect(e.system_prompt).to include("From tone (tone):\ngood\n")
      end
    end
    expect(Samagotchi::Log).to have_received(:warn).with(:plugins, "prompt_section_failed", hash_including(bundle: "tone"))
                                                   .exactly(3).times
    expect(Samagotchi::Log).to have_received(:warn)
      .with(:plugins, "prompt_section_failed", hash_including(error: "is over 2000 characters", kept: true)).once
  end

  it "refuses a bad name, a missing block, a repeat and a chi without prompt sections" do
    e = engine
    plugin(e, "tone") { |chi| chi.prompt_section("tone") { "x" } }
    plugin(e, "tone") do |chi|
      expect { chi.prompt_section("Tone") { "x" } }.to raise_error(ArgumentError, /must be a-z/)
      expect { chi.prompt_section("other") }.to raise_error(ArgumentError, /needs a block/)
      expect { chi.prompt_section("tone") { "x" } }.to raise_error(ArgumentError, "prompt section tone is registered twice")
      chi.prompt_section("other") { "y" }
      expect { chi.prompt_section("other") { "y" } }.to raise_error(ArgumentError, "prompt section other is registered twice")
    end
    bare = Samagotchi::Plugin::Api.new(bundle: "b", label: "b", registries: Samagotchi::Plugin::Registries.new)
    expect { bare.prompt_section("x") { "x" } }.to raise_error(ArgumentError, /no prompt sections/)
    expect(bare.prompt_changed!).to be_nil
  end

  it "names the sections on /stats' prompt sections line" do
    text = Samagotchi::TerminalUI::Formatting.format_session_metrics({ prompt_sections: [{ bundle: "tone", name: "tone" }] })
    expect(text).to include("prompt sections:  tone (tone)")
    expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({})).not_to include("prompt sections")
  end
end
