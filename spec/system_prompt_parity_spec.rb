# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "samagotchi/engine"
require "samagotchi/session"
require "support/test_kernel"

RSpec.describe "Engine/TerminalUI system-prompt parity" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  def ui
    Samagotchi::TerminalUI.new(client: test_client, profile: "gemma4")
  end

  def engine
    Samagotchi::Engine.new(client: test_client,
                           kernel: test_kernel, profile: "gemma4")
  end

  it "TerminalUI's Engine builds the same system prompt as a bare Engine" do
    expect(ui.engine.system_prompt).to eq(engine.system_prompt)
  end
end
