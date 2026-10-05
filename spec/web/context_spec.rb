# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"
require "samagotchi/web/app"
require "samagotchi/session"

# The session bar's attached context: list, one source's text, and detach
# (a session's source) or mute (a project's, for this session).
RSpec.describe Samagotchi::Web::App, "attached context" do
  let(:tmpdir) { Dir.mktmpdir("web-context") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:repo) { File.join(tmpdir, "app").tap { |d| FileUtils.mkdir_p(File.join(d, ".git")) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: repo).tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }
  let(:project) { Samagotchi::ContextSources.project_location_for(session.project_root, state_dir: state_dir) }
  let(:app) { described_class.new(state_dir: state_dir, session_class: Samagotchi::Session, bridge_wait_timeout: 0) }

  after { FileUtils.rm_rf(tmpdir) }

  def call(path, method: "GET")
    status, _headers, chunks = app.call(Rack::MockRequest.env_for(path, "HTTP_HOST" => "127.0.0.1", method: method))
    [status, JSON.parse(chunks.to_a.join)]
  end

  def add(location, name, cmd: nil, why: nil, hint: nil)
    location.add(Samagotchi::ContextSources::Source.new(name: name, cmd: cmd, every_seconds: cmd ? 60 : nil, why: why,
                                                        hint: hint, scope: location.scope, added_by: "cli", created_at: nil))
  end

  def push(location, name, text, summary: nil)
    location.record_text(name, Samagotchi::ContextSources::Fetched.new(text: text, summary: summary, wake: false, hint: nil))
  end

  it "lists the sources with what the chips show, never a command" do
    add(own, "pr-1", why: "the PR", hint: "https://x/1")
    push(own, "pr-1", "body", summary: "2 new comments")
    add(project, "ci", cmd: "secret-token-cmd")
    own.record_error("pr-1", "exit 1: boom")
    own.update_subscription("pr-1") { |sub| sub.with(read: Samagotchi::ContextSources.revision_of("body")) }

    status, body = call("/api/sessions/#{session.id}/context")

    expect(status).to eq(200)
    expect(body["sources"]).to match([
      include("name" => "pr-1", "scope" => "session", "kind" => "push", "why" => "the PR",
              "hint" => "https://x/1", "summary" => "2 new comments",
              "error" => "exit 1: boom", "has_text" => true, "unread" => false, "muted" => false),
      include("name" => "ci", "scope" => "project", "kind" => "cmd", "has_text" => false,
              "unread" => false)
    ])
    expect(JSON.generate(body)).not_to include("secret-token-cmd")
  end

  it "shows one source's text, and 404s an unknown or bad name and an unknown session" do
    add(own, "notes")
    push(own, "notes", "the text")

    expect(call("/api/sessions/#{session.id}/context/notes")).to match([200, include("text" => "the text", "unread" => true)])
    expect(call("/api/sessions/#{session.id}/context/nope").first).to eq(404)
    expect(call("/api/sessions/#{session.id}/context/Bad..Name").first).to eq(404)
    expect(call("/api/sessions/11111111-2222-3333-4444-555555555555/context").first).to eq(404)
  end

  it "detaches a session's source and mutes a project's for this session only" do
    add(own, "mine")
    add(project, "ours")

    expect(call("/api/sessions/#{session.id}/context/mine", method: "DELETE")).to eq([200, { "status" => "detached", "name" => "mine" }])
    expect(call("/api/sessions/#{session.id}/context/ours", method: "DELETE")).to eq([200, { "status" => "muted", "name" => "ours" }])
    expect(own.source("mine")).to be_nil
    expect(project.source("ours")).not_to be_nil
    expect(own.muted?("ours")).to be(true)
    expect(call("/api/sessions/#{session.id}/context")[1]["sources"]).to match([include("name" => "ours", "muted" => true)])
  end
end
