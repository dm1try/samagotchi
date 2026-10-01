# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/guardrails"
require "samagotchi/llm/native_tool_normalizer"
require "support/plugin_handler_ctx"

# The loop-guard plugin (lib/samagotchi/bundles/loop-guard) replayed over
# the turn that looped in session b7089279: the model ran
# `find . -name 'config.yml'` 10 times, with other calls between. Each
# call is built by the normalizer from the session's {name, arguments}, so
# the key sees the real call shape, and gets a real Guardrails::Verdict.
RSpec.describe "The loop-guard plugin, replayed" do
  let(:source) { File.expand_path("../../../lib/samagotchi/bundles/loop-guard/plugin.rb", __dir__) }
  let(:fixture) { JSON.parse(File.read(File.expand_path("../../fixtures/loop_guard/b7089279_calls.json", __dir__))) }
  let(:looping) { fixture["turns"][0] }
  let(:calm) { fixture["turns"][1] }
  let(:notices) { [] }
  let(:cards) { [] }
  let(:stops) { [] }
  let(:ctx) do
    Struct.new(:notices, :cards) do
      prepend PluginHandlerCtx

      def notify(text, level: :info) = notices << [text, level]
      def card(**card) = cards << card
    end.new(notices, cards)
  end
  let(:tool_call) { Struct.new(:name, :arguments) }

  # The plugin as the loader builds it: its file in a module of its own,
  # register(chi) collecting the chi.on blocks.
  def plugin(settings = {})
    mod = Module.new
    mod.module_eval(File.read(source), source)
    hooks = Hash.new { |h, k| h[k] = [] }
    chi = Object.new
    chi.define_singleton_method(:on) { |event, priority: 100, &block| hooks[event] << block }
    mod::Plugin.new(settings).register(chi)
    hooks
  end

  def fire(hooks, event)
    hooks[event[:type]].each { |block| ctx.with_event(event) { block.arity == 1 ? block.call(event) : block.call(event, ctx) } }
  end

  # Replays a turn: before_turn, then before/after_tool_call per call, as
  # ToolRunner does. A call the block marks denies first (known-names at
  # priority 50). Stops at a stop_turn, as the turn would.
  # @return [Array<Hash>] {message:, verdict:} per call run
  def replay(hooks, turn, prior_deny: ->(_call) {})
    fire(hooks, { type: :before_turn, prompt: turn["prompt"] })
    turn["calls"].each_with_object([]) do |entry, seen|
      call = Samagotchi::LLM::NativeToolNormalizer.normalize(tool_call.new(entry["name"], entry["arguments"]))
      verdict = Samagotchi::Guardrails::Verdict.new(call: call)
      if (reason = prior_deny.call(entry))
        verdict.deny!(reason, source: "hook known_names, bundle known-names")
      end
      stopped = false
      fire(hooks, { type: :before_tool_call, call: call.dup, guardrail: verdict,
                    stop_turn: ->(reason) { stops << [entry["message"], reason]; stopped = true } })
      output = verdict.deny? ? "[#{call[:name]}] Error: #{verdict.deny_text}" : entry["output"]
      fire(hooks, { type: :after_tool_call, tool: call[:name], output: output })
      seen << { message: entry["message"], verdict: verdict }
      break seen if stopped
    end
  end

  def by_guard(seen) = seen.select { |s| s[:verdict].deny? && s[:verdict].source == "bundle loop-guard" }.map { |s| s[:message] }
  let(:known_names_at_66) { ->(entry) { "near miss of samagotchi" if entry["message"] == 66 } }

  it "denies the 3rd identical find (message 48) with advice, no flapping, and stops the turn at the 4th deny (56)" do
    seen = replay(plugin, looping, prior_deny: known_names_at_66)

    expect(by_guard(seen)).to eq([48, 50, 54, 56])
    first = seen.find { |s| s[:message] == 48 }[:verdict]
    expect(first.rule).to be_nil
    expect(first.deny_text).to eq(
      "denied by guardrail (bundle loop-guard): repeated call. The user was not asked. " \
      "You already ran this exact call 2 times this turn and it returned the same result each time (exit: 0). " \
      "Don't repeat it. Try a different approach, or tell the user what you're stuck on."
    )
    expect(stops).to eq([[56, "the model kept repeating the same calls"]])
    expect(seen.last[:message]).to eq(56)
    expect(notices).to eq([["loop: execute find . -name 'config.yml' 2>/dev/null repeated, denied", :warn]])
    expect(cards.size).to eq(1)
    expect(cards.first).to include(title: "loop-guard stopped the turn", level: :warn)
    expect(cards.first[:body]).to include("- `execute find . -name 'config.yml' 2>/dev/null`: 6 times, the same result each time (exit: 0)")
    expect(cards.first[:body]).not_to include("ls -la")
  end

  it "keeps denying every later repeat without a stop, and a known-names deny (message 66) is no result" do
    seen = replay(plugin("stop_after" => 100), looping, prior_deny: known_names_at_66)

    expect(by_guard(seen)).to eq([48, 50, 54, 56, 60, 62, 68, 70])
    expect(seen.find { |s| s[:message] == 66 }[:verdict].source).to eq("hook known_names, bundle known-names")
    expect(stops).to be_empty
  end

  it "records no result for another voter's deny, so it neither passes the next repeat nor counts as one" do
    find = looping["calls"].first
    turn = { "prompt" => "x", "calls" => [find, find, find.merge("message" => 1), find] }
    seen = replay(plugin, turn, prior_deny: ->(entry) { "rule says no" if entry["message"] == 1 })

    expect(seen.map { |s| s[:verdict].source }).to eq([nil, nil, "hook known_names, bundle known-names", "bundle loop-guard"])

    denied = looping["calls"].find { |c| c["message"] == 66 }
    seen = replay(plugin, { "prompt" => "y", "calls" => [denied] * 4 }, prior_deny: ->(_) { "near miss" })
    expect(by_guard(seen)).to be_empty
  end

  it "only warns in notify mode, once per call" do
    seen = replay(plugin("mode" => "notify"), looping, prior_deny: known_names_at_66)

    expect(by_guard(seen)).to be_empty
    expect(stops).to be_empty
    expect(notices).to eq([["loop: execute find . -name 'config.yml' 2>/dev/null repeated 2 times with the same result", :warn]])
  end

  it "denies nothing in the next turn, which did not loop, and resets at before_turn" do
    hooks = plugin
    replay(hooks, looping, prior_deny: known_names_at_66)
    seen = replay(hooks, calm)

    expect(seen.map { |s| s[:message] }).to eq([74, 76, 78, 80, 82, 84, 86])
    expect(by_guard(seen)).to be_empty
  end

  it "lets the ignored polling tools repeat freely" do
    wait = { "message" => 1, "name" => "task_wait", "arguments" => { "task_id" => "t1" }, "output" => "[task_wait]\nrunning" }
    seen = replay(plugin, { "prompt" => "x", "calls" => [wait] * 6 })
    expect(by_guard(seen)).to be_empty

    seen = replay(plugin("ignore_tools" => []), { "prompt" => "x", "calls" => [wait] * 3 })
    expect(by_guard(seen)).to eq([1])
  end

  it "keys by the arguments with whitespace collapsed, and a new result lets the call run again" do
    a = { "message" => 1, "name" => "execute", "arguments" => { "command" => "git  status " }, "output" => "[execute]\nclean" }
    b = a.merge("message" => 2, "arguments" => { "command" => "git status" })
    changed = a.merge("message" => 3, "output" => "[execute]\nstdout:\ndirty")
    seen = replay(plugin, { "prompt" => "x", "calls" => [a, b, a] })
    expect(seen.map { |s| s[:verdict].deny? }).to eq([false, false, true])

    seen = replay(plugin, { "prompt" => "x", "calls" => [a, changed, b] })
    expect(seen.map { |s| s[:verdict].deny? }).to eq([false, false, false])
  end
end
