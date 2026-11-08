# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"

# POST /api/sessions/:id/reload_check: the opt-in reload check's counts
# (reload_check.js), logged as one line per check, never content.
RSpec.describe Samagotchi::Web::App, "POST /api/sessions/:id/reload_check" do
  let(:state_dir) { Dir.mktmpdir("web-reload-check") }
  let(:app) { described_class.new(state_dir: state_dir, bridge_wait_timeout: 0) }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: state_dir).tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:lines) { [] }

  before do
    allow(Samagotchi::Log).to receive(:info).and_call_original
    allow(Samagotchi::Log).to receive(:info).with(:web, anything, any_args) { |_tag, event, **fields| lines << [event, fields] }
  end

  after { FileUtils.rm_rf(state_dir) }

  def post(body)
    env = Rack::MockRequest.env_for("/api/sessions/#{session.id}/reload_check", "HTTP_HOST" => "127.0.0.1", method: "POST",
                                                                                 input: body.is_a?(String) ? body : JSON.generate(body))
    status, _headers, resp = app.call(env)
    [status, resp.each.to_a.join]
  end

  def live_worker(version)
    sidecar = instance_double(Samagotchi::WorkerSidecar, version: version)
    allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(instance_double(Samagotchi::WorkerLink::Live, live?: true, sidecar: sidecar))
  end

  it "answers 204 and logs reload_checked for a check that read the same" do
    expect(post({ turn_id: "8f0c1d2e-aaaa-4bbb-8ccc-0123456789ab", same: true, kinds: [], drawn: false })).to eq([204, ""])

    expect(lines).to eq([["reload_checked", { sid: session.id, turn_id: "8f0c1d2e-aaaa-4bbb-8ccc-0123456789ab", same: true,
                                              drawn: false, worker_version: nil }]])
  end

  it "logs reload_mismatch too, its kinds sorted from the shape's vocabulary only: content and unknown tokens dropped" do
    post({ turn_id: "T1", same: false, kinds: ["row", "answer", "secret text", "row", "<script>"],
           excused: %w[edit-mark made-up command-bubble], explained: true, drawn: true })

    expect(lines.map(&:first)).to eq(%w[reload_checked reload_mismatch])
    expect(lines.last.last).to eq(sid: session.id, turn_id: "T1", drawn: true, worker_version: nil, kinds: "answer,row",
                                  excused: "command-bubble,edit-mark", explained: true)
  end

  it "drops a turn id that isn't one, and keeps none of the body's other fields" do
    post({ turn_id: "a b/../c", same: false, kinds: "row", drawn: "yes", text: "the answer", worker_version: "9.9.9" })

    expect(lines.last.last).to eq(sid: session.id, turn_id: nil, drawn: false, worker_version: nil, kinds: "row", excused: "",
                                  explained: false)
    expect(lines.flatten.map(&:to_s)).not_to include("the answer", "9.9.9")
  end

  it "names the worker's version from chi web's view of it (its sidecar), never the body's" do
    live_worker("0.157.0")
    post({ turn_id: "T1", same: true, kinds: [], drawn: false, worker_version: "1.0.0" })

    expect(lines.last.last).to include(worker_version: "0.157.0")
  end

  it "logs a turn once: another tab's report of it is answered and dropped" do
    report = { turn_id: "T1", same: false, kinds: ["row"], drawn: false }
    expect(post(report)).to eq([204, ""])
    expect(post(report)).to eq([204, ""])
    post(report.merge(turn_id: "T2"))

    expect(lines.map { |event, fields| [event, fields[:turn_id]] })
      .to eq([%w[reload_checked T1], %w[reload_mismatch T1], %w[reload_checked T2], %w[reload_mismatch T2]])
  end

  it "keeps a bounded memory of the turns it logged" do
    seen = Samagotchi::Web::ReloadCheckRoute::Seen.new
    stub_const("Samagotchi::Web::ReloadCheckRoute::Seen::LIMIT", 2)
    expect(%w[a b a c a].map { |key| seen.first?(key) }).to eq([true, true, false, true, true])
  end

  it "refuses a body that isn't a JSON object" do
    expect(post("nope").first).to eq(400)
    expect(lines).to eq([])
  end

  it "keeps its kinds and ACCEPTED ids the page's (history_shape.js KINDS, ACCEPTED)" do
    source = File.read(File.expand_path("../../lib/samagotchi/web/public/history_shape.js", __dir__))
    js = source[/export const KINDS = Object\.freeze\(\[(.*?)\]\)/m, 1].scan(/"([^"]+)"/).flatten
    expect(Samagotchi::Web::ReloadCheckRoute::KINDS).to eq(js)
    ids = source[/export const ACCEPTED = Object\.freeze\(\[(.*?)\n\]\);/m, 1].scan(/^    id: "([^"]+)"/).flatten
    expect(Samagotchi::Web::ReloadCheckRoute::ACCEPTED_IDS).to eq(ids)
  end
end
