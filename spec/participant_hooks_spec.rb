# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"

# Hooks and plugins on a participant's turn: every event of the turn says
# whose it is (author:), ctx.turn_author too; the owner's events carry no
# author:, as before.
RSpec.describe "hooks on a participant's turn" do
  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  let(:state_dir) { Dir.mktmpdir("participant-hooks") }
  let(:client) { test_client }
  let(:kernel) { test_kernel(client: client) }
  let(:engine) { Samagotchi::Engine.new(client: client, kernel: kernel, profile: "gemma4").tap { |e| e.session_state_dir = state_dir } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd).tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:seen) { [] }
  let(:ctx_author) { [] }

  after { FileUtils.rm_rf(state_dir) }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:run) do |messages, **|
      ctx_author << engine.send(:plugin_host).turn_author.call
      Samagotchi::LLM::ModelResult.new(text: "done", conversation: messages.drop(1) + [{ role: "model", content: "done" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
    end
  end

  def run(origin)
    %i[session_start before_turn after_turn].each do |name|
      engine.register_hook(name) { |event| seen << [name, event.key?(:author) ? event[:author] : :none] }
    end
    engine.run_turn(session, "Is step 3 safe?", origin: origin)
  end

  it "gives a participant's turn's hooks author: and ctx.turn_author" do
    run({ client_id: "review:p_0123abcd", author: "p:p_0123abcd" })
    expect(seen).to include([:before_turn, "p:p_0123abcd"], [:after_turn, "p:p_0123abcd"])
    expect(ctx_author).to eq(["p:p_0123abcd"])
    expect(engine.send(:plugin_host).turn_author.call).to be_nil
  end

  it "gives the owner's turn's hooks no author: key" do
    run({ client_id: "web:t" })
    expect(seen.map(&:last).uniq).to eq([:none])
    expect(ctx_author).to eq([nil])
  end

  it "leaves the owner's due reminders out of a participant's turn, for the owner's next one" do
    queue = engine.instance_variable_get(:@reminder_queue)
    allow(queue).to receive(:inject!).and_return([])
    run({ client_id: "review:p_0123abcd", author: "p:p_0123abcd" })
    expect(queue).not_to have_received(:inject!)
    run({ client_id: "web:t" })
    expect(queue).to have_received(:inject!).once
  end
end
