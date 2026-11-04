# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session"
require "samagotchi/engine_peers"

# What the objectives tool checks a move against: the session's list now.
RSpec.describe "Samagotchi::Engine::PeerView#objectives" do
  let(:tmpdir) { Dir.mktmpdir("peer-view-objectives") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: tmpdir).tap { |s| s.save(state_dir: tmpdir) }
  end
  let(:engine) { Struct.new(:session, :peer_state_dir).new(session, tmpdir) }
  let(:view) { Samagotchi::Engine::PeerView.new(engine) }
  let(:list) { Samagotchi::Objectives::List.new.set([{ text: "Two coffees" }]) }

  after { FileUtils.rm_rf(tmpdir) }

  it "is nil outside a session" do
    engine.session = nil

    expect(view.objectives).to be_nil
  end

  it "is empty for a session with no list" do
    expect(view.objectives).to be_empty
  end

  it "reads the session's list note" do
    session.messages = [Samagotchi::ContextNote.message(note_id: "n1", text: list.text, source: Samagotchi::Objectives::SOURCE,
                                                        header: Samagotchi::ContextNote::OBJECTIVES_HEADER,
                                                        objectives: list.to_payload)]

    expect(view.objectives.find("O1").text).to eq("Two coffees")
  end

  it "reads a pending edit's list, which is newer" do
    Samagotchi::SessionInbox.write_note(session.id, text: list.text, source: Samagotchi::Objectives::SOURCE,
                                                    objectives: list.to_payload, state_dir: tmpdir)

    expect(view.objectives.find("O1").text).to eq("Two coffees")
  end
end
