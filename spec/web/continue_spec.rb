# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "fileutils"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/session_manager"

# POST /api/sessions with continues: the next link of a session chain
# (SessionManager.continue_session; spec/session_continue_spec.rb has its rules).
RSpec.describe Samagotchi::Web::App, "POST /api/sessions continues" do
  around do |example|
    Dir.mktmpdir("web-continue") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  let(:state_dir) { File.join(@tmp, "state") }
  let(:folder) { File.join(@tmp, "proj").tap { |dir| FileUtils.mkdir_p(dir) } }
  let(:app) { described_class.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0) }

  before { allow(Process).to receive(:spawn).and_return(12_345) }

  def create(body)
    status, _headers, chunks = app.call(Rack::MockRequest.env_for("/api/sessions", "HTTP_HOST" => "127.0.0.1",
                                                                                   method: "POST", input: JSON.generate(body)))
    [status, JSON.parse(chunks.join)]
  end

  def previous_link
    Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: folder).tap do |s|
      s.first_preview = "you are coordinator again"
      s.messages = [{ role: "user", content: "you are coordinator again" }, { role: "assistant", content: "ok" }]
      s.save(state_dir: state_dir)
    end
  end

  def archived?(id) = Samagotchi::ArchiveStore.archived?(Samagotchi::Session.session_dir(id, state_dir: state_dir))

  it "starts an idle next link in the previous one's folder and model, with its preview, and archives the previous one" do
    previous = previous_link

    status, body = create(continues: previous.id[0, 8], idle: true)

    expect(status).to eq(201), body.inspect
    expect(body).to include("continues" => previous.id, "working_directory" => folder, "model_name" => "main:gemma-small",
                            "status" => "idle", "first_preview" => "you are coordinator again")
    expect(archived?(previous.id)).to be(true)
    expect(archived?(body["id"])).to be(false)
  end

  it "answers a continued link with 409 continued and the link that continues it, so the page opens that one" do
    previous = previous_link
    _, first = create(continues: previous.id, idle: true)

    status, body = create(continues: previous.id, idle: true)

    expect(status).to eq(409)
    expect(body).to include("error" => "continued", "next_id" => first["id"])
    expect(body["detail"]).to include("continued already, by #{first["id"][0, 8]}")
  end

  it "refuses dir, model or llm_context beside continues, a continues that is no id, and an unknown session" do
    previous = previous_link

    expect(create(continues: previous.id, idle: true, model: "x", dir: folder))
      .to eq([400, { "error" => "invalid_continues",
                     "detail" => "continues takes the previous session's folder, model and llm_context; leave out dir, model" }])
    expect(create(continues: 7, idle: true).first).to eq(400)
    expect(create(continues: "feedbeef", idle: true)).to eq([404, { "error" => "not_found", "detail" => "no session feedbeef" }])
    expect(archived?(previous.id)).to be(false)
    expect(Process).not_to have_received(:spawn)
  end

  it "answers 400 ambiguous_id for a prefix of several sessions" do
    %w[aaaa1111-0000-4000-8000-000000000001 aaaa2222-0000-4000-8000-000000000002].each do |id|
      previous_link.tap { |s| FileUtils.mv(Samagotchi::Session.session_file(s.id, state_dir: state_dir), Samagotchi::Session.session_file(id, state_dir: state_dir)) }
      data = JSON.parse(File.read(Samagotchi::Session.session_file(id, state_dir: state_dir)))
      File.write(Samagotchi::Session.session_file(id, state_dir: state_dir), JSON.generate(data.merge("id" => id)))
    end

    status, body = create(continues: "aaaa", idle: true)
    expect(status).to eq(400)
    expect(body).to include("error" => "ambiguous_id")
    expect(body["detail"]).to include("session id aaaa matches 2 sessions")
  end

  it "doesn't answer 404 for an error after the new link started (it did start)" do
    previous = previous_link
    hub = double("hub")
    allow(hub).to receive(:touch).and_raise(ArgumentError, "hub hiccup")
    app = described_class.new(manager: Samagotchi::SessionManager, state_dir: state_dir, bridge_wait_timeout: 0, hub: hub)

    status = begin
      app.call(Rack::MockRequest.env_for("/api/sessions", "HTTP_HOST" => "127.0.0.1", method: "POST",
                                                          input: JSON.generate(continues: previous.id, idle: true))).first
    rescue ArgumentError
      :raised
    end
    expect(status).not_to eq(404)
    expect(Samagotchi::Session.list(state_dir: state_dir).map(&:continues)).to include(previous.id)
  end

  it "answers 409 open_children naming a delegate still open that can't move (a chi REPL holds it)" do
    previous = previous_link
    child = Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: folder,
                                            parent_id: previous.id, delegate: true)
    child.save(state_dir: state_dir)
    Samagotchi::SessionInbox.write_output(Samagotchi::Session.session_dir(child.id, state_dir: state_dir), "done")
    lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(child.id, state_dir: state_dir), kind: "tui")

    status, body = create(continues: previous.id, idle: true)

    expect(status).to eq(409)
    expect(body).to include("error" => "open_children", "ids" => [child.id])
    expect(archived?(previous.id)).to be(false)
  ensure
    lock&.release
  end
end
