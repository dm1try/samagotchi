# frozen_string_literal: true

require "spec_helper"
require "samagotchi/engine"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "samagotchi/plugin/api"
require "samagotchi/plugin/loader"
require "support/test_kernel"

# A plugin command that asks before a prompt-cache restart
# (ctx.cache_confirm, docs/plugins.md "Commands that ask"): SessionCommands
# hands it the sender's confirm flag, and its [text, confirm] reply becomes
# Result#confirm, as /thinking's does.
RSpec.describe "ctx.cache_confirm in a plugin command" do
  let(:engine) { Samagotchi::Engine.new(client: test_client, kernel: test_kernel, profile: "gemma4") }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }
  let(:commands) do
    Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine), default_model: "m",
                                    registry: engine.command_registry, save: ->(_s) {})
  end
  let(:context) do
    Samagotchi::Plugin::Context.new(bundle: "tone", label: "plugin.rb (bundle tone)", settings: {}, host: engine.send(:plugin_host))
  end
  let(:state) { { style: "concise", changes: 0 } }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    engine.session = session
    state_ref = state
    registries = Samagotchi::Plugin::Registries.new(commands: engine.command_registry, toolkits: [],
                                                    prompt_sections: engine.instance_variable_get(:@prompt_sections),
                                                    prompt_changed: -> { state_ref[:changes] += 1 })
    api = Samagotchi::Plugin::Api.new(bundle: "tone", label: "plugin.rb (bundle tone)", registries: registries,
                                      context: context)
    api.prompt_section("tone") { state_ref[:style] }
    api.command("/tone", "set the tone") do |args, ctx|
      word = (args.split - %w[--yes -y]).join(" ")
      ask = ctx.cache_confirm("/tone #{word}", changed: word != state_ref[:style])
      next ["tone: #{word} restarts the prompt cache.", ask] if ask

      state_ref[:style] = word
      api.prompt_changed!
      "tone: #{word}"
    end
    api.command("/plain", "returns a string") { |_args, _ctx| "plain" }
    api.command("/quiet", "returns nothing") { |_args, _ctx| nil }
    api.commit!
  end

  def with_history = session.messages << { role: "model", content: "hi" }

  it "asks a person at a web tab or a TUI once the session has a model reply, and changes nothing" do
    with_history
    result = commands.run("/tone detailed")

    expect(result.status).to eq(:ok)
    expect(result.output).to eq("tone: detailed restarts the prompt cache.")
    expect(result.confirm).to eq(Samagotchi::CacheConfirm::Confirm.new(
      line: "/tone detailed --yes",
      text: "Nothing changed yet: send `/tone detailed --yes` to apply."
    ))
    expect(state).to eq({ style: "concise", changes: 0 })
  end

  it "applies at once with --yes, for a sender no one answers for, without history, or with no change" do
    with_history
    expect(commands.run("/tone detailed --yes")).to have_attributes(output: "tone: detailed", confirm: nil)
    expect(commands.run("/tone teaching", confirm: false)).to have_attributes(output: "tone: teaching", confirm: nil)
    expect(commands.run("/tone teaching")).to have_attributes(output: "tone: teaching", confirm: nil)
    expect(state).to eq({ style: "teaching", changes: 3 })

    session.messages.clear
    expect(commands.run("/tone concise")).to have_attributes(output: "tone: concise", confirm: nil)
  end

  it "names the size from the last request and, on api: anthropic, the dropped thinking" do
    with_history
    allow(engine).to receive_messages(cache_restart_tokens: 12_400, cache_restart_anthropic?: true)
    text = commands.run("/tone detailed").confirm.text

    expect(text).to eq("The next request reads the whole conversation again (about 12.4k tokens).\n" \
                       "On an `api: anthropic` host, preserved thinking in replies is dropped from then on.\n" \
                       "Nothing changed yet: send `/tone detailed --yes` to apply.")
  end

  it "keeps a plain String or nil reply as it was" do
    with_history
    expect(commands.run("/plain")).to have_attributes(output: "plain", confirm: nil, status: :ok)
    expect(commands.run("/quiet")).to have_attributes(output: nil, confirm: nil, status: :ok)
  end

  it "never asks outside a command (a hook, an init task, a thread of the plugin's)" do
    with_history
    expect(context.cache_confirm("/tone detailed", changed: true)).to be_nil
  end
end
