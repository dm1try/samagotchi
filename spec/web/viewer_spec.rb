# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/viewer"
require "samagotchi/web/principal"
require "samagotchi/grants"

# Who looks at the main page and what they may do (Web::Viewer): the one
# place that decides +can+, stamped on <body> and carried by the owner's
# show. The page's side is spec/web/public/viewer.test.js and
# viewer_boot.test.js.
RSpec.describe Samagotchi::Web::Viewer do
  let(:grant) do
    Samagotchi::Grants::Grant.new(id: "p_0123abcd", session_id: "s1", digest: "d", name: "Alex",
                                  role: "participant", created_at: nil, expires_at: nil, revoked_at: nil,
                                  revoked_by: nil, last_used_at: nil)
  end

  it "gives the owner every capability" do
    viewer = described_class.for(Samagotchi::Web::Principal::OWNER)

    expect(viewer).to be_owner
    expect(viewer.can).to eq(described_class::CAPABILITIES)
    expect(viewer.can).to be_frozen
    expect(described_class::CAPABILITIES).to all(satisfy { |name| viewer.can?(name) })
    expect(viewer.to_h).to eq(kind: "owner", id: nil, name: nil, can: described_class::CAPABILITIES)
  end

  it "gives a participant their own and, of the owner's, only what their routes serve, with their grant's id, name and client id" do
    viewer = described_class.for(Samagotchi::Web::Principal.new(kind: :participant, grant: grant))

    expect(viewer).not_to be_owner
    expect(viewer.to_h).to eq(kind: "participant", id: "p_0123abcd", name: "Alex",
                              can: described_class::PARTICIPANT_CAPABILITIES, client_id: "participant:p_0123abcd")
    expect(described_class::CAPABILITIES.select { |name| viewer.can?(name) }).to eq(%w[working_set images])
    expect(described_class::PARTICIPANT_CAPABILITIES).to all(satisfy { |name| viewer.can?(name) })
  end

  it "stamps the kind and the space-separated list, never a name or an id" do
    expect(described_class::OWNER.body_attributes).to eq("viewer-kind" => "owner",
                                                         "viewer-can" => described_class::CAPABILITIES.join(" "))
    participant = described_class.for(Samagotchi::Web::Principal.new(kind: :participant, grant: grant))
    expect(participant.body_attributes).to eq("viewer-kind" => "participant",
                                              "viewer-can" => described_class::PARTICIPANT_CAPABILITIES.join(" "))
  end

  it "gives a participant Revise on their own answers only: revise_own_turn, never the owner's revise" do
    expect(described_class::PARTICIPANT_CAPABILITIES).to include("revise_own_turn")
    expect(described_class::PARTICIPANT_CAPABILITIES).not_to include("revise")
  end

  it "gives a participant ↑ over their own prompts: own_prompt_history, never the owner's machine-wide prompt_history" do
    expect(described_class::PARTICIPANT_CAPABILITIES).to include("own_prompt_history")
    expect(described_class::PARTICIPANT_CAPABILITIES).not_to include("prompt_history")
    expect(described_class::CAPABILITIES).not_to include("own_prompt_history")
  end

  it "names each capability once, in the page's words (lower snake case); a participant's are none of the owner's" do
    all = described_class::CAPABILITIES | described_class::PARTICIPANT_CAPABILITIES
    expect(described_class::PARTICIPANT_CAPABILITIES).to eq(described_class::PARTICIPANT_CAPABILITIES.uniq)
    expect(described_class::CAPABILITIES).to eq(described_class::CAPABILITIES.uniq)
    expect(all).to all(match(/\A[a-z]+(_[a-z]+)*\z/))
  end
end

RSpec.describe Samagotchi::Web::App, "the owner's viewer" do
  let(:state_dir) { Dir.mktmpdir("web-viewer") }
  let(:app) { described_class.new(state_dir: state_dir, bridge_wait_timeout: 0, markdown: false) }

  after { FileUtils.rm_rf(state_dir) }

  def get(path)
    app.call(Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", "REMOTE_ADDR" => "127.0.0.1"))
  end

  it "is stamped on the main page's <body> at boot" do
    _status, _headers, body = get("/")

    expect(body.first).to include(%(data-viewer-kind="owner"))
    expect(body.first).to include(%(data-viewer-can="#{Samagotchi::Web::Viewer::CAPABILITIES.join(" ")}"))
  end

  it "comes with the session show, next to capabilities" do
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: "/work/proj")
    session.save(state_dir: state_dir)

    status, _headers, body = get("/api/sessions/#{session.id}")

    expect(status).to eq(200)
    data = JSON.parse(body.first)
    expect(data["viewer"]).to eq("kind" => "owner", "id" => nil, "name" => nil, "can" => Samagotchi::Web::Viewer::CAPABILITIES)
    expect(data.keys).to include("capabilities")
  end
end
