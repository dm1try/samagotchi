# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/objectives"

# The page's objectives: the session read's fold and each list note's entry.
RSpec.describe Samagotchi::Web::App, "objectives" do
  let(:tmpdir) { Dir.mktmpdir("web-objectives") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: tmpdir).tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:app) { described_class.new(state_dir: state_dir, session_class: Samagotchi::Session, bridge_wait_timeout: 0) }
  let(:list) { Samagotchi::Objectives::List.new.set([{ text: "A" }, { text: "B" }]) }

  after { FileUtils.rm_rf(tmpdir) }

  def show
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}", "HTTP_HOST" => "127.0.0.1")
    _status, _headers, chunks = app.call(env)
    JSON.parse(chunks.to_a.join)
  end

  def note(id, list)
    Samagotchi::ContextNote.message(note_id: id, text: list.text, source: "objectives",
                                    header: Samagotchi::ContextNote::OBJECTIVES_HEADER, objectives: list.to_payload)
  end

  it "has no objectives key for a session with no list" do
    session.messages = [{ role: "user", content: "hi" }]
    session.save(state_dir: state_dir)
    expect(show).not_to have_key("objectives")
  end

  it "reads the fold, and an unabsorbed edit as pending" do
    session.messages = [note("n1", list)]
    session.save(state_dir: state_dir)
    expect(show["objectives"]).to include("pending" => false)

    edited = list.mark("O1", "done")
    Samagotchi::SessionInbox.write_note(session.id, text: edited.text, source: "objectives", objectives: edited.to_payload, state_dir: state_dir)
    body = show
    expect(body["objectives"]).to include("pending" => true)
    expect(body["objectives"]["items"].first).to include("id" => "O1", "status" => "done")
  end

  it "gives each list note its entry: the first the list, a later one what changed" do
    session.messages = [note("n1", list), note("n2", list.mark("O2", "dropped"))]
    session.save(state_dir: state_dir)
    entries = show["messages"].select { |m| m["role"] == "note" }.map { |m| m["objectives"] }
    expect(entries.first).not_to have_key("changes")
    expect(entries.last["changes"]).to eq([{ "id" => "O2", "kind" => "dropped", "text" => "B" }])
  end
end
