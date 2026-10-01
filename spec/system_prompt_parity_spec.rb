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

  it "TerminalUI fully-built system prompt == Engine#system_prompt" do
    session = ui.send(:messages_for,
      Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd))
    expect(session[0][:content]).to eq(engine.system_prompt)
  end

  it "a resumed REPL session keeps a context note at the head and puts the system prompt before it" do
    note = { role: "system", kind: "note", note_id: "n1", content: "[CONTEXT NOTE from cli]\nx\n[END NOTE]" }
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd)
    session.messages = [note, { role: "user", content: "hi" }]
    terminal = ui
    terminal.instance_variable_set(:@resume_session, true)

    messages = terminal.send(:messages_for, session)

    expect(messages.map { |m| m[:role] }).to eq(%w[system system user])
    expect(messages[0][:content]).to eq(engine.system_prompt)
    expect(messages[1]).to eq(note)
  end
end
