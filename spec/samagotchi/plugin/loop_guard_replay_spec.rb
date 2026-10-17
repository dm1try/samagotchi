# frozen_string_literal: true

require "spec_helper"
require "json"
require "samagotchi/guardrails"
require "samagotchi/llm/native_tool_normalizer"
require "samagotchi/testing/rspec"

# The loop-guard plugin (lib/samagotchi/bundles/loop-guard) replayed over
# the turn that looped in session b7089279: the model ran
# `find . -name 'config.yml'` 10 times, with other calls between. Each
# call is built by the normalizer from the session's {name, arguments}, so
# the key sees the real call shape, and goes through a real Guardrails::Gate
# (the bundle test kit's tool_call).
RSpec.describe "The loop-guard plugin, replayed", :bundle do
  let(:fixture) { JSON.parse(File.read(File.expand_path("../../fixtures/loop_guard/b7089279_calls.json", __dir__))) }
  let(:looping) { fixture["turns"][0] }
  let(:calm) { fixture["turns"][1] }
  let(:tool_call) { Struct.new(:name, :arguments) }
  # [message, reason] per stop_turn: the call the turn stopped at.
  let(:stops) { [] }
  let(:known_names_at_66) { ->(entry) { "near miss of samagotchi" if entry["message"] == 66 } }

  # The plugin as chi loads it.
  def plugin(settings = {}) = shipped_bundle("loop-guard", settings: settings)

  # Replays a turn: before_turn, then before/after_tool_call per call, as
  # ToolRunner does. A call the block marks denies first (known-names at
  # priority 50). Stops at a stop_turn, as the turn would.
  # @return [Array<Hash>] {message:, verdict:} per call run
  def replay(bundle, turn, prior_deny: ->(_call) {})
    @bundle = bundle
    bundle.fire(:before_turn, prompt: turn["prompt"])
    turn["calls"].each_with_object([]) do |entry, seen|
      call = Samagotchi::LLM::NativeToolNormalizer.normalize(tool_call.new(entry["name"], entry["arguments"]))
      verdict = Samagotchi::Testing::Verdict.new(call: call)
      if (reason = prior_deny.call(entry))
        verdict.deny!(reason, source: "hook known_names, bundle known-names")
      end
      before = bundle.stops.size
      bundle.tool_call(call, verdict: verdict)
      stopped = bundle.stops.size > before
      stops << [entry["message"], bundle.stops.last.reason] if stopped
      output = verdict.deny? ? "[#{call[:name]}] Error: #{verdict.deny_text}" : entry["output"]
      bundle.fire(:after_tool_call, tool: call[:name], output: output)
      seen << { message: entry["message"], verdict: verdict }
      break seen if stopped
    end
  end

  # What the last replayed plugin said: notices as [text, level], its cards.
  def notices = @bundle.notices.map { |notice| [notice.text, notice.level] }
  def cards = @bundle.cards

  def by_guard(seen) = seen.select { |s| s[:verdict].deny? && s[:verdict].source == "bundle loop-guard" }.map { |s| s[:message] }

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
