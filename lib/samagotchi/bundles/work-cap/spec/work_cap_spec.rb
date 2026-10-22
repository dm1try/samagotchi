# frozen_string_literal: true

require "json"
require "samagotchi/testing/rspec"

# The work-cap plugin through the bundle test kit: ctx.usage (and ctx.cost
# for the totals) set by the test, the Continue / Stop question answered
# from the queue, the state file in the example's sandbox.
RSpec.describe "The work-cap bundle", :bundle do
  let(:state_file) { File.join(sandbox.state_dir, "plugins", "work-cap", "sessions", "test-session.json") }

  def plugin(settings = { "default" => { "tool_calls" => 400 } }, usage: {}, cost: nil, session_settings: {})
    shipped_bundle("work-cap", settings: settings, host: { usage: usage, cost: cost }, session_settings: session_settings)
  end

  def calls(count, turns: 1, **rest) = { turns: turns, tool_calls_by_tool: { "read" => count }, **rest }

  def minutes(value) = (value * 60_000).round

  def generation(bundle) = bundle.fire(:before_generation, iteration: 1)

  def notices(bundle) = bundle.notices.map { |notice| [notice.text, notice.level] }

  def state = JSON.parse(File.read(state_file))

  describe "the check before each generation" do
    it "reads no usage and asks nothing with no cap" do
      reads = 0
      bundle = plugin({}, usage: -> { reads += 1 })
      3.times { generation(bundle) }
      expect(reads).to eq(0)
      expect([bundle.questions, bundle.notices, bundle.stops]).to all(be_empty)
    end

    it "does nothing under the cap and under the warning" do
      bundle = plugin(usage: calls(100))
      generation(bundle)
      expect([bundle.questions, bundle.notices, bundle.stops]).to all(be_empty)
    end

    it "warns the user once at warn_at of the cap, and again after the cap is raised" do
      bundle = plugin(usage: calls(320))
      2.times { generation(bundle) }
      expect(notices(bundle)).to eq([["320 of 400 tool calls (80%)", :warn]])

      bundle.command("/workcap 500")
      bundle.set(usage: calls(410))
      generation(bundle)
      expect(notices(bundle).last).to eq(["410 of 500 tool calls (82%)", :warn])
      expect(bundle.questions).to be_empty
    end

    it "doesn't warn with warn_at off" do
      bundle = plugin({ "default" => { "tool_calls" => 400 }, "warn_at" => "off" }, usage: calls(399))
      generation(bundle)
      expect(bundle.notices).to be_empty
    end

    it "asks at the cap naming the session's totals; Continue raises it by a step, saves it and lets the turn go on" do
      bundle = plugin(usage: calls(412, turns: 6, active_ms: minutes(47.5)), cost: 1.2)
      bundle.answer({ selected: ["Continue"] })
      generation(bundle)

      question = bundle.questions.last
      expect(question).to have_attributes(header: "Work cap", options: %w[Continue Stop],
                                          question: "Work cap reached: 412 tool calls of 400 (6 turns, 47 min active, " \
                                                    "$1.20). Continue raises it to 800.")
      # A parent agent's Continue spends: refused under guardrails.parent_answers: hard.
      expect(question.effects).to eq("Continue" => :spend, "Stop" => :deny)
      expect(state).to eq("tool_calls" => { "cap" => 800.0, "step" => 400.0 })
      expect(bundle.stops).to be_empty
      expect(notices(bundle).last).to eq(["cap raised to 800 tool calls", :info])

      generation(bundle)
      expect(bundle.questions.size).to eq(1)
    end

    it "raises past a big overshoot in whole steps, so Continue never asks again at once; by index too" do
      bundle = plugin(usage: calls(1000))
      bundle.answer({ selected: [], selected_indices: [0] })
      generation(bundle)
      expect(bundle.questions.last.question).to end_with("Continue raises it to 1200.")
      expect(state["tool_calls"]["cap"]).to eq(1200.0)
      generation(bundle)
      expect(bundle.questions.size).to eq(1)
    end

    it "stops the turn with a card on Stop" do
      bundle = plugin(usage: calls(400, turns: 3, active_ms: minutes(12)))
      bundle.answer({ selected: ["Stop"] })
      generation(bundle)

      expect(bundle.turn_stops.map(&:reason)).to eq(["work cap reached (400 tool calls of 400)"])
      card = bundle.cards.last
      expect(card).to include(title: "work-cap stopped the turn", level: :warn)
      expect(card[:body]).to include("Used 400 tool calls of 400 (3 turns, 12 min active)", "`/workcap N` raises",
                                     "`/workcap off` removes both")
      expect(File).not_to exist(state_file)
    end

    it "stops the turn with a card when no one can be asked (nil)" do
      bundle = plugin(usage: calls(500))
      generation(bundle)
      expect(bundle.questions.size).to eq(1)
      expect(bundle.turn_stops.size).to eq(1)
      expect(bundle.cards.last[:title]).to eq("work-cap stopped the turn")
    end

    it "caps active minutes: work time from ctx.usage, its own question and raise" do
      bundle = plugin({ "default" => { "minutes" => 60 } }, usage: calls(30, turns: 2, active_ms: minutes(61)))
      bundle.answer({ selected: ["Continue"] })
      generation(bundle)
      expect(bundle.questions.last.question)
        .to eq("Work cap reached: 61 active minutes of 60 (2 turns, 30 tool calls). Continue raises it to 120.")
      expect(state).to eq("minutes" => { "cap" => 120.0, "step" => 60.0 })
    end

    it "asks once when both meters are reached, naming both, and Continue raises each" do
      bundle = plugin({ "default" => { "tool_calls" => 10, "minutes" => 5 } },
                      usage: calls(12, turns: 1, active_ms: minutes(6)))
      bundle.answer({ selected: ["Continue"] })
      generation(bundle)
      expect(bundle.questions.size).to eq(1)
      expect(bundle.questions.last.question)
        .to eq("Work cap reached: 12 tool calls of 10, 6 active minutes of 5 (1 turn). " \
               "Continue raises them to 20 tool calls and 10 active minutes.")
      expect(state).to eq("tool_calls" => { "cap" => 20.0, "step" => 10.0 }, "minutes" => { "cap" => 10.0, "step" => 5.0 })
      expect(notices(bundle).last).to eq(["caps raised to 20 tool calls and 10 active minutes", :info])
    end

    it "warns per meter, each once" do
      bundle = plugin({ "default" => { "tool_calls" => 10, "minutes" => 10 } }, usage: calls(8, active_ms: minutes(9)))
      2.times { generation(bundle) }
      expect(notices(bundle)).to eq([["8 of 10 tool calls (80%)", :warn], ["9 of 10 active minutes (90%)", :warn]])
    end

    it "leaves the polling tools' calls and time out (ignore_tools), and takes its own list" do
      usage = { tool_calls_by_tool: { "read" => 5, "task_wait" => 50, "delegate_result" => 3 },
                tool_ms_by_tool: { "read" => minutes(1), "task_wait" => minutes(100) } }
      bundle = plugin({ "default" => { "tool_calls" => 10, "minutes" => 60 } }, usage: usage)
      generation(bundle)
      expect(bundle.questions).to be_empty
      expect(bundle.command("/workcap")).to eq("work-cap: 5 of 10 tool calls, 1 of 60 active minutes (0 turns)")

      own = plugin({ "default" => { "tool_calls" => 10 }, "ignore_tools" => ["read"] }, usage: usage)
      generation(own)
      expect(own.questions.last.question).to start_with("Work cap reached: 53 tool calls of 10")
    end

    it "leaves a long blocking delegate call (waiting on its child) out of the minutes and the calls" do
      usage = { turns: 1, tool_calls_by_tool: { "read" => 2, "delegate" => 1 },
                tool_ms_by_tool: { "read" => minutes(1), "delegate" => minutes(60) } }
      bundle = plugin({ "default" => { "tool_calls" => 3, "minutes" => 30 } }, usage: usage)
      generation(bundle)
      expect(bundle.questions).to be_empty
      expect(bundle.command("/workcap")).to eq("work-cap: 2 of 3 tool calls, 1 of 30 active minutes (1 turn)")
    end

    it "uses child: for a delegate, else default:, per meter" do
      settings = { "default" => { "tool_calls" => 400, "minutes" => 30 }, "child" => { "tool_calls" => 50 } }
      bundle = plugin(settings, usage: calls(60, active_ms: minutes(10)))
      allow(bundle.ctx).to receive(:delegate?).and_return(true)
      expect(bundle.command("/workcap")).to eq("work-cap: 60 of 50 tool calls, 10 of 30 active minutes (1 turn)")

      other = plugin(settings, usage: calls(60, active_ms: minutes(10)))
      allow(other.ctx).to receive(:delegate?).and_return(false)
      generation(other)
      expect(other.questions).to be_empty
      expect(other.command("/workcap")).to eq("work-cap: 60 of 400 tool calls, 10 of 30 active minutes (1 turn)")
    end

    it "takes a session's own value (chi --set work-cap.tool_calls=N) over child: and default:, under the state file" do
      bundle = plugin({ "default" => { "tool_calls" => 400 }, "child" => { "tool_calls" => 200 } },
                      usage: calls(6), session_settings: { tool_calls: 5 })
      allow(bundle.ctx).to receive(:delegate?).and_return(true)
      bundle.answer({ selected: ["Continue"] })
      generation(bundle)
      expect(bundle.questions.last.question).to eq("Work cap reached: 6 tool calls of 5 (1 turn, <1 min active). Continue raises it to 10.")

      bundle.command("/workcap 40")
      expect(bundle.command("/workcap")).to eq("work-cap: 6 of 40 tool calls (1 turn, <1 min active)")
    end

    it "takes off, 0 or a negative number (--set work-cap.tool_calls=off) as no cap for the session, over default:" do
      [false, 0, -1].each do |value|
        bundle = plugin(usage: calls(900), session_settings: { tool_calls: value })
        generation(bundle)
        expect(bundle.questions).to be_empty, value.inspect
        expect(bundle.command("/workcap")).to eq("work-cap: no cap (1 turn, 900 tool calls, <1 min active)")
      end
    end

    it "lists tool_calls and minutes as its session settings, numbers or off (--set refuses another)" do
      expect { shipped_bundle("work-cap", session_settings: { default: 1 }) }
        .to raise_error(ArgumentError, /work-cap takes tool_calls, minutes|work-cap takes minutes, tool_calls/)
      expect { shipped_bundle("work-cap", session_settings: { tool_calls: "many" }) }
        .to raise_error(ArgumentError, /work-cap takes a number \(or off\) for tool_calls, not "many"/)
    end

    it "warns once when a value can't be read, and uses the next one instead of no cap" do
      bundle = plugin({ "tool_calls" => "many", "default" => { "tool_calls" => 10 } }, usage: calls(12))
      bundle.answer({ selected: ["Stop"] })
      2.times { generation(bundle) }
      expect(notices(bundle).first)
        .to eq(["work-cap: tool_calls: \"many\" isn't a number or off; using default.tool_calls: (10)", :warn])
      expect(notices(bundle).count { |text, _| text.include?("isn't a number") }).to eq(1)
      expect(bundle.questions.first.question).to include("12 tool calls of 10")
    end

    it "warns when a child: or default: isn't a mapping, or nothing reads: no cap, but not silently" do
      bundle = plugin({ "default" => 400 }, usage: calls(900))
      generation(bundle)
      expect(bundle.questions).to be_empty
      expect(notices(bundle)).to eq([["work-cap: default: 400 isn't a number or off; no cap", :warn]])

      delegate = plugin({ "child" => { "minutes" => "soon" }, "default" => { "minutes" => 60 } })
      allow(delegate.ctx).to receive(:delegate?).and_return(true)
      generation(delegate)
      expect(notices(delegate).first)
        .to eq(["work-cap: child.minutes: \"soon\" isn't a number or off; using default.minutes: (60)", :warn])
    end

    it "counts an empty key (nil) as unset and falls through to the next source, with no notice" do
      bundle = plugin({ "tool_calls" => nil, "child" => { "tool_calls" => nil }, "default" => { "tool_calls" => 10 } },
                      usage: calls(12))
      allow(bundle.ctx).to receive(:delegate?).and_return(true)
      bundle.answer({ selected: ["Stop"] })
      generation(bundle)
      expect(bundle.questions.last.question).to include("12 tool calls of 10")
      expect(bundle.notices).to be_empty

      empty_default = plugin({ "default" => nil, "minutes" => nil }, usage: calls(900))
      generation(empty_default)
      expect([empty_default.questions, empty_default.notices]).to all(be_empty)
    end

    it "keeps off, false and 0 as an explicit no cap that stops the resolution" do
      ["off", false, 0, "0"].each do |value|
        bundle = plugin({ "tool_calls" => value, "default" => { "tool_calls" => 10 } }, usage: calls(12))
        generation(bundle)
        expect([bundle.questions, bundle.notices]).to all(be_empty), value.inspect
      end
    end

    it "reads minutes written 90m, 1.5h or 90 min in config.yml" do
      { "90m" => 90, "1.5h" => 90, "90 min" => 90, "2h" => 120 }.each do |text, cap|
        bundle = plugin({ "default" => { "minutes" => text } })
        expect(bundle.command("/workcap")).to eq("work-cap: 0 of #{cap} active minutes (0 turns, 0 tool calls)"), text
        expect(bundle.notices).to be_empty, text
      end
    end

    it "resolves the caps once per session: delegate? is read once across generations" do
      bundle = plugin({ "default" => { "tool_calls" => 400 }, "child" => { "tool_calls" => 50 } }, usage: calls(1))
      allow(bundle.ctx).to receive(:delegate?).and_return(false)
      4.times { generation(bundle) }
      expect(bundle.ctx).to have_received(:delegate?).once

      bundle.set(session_id: "another")
      generation(bundle)
      expect(bundle.ctx).to have_received(:delegate?).twice
    end

    it "resolves again when the settings change, the state file still winning per meter" do
      bundle = plugin({ "default" => { "tool_calls" => 10, "minutes" => 30 } }, usage: calls(7))
      generation(bundle)
      expect(bundle.questions).to be_empty

      allow(bundle.ctx).to receive(:settings).and_return({ "default" => { "tool_calls" => 5, "minutes" => 30 } })
      bundle.answer({ selected: ["Stop"] })
      generation(bundle)
      expect(bundle.questions.last.question).to include("7 tool calls of 5")

      bundle.command("/workcap 20")
      allow(bundle.ctx).to receive(:settings).and_return({ "default" => { "tool_calls" => 3, "minutes" => 30 } })
      expect(bundle.command("/workcap")).to start_with("work-cap: 7 of 20 tool calls")
    end

    it "works with no session (the totals zero), and /workcap can't set a cap then" do
      bundle = plugin(usage: nil)
      bundle.set(session_id: nil)
      generation(bundle)
      expect(bundle.questions).to be_empty
      expect(bundle.command("/workcap 5")).to eq("work-cap: no session yet")
    end
  end

  describe "/workcap" do
    it "shows the totals with no cap" do
      expect(plugin({}, usage: calls(12, turns: 2, active_ms: minutes(3)), cost: 0.5).command("/workcap"))
        .to eq("work-cap: no cap (2 turns, 12 tool calls, 3 min active, $0.50)")
    end

    it "sets the tool-call cap with N, the minutes with Nm or Nh, each saved apart" do
      bundle = plugin({}, usage: calls(12, active_ms: minutes(3)))
      expect(bundle.command("/workcap 400")).to eq("work-cap: tool calls cap set to 400 (12 so far)")
      expect(bundle.command("/workcap 90m")).to eq("work-cap: active minutes cap set to 90 (3 so far)")
      expect(bundle.command("/workcap 2h")).to eq("work-cap: active minutes cap set to 120 (3 so far)")
      expect(state).to eq("tool_calls" => { "cap" => 400.0, "step" => 400.0 }, "minutes" => { "cap" => 120.0, "step" => 120.0 })
      expect(bundle.command("/workcap")).to eq("work-cap: 12 of 400 tool calls, 3 of 120 active minutes (1 turn)")
    end

    it "turns both caps off for this session over the config" do
      bundle = plugin({ "default" => { "tool_calls" => 10, "minutes" => 1 } }, usage: calls(90, active_ms: minutes(9)))
      expect(bundle.command("/workcap off")).to eq("work-cap: no cap for this session")
      expect(state).to eq("tool_calls" => { "cap" => nil }, "minutes" => { "cap" => nil })
      generation(bundle)
      expect(bundle.questions).to be_empty
    end

    it "answers a bad value with the usage line" do
      bundle = plugin
      %w[five -1 5x 0m].each do |arg|
        expect(bundle.command("/workcap #{arg}")).to eq(bundle.namespace::Plugin::USAGE), arg
      end
      expect(File).not_to exist(state_file)
    end

    it "logs why the command failed (a state file it can't write), and says so" do
      bundle = plugin
      blocker = File.join(sandbox.root, "not-a-dir")
      File.write(blocker, "")
      allow(bundle.ctx).to receive(:data_dir).and_return(blocker)
      allow(bundle.ctx.log).to receive(:warn)
      expect(bundle.command("/workcap 5")).to start_with("work-cap: ")
      expect(bundle.ctx.log).to have_received(:warn).with(:workcap_command_failed, error: start_with("Errno::"))
    end

    it "keeps the cap across a reload of the bundle (the same data dir)" do
      plugin(usage: calls(1)).command("/workcap 40")
      reloaded = plugin(usage: calls(39))
      expect(reloaded.command("/workcap")).to eq("work-cap: 39 of 40 tool calls (1 turn, <1 min active)")
    end
  end
end
