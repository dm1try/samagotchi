# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "samagotchi/context_note"
require "samagotchi/objectives"
require "samagotchi/session_inbox"
require "samagotchi/plugin/context"

# ctx.objectives (docs/plugins.md, The context): the session's list as the
# conversation and its unabsorbed note files leave it.
RSpec.describe "ctx.objectives" do
  let(:state_dir) { Dir.mktmpdir("ctx-objectives-") }
  let(:messages) { [] }
  let(:session_id) { "s1" }
  let(:ctx) do
    host = Samagotchi::Plugin::Host.new(session_id: -> { session_id }, messages: -> { messages }, state_dir: -> { state_dir })
    Samagotchi::Plugin::Context.new(bundle: "b", label: "plugin.rb (bundle b)", settings: {}, host: host)
  end

  after { FileUtils.rm_rf(state_dir) }

  def note(list)
    Samagotchi::ContextNote.message(note_id: "n1", text: list.text, source: Samagotchi::Objectives::SOURCE,
                                    header: Samagotchi::ContextNote::OBJECTIVES_HEADER, objectives: list.to_payload)
  end

  def list_of(*texts) = Samagotchi::Objectives::List.new.set(texts.map { |text| { text: text } })

  it "is an empty list for a session with none, and makes no folder" do
    expect(ctx.objectives).to be_empty
    expect(Dir.children(state_dir)).to eq([])
  end

  it "is an empty list with no session yet" do
    host = Samagotchi::Plugin::Host.new(session_id: -> {}, messages: -> { [] }, state_dir: -> { state_dir })
    plain = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: host)
    expect(plain.objectives).to be_empty
  end

  it "reads the newest list in the conversation" do
    messages << note(list_of("Old")) << { role: "user", content: "hi" } << note(list_of("New", "Other"))
    expect(ctx.objectives.items.map(&:text)).to eq(%w[New Other])
    expect(ctx.objectives.text).to eq("O1 New\nO2 Other")
  end

  it "reads an unabsorbed edit over the conversation: it is newer" do
    messages << note(list_of("Old"))
    edit = list_of("Edited")
    FileUtils.mkdir_p(Samagotchi::Session.session_dir(session_id, state_dir: state_dir))
    Samagotchi::SessionInbox.write_note(session_id, text: edit.text, source: Samagotchi::Objectives::SOURCE,
                                                    objectives: edit.to_payload, state_dir: state_dir)
    expect(ctx.objectives.items.map(&:text)).to eq(["Edited"])
  end
end

RSpec.describe "ctx.turn_running?" do
  it "follows the host, false without the member" do
    running = true
    ctx = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {},
                                          host: Samagotchi::Plugin::Host.new(turn_running: -> { running }))
    expect(ctx.turn_running?).to be(true)
    running = false
    expect(ctx.turn_running?).to be(false)
    plain = Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: Samagotchi::Plugin::Host.new)
    expect(plain.turn_running?).to be(false)
  end
end
