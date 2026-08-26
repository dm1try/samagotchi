# frozen_string_literal: true
require "samagotchi/terminal_ui"
require "samagotchi/engine"
require "samagotchi/session"

RSpec.describe "Engine/TerminalUI system-prompt parity" do
  around do |example|
    original = ENV["SAMAGOTCHI_MODEL"]
    ENV["SAMAGOTCHI_MODEL"] = "Gemma-4B-it"
    example.run
    ENV["SAMAGOTCHI_MODEL"] = original
  end

  def ui
    Samagotchi::TerminalUI.new(mode: "assist", client: instance_double(Samagotchi::Client), profile: "gemma4")
  end

  def engine
    Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client),
                           kernel: instance_double(Samagotchi::KernelLoop), profile: "gemma4")
  end

  it "TerminalUI base prompt == Engine canonical base prompt" do
    expect(ui.send(:assist_system_prompt)).to eq(engine.send(:assist_system_prompt))
  end

  it "TerminalUI fully-built system prompt == Engine#system_prompt" do
    session = ui.send(:messages_for,
      Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd))
    expect(session[0][:content]).to eq(engine.system_prompt)
  end
end
