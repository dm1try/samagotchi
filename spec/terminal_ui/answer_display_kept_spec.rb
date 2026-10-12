# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"
require_relative "../support/recording_surface"

# The REPL (--no-shared) keeps the turn's conversation as the session's
# messages; the answer's display and refs, which the after_turn hooks put
# on the stored answer (Engine#store_answer_display), stay on it, so a
# save keeps them and the web shows them on a reload.
RSpec.describe Samagotchi::TerminalUI, "after a turn" do
  let(:agent) { described_class.new(client: instance_double(Samagotchi::Client), surface: RecordingSurface.new) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd) }
  let(:refs) { [{ match: "JIRA-1", kind: "issue", target: { id: "JIRA-1" } }] }

  before { allow(agent).to receive(:save_session) }

  def finish(conversation)
    result = Samagotchi::LLM::ModelResult.new(text: conversation.last[:content], conversation: conversation, tool_activity: [])
    agent.send(:finish_turn, session, result, continue: false)
  end

  it "keeps the stored answer's display and display_refs" do
    session.messages = [{ role: "user", content: "go" },
                        { role: "model", content: "see JIRA-1", display: "see [JIRA-1](https://j.test/JIRA-1)", display_refs: refs }]

    finish([{ role: "user", content: "go" }, { role: "model", content: "see JIRA-1" }])

    expect(session.messages.last).to eq(role: "model", content: "see JIRA-1", display: "see [JIRA-1](https://j.test/JIRA-1)",
                                        display_refs: refs)
    expect(agent).to have_received(:save_session).with(session)
  end

  it "keeps them after a reminder turn too" do
    engine = agent.engine
    allow(engine).to receive_messages(due_reminder_names: ["tea"], reminders_due?: true)
    allow(engine).to receive(:clear_due_reminder_names!)
    allow(engine).to receive(:record_activity)
    allow(engine).to receive(:store_model!)
    allow(session).to receive(:save)
    conversation = [{ role: "user", content: "go" }, { role: "model", content: "tea time" }]
    allow(agent).to receive(:run_engine_turn) do
      session.messages = [conversation.first, conversation.last.merge(display: "**tea** time", display_refs: refs)]
      Samagotchi::LLM::ModelResult.new(text: "tea time", conversation: conversation, tool_activity: [])
    end

    agent.send(:run_reminder_turn, session)

    expect(session.messages.last).to eq(role: "model", content: "tea time", display: "**tea** time", display_refs: refs)
    expect(session).to have_received(:save)
  end

  it "keeps nothing when the conversation's last message isn't that answer" do
    session.messages = [{ role: "user", content: "go" }, { role: "model", content: "old", display: "old!" }]

    finish([{ role: "user", content: "go" }, { role: "model", content: "new" }])

    expect(session.messages.last).to eq(role: "model", content: "new")
  end
end
