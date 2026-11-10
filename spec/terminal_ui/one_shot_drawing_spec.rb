# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "samagotchi/bridge/turn_drawings"

# A one-shot run (chi -p X --non-interactive) owns its session (OwnerLock)
# and writes its turn's drawing, as a worker's Bridge does: one line, its
# rows as live drew them.
RSpec.describe Samagotchi::TerminalUI, "a one-shot turn's drawing" do
  before { allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil) }

  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "alpha" => { host: "alpha.test", port: 1111 } }) }

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "alpha:gemma-small") { example.run } }

  it "leaves one line whose drawing has the turn's hook notice" do
    ui = described_class.new(host_registry: registry, prompt: "list files")
    session = Samagotchi::Session.new_session(mode: "assist", model_name: "alpha:gemma-small", working_directory: Dir.pwd)
    result = instance_double(Samagotchi::LLM::ModelResult, empty_answer?: false, output: "a.txt", resumable?: false)
    allow(ui.engine).to receive(:run_turn) do |sess, prompt, on_event:, **|
      on_event.call({ type: :turn_started, prompt: prompt, turn_id: "t1", origin: {} })
      on_event.call({ type: :generation_started, iteration: 1 })
      on_event.call({ type: :generation_chunk, iteration: 1, text: "a.txt", thinking: "" })
      on_event.call({ type: :hook_notice, hook: "loop-guard", text: "loop: ls repeated", level: :warn })
      sess.messages = [{ role: "user", content: prompt, turn_id: "t1" }, { role: "model", content: "a.txt" }]
      on_event.call({ type: :turn_completed, turn_id: "t1", duration_ms: 5, kept_from: 0, kept_to: 2 })
      result
    end

    expect { ui.send(:run_one_shot_turn, session) }.to output(/a\.txt/).to_stdout.and output(/loop: ls repeated/).to_stderr

    lines = Samagotchi::Bridge::TurnDrawings.read(Samagotchi::Session.session_dir(session.id))
    expect(lines.size).to eq(1)
    expect(lines.first.turn_id).to eq("t1")
    notice = lines.first.drawing["parts"].find { |part| part["kind"] == "notice" }
    expect(notice["event"]).to include("type" => "hook_notice", "hook" => "loop-guard", "text" => "loop: ls repeated")
  end
end
