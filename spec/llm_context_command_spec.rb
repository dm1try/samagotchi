# frozen_string_literal: true

require "samagotchi/session_commands"
require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/turn_flow"

# /llm-context: the session's own LLM context values, shown with where each
# came from, set and reset; what a switch does is in its reply.
RSpec.describe Samagotchi::SessionCommands, "/llm-context" do
  before do
    allow_any_instance_of(Samagotchi::Client).to receive(:server_props).and_return(nil)
    allow(Samagotchi::ConfigFile).to receive(:model_settings).and_return(models)
    Samagotchi::ConfigFile.reset_warnings!
    engine.session = session
  end

  let(:models) { { "qwen3-14b" => { llm_context_strategy: [:stale], llm_context_budget_tokens: 48_000 } } }
  let(:registry) { Samagotchi::HostRegistry.new(hosts_config: { "beta" => { host: "beta.test", port: 2222 } }) }
  let(:engine) { Samagotchi::Engine.new(host_registry: registry, model_name: "beta:Qwen3-14B") }
  let(:saved) { [] }
  let(:commands) do
    described_class.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine), default_model: "beta:Qwen3-14B",
                        save: ->(session) { saved << session.llm_context })
  end
  let(:body) { (1..40).map { |n| "#{n}: line #{n} of the cart" }.join("\n") }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "beta:Qwen3-14B", working_directory: "/work/shop")
  end

  def chat_read(id, tool_id)
    [{ role: "model", content: "", tool_calls: [{ id: id, name: "read", arguments: { "path" => "lib/cart.rb" } }] },
     { role: "tool_response", content: "[read]\n#{body}", tool_call_id: id, tool_ids: [tool_id] }]
  end

  def run(line) = commands.run(line)

  it "shows what the next turn runs under and where each value came from" do
    result = run("/llm-context")

    expect(result.status).to eq(:ok)
    expect(result.changed).to eq([])
    expect(result.output).to eq(<<~TEXT.chomp)
      llm context: stale (models: qwen3-14b)
        apply:  payoff (llm_context.apply)
        budget: 48000 tokens (models: qwen3-14b)
        this session's own: none (follows the model, its host, then llm_context.*)
    TEXT
    expect(saved).to be_empty
  end

  it "sets the session's own values, saves them, and shows them from the session" do
    result = run("/llm-context strategy stale forget apply turn_end budget 64k")

    expect(result.changed).to eq([:llm_context])
    expect(session.llm_context).to eq(Samagotchi::LLMContextOverride.new(strategy: %i[stale forget], apply: :turn_end,
                                                                         budget_tokens: 64_000))
    expect(saved).to eq([session.llm_context])
    expect(result.output).to start_with(<<~TEXT.chomp)
      llm context: stale, forget (the session)
        apply:  turn_end (the session)
        budget: 64000 tokens (the session)
        this session's own: strategy stale, forget; apply turn_end; budget 64000
      From the next turn's start (a running turn keeps its own).
    TEXT
    expect(result.output).to include("forget_outputs joins the tool list and the system prompt (and outputs show their ids): " \
                                     "the next request re-reads the whole prompt (a full cache break).")
    expect(engine.llm_context_explained.resolved.forget?).to be(true)
    # /stats shows the same budget (/stats' snapshot feeds it).
    expect(engine.stats_snapshot[:llm_context]).to include(budget_tokens: 64_000, budget_where: "the session")
  end

  it "takes none and off as values, unsets one with default, and goes back to the model's with reset" do
    run("/llm-context strategy none budget off")
    expect(engine.llm_context_explained.resolved.to_h).to include(strategy: :none, source: :session, budget_tokens: nil)

    run("/llm-context budget default")
    expect(session.llm_context).to eq(Samagotchi::LLMContextOverride.new(strategy: []))
    expect(engine.llm_context_explained.resolved.budget_tokens).to eq(48_000)

    result = run("/llm-context reset")
    expect(session.llm_context).to be_nil
    expect(result.output).to start_with("llm context: stale (models: qwen3-14b)")
    expect(engine.llm_context_explained.resolved.source).to eq(:model_setting)
  end

  it "says how many past reads turning stale on stages, and when they go in under the apply rule" do
    models.clear
    session.messages = [{ role: "user", content: "go" }, *chat_read("c1", "t1"), *chat_read("c2", "t2"), *chat_read("c3", "t3")]

    result = run("/llm-context strategy stale apply next_request")

    expect(result.output).to include("stale: 2 past reads already superseded go in as one batch under apply next_request: " \
                                     "at the next request.")
    expect(result.output).not_to include("forget_outputs")
  end

  it "says a layer turned off sends its stubs whole again, and that nothing changed when nothing did" do
    session.messages = [{ role: "user", content: "go" }, *chat_read("c1", "t1"), *chat_read("c2", "t2")]
    edit = Samagotchi::LLMContextEdit.new(id: "t1", kind: :stale, note: "lib/cart.rb: superseded", by: "chi",
                                          staged_at: "x", applied_at: "x")
    Samagotchi::LLMContextEdit.store(session.messages[2], edit)

    expect(run("/llm-context strategy stale").output).to include("(no change to what the next turn runs under)")
    expect(run("/llm-context strategy stale,forget").output).to include("forget_outputs joins")
    expect(run("/llm-context strategy stale").output)
      .to include("forget_outputs leaves the tool list", "Its past forget_outputs calls and their results stay in the history.")
    expect(run("/llm-context strategy none").output)
      .to include("stale's 1 stub goes out whole again (a cache break from the first; the originals stay in the session, " \
                  "and turning stale back on brings the stubs back).")
  end

  it "refuses a line that isn't one, changing nothing" do
    result = run("/llm-context strategy stale,summarize")
    expect(result.status).to eq(:error)
    expect(result.output).to include("unknown llm_context strategy summarize")

    expect(run("/llm-context speed fast").output).to include("unknown /llm-context word speed", "usage: /llm-context")
    expect(run("/llm-context apply turn_end payoff").output).to include("apply takes one value")
    expect(run("/llm-context budget").output).to include("budget needs a value")
    expect(session.llm_context).to be_nil
    expect(saved).to be_empty
  end

  it "is a session command the worker runs between turns (not anytime)" do
    entry = described_class.builtin_registry.lookup("/llm-context strategy stale")

    expect(entry.name).to eq("/llm-context")
    expect(entry.anytime).to be(false)
    expect(described_class.builtin_registry.command?("/llm-contextx")).to be(false)
  end
end
