# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/session"
require "samagotchi/bridge/turn_drawings"

# The owner's GET /api/sessions/:id, byte for byte (characterization):
# pinned before SessionShow#handle_show was split into the shared reads and
# the owner's assembler (Phase A of the participant main page), which must
# keep it identical but for the new +viewer+ key. Two shows: a session with
# no worker (the saved file) and one a live worker's snapshot answers (a
# running turn, a queued prompt, a card, its commands). The golden is the
# pretty JSON with the spec's tmpdir as <TMP>, the session's id as <ID> (its short id <SHORT_ID>) and
# this chi's VERSION as <VERSION>.
#
# Regenerate only after an intended change to the owner's show:
#   UPDATE_GOLDENS=1 bundle exec rspec spec/web/session_show_golden_spec.rb
RSpec.describe Samagotchi::Web::App, "the owner's show (golden)" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:golden_dir) { File.expand_path("../fixtures/show_goldens", __dir__) }
  let(:state_dir) { Dir.mktmpdir("show-goldens") }
  let(:now) { Time.utc(2026, 11, 13, 12, 0, 0) }
  # Three finished turns from the shared drawing scenarios: tool calls and
  # an answer, a plain answer, a pair participant's turn (its author).
  let(:messages) do
    %w[tools_answer plain_answer pair_participant].flat_map do |name|
      JSON.parse(File.read(File.expand_path("../shared/turn_drawings/#{name}.json", __dir__)))["messages"]
          .reject { |m| m["role"] == "system" && m["kind"].nil? }
    end.map { |m| m.transform_keys(&:to_sym) }
  end
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "TestModel", working_directory: "/work/proj", test_run: true, now: now).tap do |s|
      s.messages = messages
      s.save(state_dir: state_dir, now: now)
    end
  end
  let(:live) do
    {
      "snapshot" => {
        "messages" => messages.map { |m| m.transform_keys(&:to_s) },
        "current_turn" => {
          "turn_id" => "t2", "prompt" => "Now the install section", "client_id" => "tab-1", "status" => "running",
          "steps" => [], "pending_question" => nil
        },
        "queued" => [{ "enqueued_id" => "q1", "prompt" => "and the changelog", "client_id" => "tab-1", "delivery" => "queue" }],
        "queued_commands" => [],
        "cards" => [{ "id" => "k1", "kind" => "note", "title" => "A card", "body" => "Card body", "turn_id" => "t1" }],
        "commands" => [{ "name" => "/help", "description" => "Help" }],
        "recap" => nil, "continue_offer" => nil, "init_tasks" => [],
        "event_seq" => 42, "event_id" => "42-7"
      },
      "session_state_snapshot" => {
        "event_seq" => 42, "model_name" => "LiveModel", "status" => "running", "served_model" => "live-served",
        "metrics" => { "turns" => 2, "turn_records" => [{ "id" => "t1", "duration_ms" => 4000 }], "tool_records" => [],
                       "active_turn" => { "id" => "t2" }, "active_tools" => [] }
      }
    }
  end

  after { FileUtils.rm_rf(state_dir) }

  def manager
    Class.new do
      def session_owner(_id, state_dir: nil) = nil
      def read_responses(_id, since_time: nil, state_dir: nil) = []
      def retention_sweep_if_due(state_dir: nil) = nil
    end.new
  end

  def app_with(live)
    app = described_class.new(manager: manager, state_dir: state_dir, bridge_wait_timeout: 0, markdown: false)
    allow(app).to receive(:bridge_get_json).and_call_original
    allow(app).to receive(:bridge_get_json).with(session.id, "snapshot").and_return(live)
    allow(app).to receive(:bridge_event_seq).and_return(nil)
    app
  end

  def show(app)
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}", "HTTP_HOST" => "127.0.0.1", "REMOTE_ADDR" => "127.0.0.1")
    status, _headers, body = app.call(env)
    expect(status).to eq(200)
    JSON.parse(body.first)
  end

  def normalize(text)
    text.gsub(File.realpath(state_dir), "<TMP>").gsub(state_dir, "<TMP>").gsub(session.id, "<ID>").gsub(session.id[0, 8], "<SHORT_ID>")
        .gsub(Samagotchi::VERSION.to_json, %("<VERSION>"))
  end

  # The show as the golden holds it: today's keys only (the viewer is new
  # in Phase A, pinned by its own examples).
  def expect_golden(name, data)
    path = File.join(golden_dir, name)
    text = normalize("#{JSON.pretty_generate(data.except("viewer"))}\n")
    if ENV["UPDATE_GOLDENS"] == "1"
      FileUtils.mkdir_p(golden_dir)
      File.write(path, text)
    end
    expect(text).to eq(File.read(path)), "#{name} differs from its golden (UPDATE_GOLDENS=1 rewrites it)"
  end

  it "keeps the show of a session without a worker" do
    expect_golden("no_worker.json", show(app_with(nil)))
  end

  it "keeps the show a live worker's snapshot answers" do
    expect_golden("live_worker.json", show(app_with(live)))
  end
end
