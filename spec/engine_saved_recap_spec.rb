# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"

# The recap saved in <session>/recap.json: loaded for a resumed session, and
# reported with how many turns came after it.
RSpec.describe "Engine saved recap", :recap do
  let(:state_dir) { Dir.mktmpdir }
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "box" => { name: "box", host: "box.test", port: 8081 } }) }

  after { FileUtils.rm_rf(state_dir) }

  def msg(role, content) = { "role" => role, "content" => content }

  def session_with(messages)
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "box:m", working_directory: Dir.pwd)
    session.messages.replace(messages)
    session.save(state_dir: state_dir)
    session
  end

  def engine_for(session)
    engine = Samagotchi::Engine.new(host_registry: registry, model_name: "box:m",
                                    recap: { host_ref: "box", model: "box:small" })
    engine.session_state_dir = state_dir
    engine.session = session
    engine
  end

  def write_recap(session, covered:, digest_of:)
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "recap.json"),
               JSON.generate(text: "We set up Bluefin.", covered: covered,
                             covered_digest: Samagotchi::IdleRecap.digest(digest_of), created_at: "2026-09-24T10:00:00Z"))
  end

  it "reports the saved recap, current when nothing was said since" do
    history = [msg("system", "sys"), msg("user", "Bluefin"), msg("model", "ok"), msg("user", "2+2"), msg("model", "4")]
    session = session_with(history)
    write_recap(session, covered: 5, digest_of: history.last)
    expect(engine_for(session).saved_recap).to eq(text: "We set up Bluefin.", covered: 5, turns_since: 0,
                                                  created_at: "2026-09-24T10:00:00Z")
  end

  it "counts the user turns after it" do
    history = [msg("user", "Bluefin"), msg("model", "ok"), msg("user", "2+2"), msg("model", "4")]
    session = session_with(history + [msg("user", "more"), msg("model", "x"), msg("user", "again"), msg("model", "y")])
    write_recap(session, covered: 4, digest_of: history.last)
    expect(engine_for(session).saved_recap).to include(turns_since: 2)
  end

  it "is nil with no saved recap, or with recap off" do
    session = session_with([msg("user", "hi")])
    expect(engine_for(session).saved_recap).to be_nil
    off = Samagotchi::Engine.new(host_registry: registry, model_name: "box:m")
    off.session = session
    expect(off.saved_recap).to be_nil
  end
end
