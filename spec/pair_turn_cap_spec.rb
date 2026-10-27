# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"

# A pair turn (a participant's turn in a working session) stops mid-turn
# once its participant passed their cap: before a generation the Engine asks
# the Worker's check (Engine#participant_cap) and stops the turn on the
# plugins' stop path, with its notice. A review turn and the owner's turns
# are never checked mid-turn.
RSpec.describe Samagotchi::Engine, "a pair turn's mid-turn cap" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:state_dir) { Dir.mktmpdir("pair-turn-cap") }
  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4").tap { |e| e.session_state_dir = state_dir } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd).tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:author) { "p:p_0123abcd" }
  let(:asked) { [] }
  let(:events) { [] }
  let(:generations) { [] }

  after { FileUtils.rm_rf(state_dir) }

  before do
    engine.participant_cap = lambda { |who|
      asked << who
      "Alex reached their $2.00 cap"
    }
    # Two generations, each behind the guard, as both loops ask it.
    allow(kernel).to receive(:run) do |messages, cancel_controller: nil, **|
      2.times do
        kernel.guard_generation
        break if cancel_controller&.cancelled?

        generations << :ran
      end
      Samagotchi::LLM::ModelResult.new(text: "done", conversation: messages.drop(1) + [{ role: "model", content: "done" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [],
                                       canceled: cancel_controller&.cancelled? || false)
    end
  end

  def run(origin) = engine.run_turn(session, "go", origin: origin, on_event: ->(event) { events << event })

  it "stops a participant's pair turn before its next generation, with the stop notice" do
    run({ client_id: "review:p_0123abcd", author: author })

    expect(asked).to eq([author])
    expect(generations).to be_empty
    notice = events.find { |event| event[:type] == :hook_notice }
    expect(notice).to include(hook: "participants", level: :warn, text: "stopped the turn: Alex reached their $2.00 cap")
  end

  it "never checks the owner's turns or a review session's participant turn mid-turn" do
    run({ client_id: "web:tab" })
    session.review = { subjects: ["README.md"] }
    run({ client_id: "review:p_0123abcd", author: author })

    expect(asked).to be_empty
    expect(generations).to eq(%i[ran ran ran ran])
  end
end
