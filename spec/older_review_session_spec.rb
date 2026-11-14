# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"

require "samagotchi/session"
require "samagotchi/share_terms"

# A session an older chi started as a review (chi review, the web's Start
# review: its review: key) is an ordinary session now: it loads without an
# error, keeps its key as written (nothing reads it), and is invited to,
# continued and run like any other.
RSpec.describe "an older chi's review session" do
  let(:state_dir) { Dir.mktmpdir("older-review") }
  let(:fixture) { File.expand_path("fixtures/older_review_session.json", __dir__) }

  after { FileUtils.rm_rf(state_dir) }

  def write_session
    text = File.read(fixture).gsub("<TMP>", state_dir).gsub("<VERSION>", "0.171.0").gsub("<NOW>", "2026-11-13T12:00:00Z")
    path = Samagotchi::Session.session_file("00000000-0000-4000-8000-000000000001", state_dir: state_dir)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
    "00000000-0000-4000-8000-000000000001"
  end

  it "loads as an ordinary session, its review: key kept as written on a save" do
    id = write_session
    session = Samagotchi::Session.load(id, state_dir: state_dir)
    expect(session).not_to respond_to(:review?)
    expect(session.review.subjects).to eq(["plan.md"])
    session.save(state_dir: state_dir)
    expect(JSON.parse(File.read(Samagotchi::Session.session_file(id, state_dir: state_dir)))["review"])
      .to eq("subjects" => ["plan.md"])
  end

  it "is invited to as any session: the same warning, no refusal" do
    session = Samagotchi::Session.load(write_session, state_dir: state_dir)
    terms = Samagotchi::ShareTerms.of(session, state_dir: state_dir)
    expect(terms.refusal).to be_nil
    expect(terms.warning).to eq(format(Samagotchi::ShareTerms::WARNING, id: session.id[0, 8], outputs: "0 tool outputs so far"))
  end
end
