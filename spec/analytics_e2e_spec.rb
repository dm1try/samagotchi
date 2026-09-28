# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"
require "spec_helper"

# A minimal client double that replays a realistic two-chunk generation: each
# chunk carries a server timings payload (as llama.cpp streams), exercising the
# real KernelLoop -> Engine#run_turn -> SessionObserver -> SessionMetrics path
# rather than hand-fed events.
class AnalyticsChunkClient
  def complete(_prompt, **kwargs)
    on_chunk = kwargs[:on_chunk]
    on_chunk&.call(
      content: "hello",
      payload: { "content" => "hello", "timings" => { "prompt_n" => 42, "predicted_n" => 7 } }
    )
    on_chunk&.call(
      content: " world",
      payload: { "content" => " world", "timings" => { "prompt_n" => 42, "predicted_n" => 9 } }
    )
    "hello world"
  end
end

RSpec.describe "SessionMetrics end-to-end (real KernelLoop flow)" do
  around do |example|
    @xdg = Dir.mktmpdir
    original_xdg = ENV["XDG_STATE_HOME"]
    original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["XDG_STATE_HOME"] = @xdg
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "gemma4"
    example.run
    ENV["XDG_STATE_HOME"] = original_xdg
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
  end

  it "captures server-reported tokens through a full run_turn" do
    engine = Samagotchi::Engine.new(mode: :assist, client: AnalyticsChunkClient.new, model_name: "gemma4")
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd)

    engine.run_turn(session, "hi")

    snap = engine.metrics.snapshot
    # Single generation: running MAX of prompt_n (42), per-generation MAX of
    # predicted_n (9) summed across the one generation.
    expect(snap[:turns]).to eq(1)
    expect(snap[:tokens_in]).to eq(42)
    expect(snap[:tokens_out]).to eq(9)
    expect(snap[:tokens_total]).to eq(51)
    expect(snap[:token_source]).to eq(:server)
    expect(snap[:tool_calls_total]).to eq(0)
  end

  it "persists the analytics summary next to the session file" do
    engine = Samagotchi::Engine.new(mode: :assist, client: AnalyticsChunkClient.new, model_name: "gemma4")
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd)

    engine.run_turn(session, "hi")

    dir = Samagotchi::Session.session_dir(session.id)
    path = File.join(dir, "analytics.json")
    expect(File.exist?(path)).to be(true)

    written = JSON.parse(File.read(path))
    expect(written["tokens_in"]).to eq(42)
    expect(written["token_source"]).to eq("server")
    expect(written["turn_records"]).to include(hash_including("status" => "completed"))
    expect(written["active_turn"]).to be_nil
  end

  it "persists into the engine's session state dir, not the default one" do
    engine = Samagotchi::Engine.new(mode: :assist, client: AnalyticsChunkClient.new, model_name: "gemma4")
    engine.session_state_dir = state_dir = File.join(@xdg, "elsewhere")
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd)

    engine.run_turn(session, "hi")

    expect(File).to exist(File.join(state_dir, session.id, "analytics.json"))
    expect(File).not_to exist(File.join(Samagotchi::Session.session_dir(session.id), "analytics.json"))
  end
end
