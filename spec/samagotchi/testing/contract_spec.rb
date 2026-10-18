# frozen_string_literal: true

require "spec_helper"
require "samagotchi/testing"
require "samagotchi/plugin/sessions"

# The kit records chi's edges in full: a member added to Plugin::Host or
# Hooks::Runtime, or a method added to Plugin::Sessions, fails here until
# the kit has it.
RSpec.describe "The bundle test kit's contract" do
  let(:recorder) { Samagotchi::Testing::Recorder.new(cwd: "/work", messages: [{ role: "user", content: "hi" }]) }
  let(:host) { Samagotchi::Testing::Host.build(recorder, toolkits: -> { %w[full lean] }, tool_names: -> { %w[read] }) }
  let(:label) { "plugin.rb (bundle b)" }
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "b", label: label, settings: {}, host: host) }

  it "sets every Plugin::Host member" do
    unset = Samagotchi::Plugin::Host.members.select { |member| host[member].nil? }
    expect(unset).to be_empty, "Testing::Host.build sets no #{unset.join(", ")}"
  end

  it "sets every Hooks::Runtime member" do
    runtime = Samagotchi::Testing::Runtime.build(recorder)
    unset = Samagotchi::Hooks::Runtime.members.select { |member| runtime[member].nil? }
    expect(unset).to be_empty, "Testing::Runtime.build sets no #{unset.join(", ")}"
  end

  it "gives Testing::Sessions the public methods of Plugin::Sessions, with the same parameters" do
    real = Samagotchi::Plugin::Sessions
    fake = Samagotchi::Testing::Sessions
    signatures = ->(klass) { real.public_instance_methods(false).sort.to_h { |m| [m, klass.instance_method(m).parameters] } }
    expect(fake.public_instance_methods(false)).to include(*real.public_instance_methods(false))
    expect(signatures.call(fake)).to eq(signatures.call(real))
  end

  it "records each Context helper's call with what Context passes" do
    ctx.notify("note", level: :warn, fallback_for: :display)
    id = ctx.card(title: "t", body: "b", actions: [{ label: "Go", command: "/go" }], id: "c1")
    expect(ctx.steer("more")).to be true
    expect(ctx.stop_turn("enough")).to be true
    expect(ctx.stop_generation("cut")).to be true
    recorder.answers << { selected: "a" }
    expect(ctx.ask_user(question: "q?", options: %w[a b], header: "H", allow_freeform: true)).to eq(selected: "a")
    recorder.model_answers << "answer"
    expect(ctx.ask_model(messages: [], prompt: "p", timeout: 3, max_tokens: 9)).to eq("answer")
    expect(ctx.use_toolkit("lean")).to be true
    expect { ctx.use_toolkit("nope") }.to raise_error(ArgumentError, "no toolkit named nope")

    expect(recorder.notices.map(&:to_h)).to eq([{ text: "note", level: :warn, hook: label, fallback_for: :display }])
    expect(id).to eq("c1")
    expect(recorder.cards).to eq([{ type: :card, id: "c1", source: "b", title: "t", body: "b", level: :info,
                                    actions: [{ label: "Go", command: "/go" }] }])
    expect(recorder.steers.map(&:to_h)).to eq([{ text: "more", hook: label }])
    expect(recorder.stops.map(&:to_h)).to eq([{ kind: :turn, reason: "enough", hook: label },
                                              { kind: :generation, reason: "cut", hook: label }])
    expect(recorder.questions.map(&:to_h)).to eq([{ question: "q?", options: %w[a b], header: "H", allow_freeform: true, hook: label, effects: nil }])
    request = recorder.model_requests.first
    expect([request.timeout, request.max_tokens, request.cancel, request.model, request.source]).to eq([3.0, 9, nil, nil, "b"])
    expect(request.request.last).to include(role: "user")
    expect(recorder.toolkit_uses).to eq(["lean"])
    expect(ctx.toolkit).to eq("lean")
    recorder.set(toolkit_staged: false)
    expect(ctx.use_toolkit("full")).to be false
    expect(ctx.toolkit).to eq("lean")
  end

  it "reads the session's values from the recorder at each call" do
    expect([ctx.session_id, ctx.cwd, ctx.model, ctx.model_key, ctx.toolkit, ctx.declared_tools, ctx.frontend])
      .to eq(["test-session", "/work", "test:model", "model", "full", ["read"], :worker])
    expect([ctx.scratch?, ctx.messages_partial?, ctx.cancelled?, ctx.prompt_files]).to eq([false, false, false, []])
    expect(ctx.messages).to eq([{ role: "user", content: "hi" }])

    recorder.set(cwd: "/other", cancelled: true, frontend: :repl, declared_tools: %w[a b], running: false)
    expect([ctx.cwd, ctx.cancelled?, ctx.frontend, ctx.declared_tools]).to eq(["/other", true, :repl, %w[a b]])
    expect(ctx.steer("late")).to be false
    expect { recorder.set(nope: 1) }.to raise_error(ArgumentError, "unknown host values: nope")
  end

  it "gives ctx.http's default cancel only while the session is cancelled (the kit's Host#cancel_controller)" do
    expect(host.cancel_controller.call(handler: false)).to be_nil
    recorder.set(cancelled: true)
    expect(host.cancel_controller.call(handler: true)).to be_cancelled
    recorder.set(cancelled: false)
    expect(host.cancel_controller.call(handler: false)).to be_nil
  end

  it "records a hook's helpers through the Runtime in the same lists, labelled by the hook" do
    registry = Samagotchi::Hooks::Registry.new
    registry.runtime = Samagotchi::Testing::Runtime.build(recorder)
    registry.register_bundle("b", :before_turn, hook_name: "h.rb") do |event|
      event[:notify].call("from hook")
      event[:steer].call("nudge")
      event[:stop_generation].call("cut")
      event[:ask_user].call(question: "q", options: ["x"], effects: { "x" => :permit })
    end
    registry.fire(:before_turn, { type: :before_turn })
    hook = "h.rb (bundle b)"
    expect(recorder.notices.map(&:to_h)).to eq([{ text: "from hook", level: :info, hook: hook, fallback_for: nil }])
    expect(recorder.steers.map(&:hook)).to eq([hook])
    expect(recorder.stops.map(&:to_h)).to eq([{ kind: :generation, reason: "cut", hook: hook }])
    expect(recorder.questions.map(&:hook)).to eq([hook])
    expect(recorder.questions.map(&:effects)).to eq([{ "x" => :permit }])
  end

  it "records every vote on a Testing::Verdict, kept or not" do
    verdict = Samagotchi::Testing::Verdict.new(call: { name: "x" })
    verdict.ask!("maybe", scopes: %w[once]).deny!("no", advice: "do y").deny!("no again")
    expect(verdict.votes.map { |vote| [vote.decision, vote.reason, vote.options] })
      .to eq([[:ask, "maybe", { scopes: %w[once] }], [:deny, "no", { advice: "do y" }], [:deny, "no again", {}]])
    expect(verdict.reason).to eq("no")
  end
end
