# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session_manager"

# POST /api/sessions with review: a review session (ReviewStart), fresh in
# a folder or a review fork of a session.
RSpec.describe Samagotchi::Web::App, "POST /api/sessions with review" do
  let(:state_dir) { Dir.mktmpdir("web-review") }
  let(:project) { Dir.mktmpdir("web-review-project") }
  let(:app) { described_class.new(state_dir: state_dir, bridge_wait_timeout: 0) }

  before do
    allow(Process).to receive(:spawn).and_return(12_345)
    system("git", "init", "-q", project, exception: true)
    FileUtils.mkdir_p(File.join(project, "docs"))
    File.write(File.join(project, "docs", "plan.md"), "# Plan\n")
    File.write(File.join(project, ".env"), "TOKEN=x\n")
  end

  after do
    FileUtils.rm_rf(state_dir)
    FileUtils.rm_rf(project)
  end

  def create(body)
    env = Rack::MockRequest.env_for("/api/sessions", "HTTP_HOST" => "127.0.0.1", method: "POST", input: JSON.generate(body),
                                                     "CONTENT_TYPE" => "application/json")
    status, _headers, resp = app.call(env)
    [status, JSON.parse(resp.each.to_a.join)]
  end

  def saved(id) = Samagotchi::Session.load(id, state_dir: state_dir)

  it "starts an idle review session in dir with its subjects, the create's setup fields too" do
    status, json = create("review" => { "subjects" => ["docs/plan.md"] }, "dir" => project, "model" => "main:gemma-small",
                          "thinking" => "high")
    expect(status).to eq(201), json.inspect
    session = saved(json["id"])
    expect(session.review.subjects).to eq(["docs/plan.md"])
    expect(session.status).to eq("idle")
    expect(session.thinking).not_to be_nil
  end

  it "starts a review fork of a session, which takes its folder" do
    source = Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: project)
    source.save(state_dir: state_dir)
    status, json = create("review" => { "from" => source.id[0, 8] })
    expect(status).to eq(201), json.inspect
    expect(saved(json["id"]).review).to eq(Samagotchi::SessionReview.new(subjects: [], from: source.id))
  end

  it "answers 400 invalid_review for a secret subject, a bad shape, a prompt beside it, dir beside from; 404 an unknown source" do
    expect(create("review" => { "subjects" => [".env"] }, "dir" => project))
      .to eq([400, { "error" => "invalid_review", "detail" => format(Samagotchi::ReviewStart::SUBJECT_REFUSED, ".env") }])
    expect(create("review" => { "subjects" => "docs/plan.md" }, "dir" => project).dig(1, "error")).to eq("invalid_review")
    expect(create("review" => { "subjects" => ["docs/plan.md"] }, "dir" => project, "prompt" => "hi").dig(1, "detail"))
      .to eq("a review session starts idle; leave out prompt")
    expect(create("review" => { "from" => "abcd" }, "dir" => project).dig(1, "detail")).to include("leave out dir")
    expect(create("review" => { "from" => "00000000-0000-4000-8000-000000000000" }).first).to eq(404)
    expect(Dir.glob(File.join(state_dir, "*.json"))).to be_empty
  end
end
