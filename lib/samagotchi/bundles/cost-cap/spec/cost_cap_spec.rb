# frozen_string_literal: true

require "json"
require "samagotchi/testing/rspec"

# The cost-cap plugin through the bundle test kit: ctx.cost set by the
# test (bundle.set(cost:)), the Continue / Stop question answered from the
# queue, the state file in the example's sandbox.
RSpec.describe "The cost-cap bundle", :bundle do
  let(:state_file) { File.join(sandbox.state_dir, "plugins", "cost-cap", "sessions", "test-session.json") }

  def plugin(settings = { "default" => 3.0 }, cost: 0.0) = shipped_bundle("cost-cap", settings: settings, host: { cost: cost })

  def generation(bundle) = bundle.fire(:before_generation, iteration: 1)

  def notices(bundle) = bundle.notices.map { |notice| [notice.text, notice.level] }

  def state = JSON.parse(File.read(state_file))

  describe "the check before each generation" do
    it "reads no cost and asks nothing with no cap" do
      reads = 0
      bundle = plugin({}, cost: -> { reads += 1 })
      3.times do
        generation(bundle)
        bundle.fire(:after_generation, iteration: 1)
      end
      expect(reads).to eq(0)
      expect(bundle.questions).to be_empty
      expect(bundle.notices).to be_empty
    end

    it "does nothing under the cap and under the warning" do
      bundle = plugin(cost: 1.0)
      generation(bundle)
      expect([bundle.questions, bundle.notices, bundle.stops]).to all(be_empty)
    end

    it "warns the user once at warn_at of the cap, and again after the cap is raised" do
      bundle = plugin(cost: 2.41)
      2.times { generation(bundle) }
      expect(notices(bundle)).to eq([["$2.41 of $3.00 spent (80%)", :warn]])

      bundle.command("/cap 4")
      bundle.set(cost: 3.3)
      generation(bundle)
      expect(notices(bundle).last).to eq(["$3.30 of $4.00 spent (82%)", :warn])
      expect(bundle.questions).to be_empty
    end

    it "doesn't warn with warn_at off" do
      bundle = plugin({ "default" => 3.0, "warn_at" => "off" }, cost: 2.9)
      generation(bundle)
      expect(bundle.notices).to be_empty
    end

    it "asks at the cap; Continue raises it by a step, saves it and lets the turn go on" do
      bundle = plugin(cost: 3.04)
      bundle.answer({ selected: ["Continue"] })
      generation(bundle)

      question = bundle.questions.last
      expect(question).to have_attributes(header: "Cost cap", options: %w[Continue Stop],
                                          question: "Cost cap reached: $3.04 spent of $3.00. Continue raises it to $6.00.")
      # A parent agent's Continue spends: refused under guardrails.parent_answers: hard.
      expect(question.effects).to eq("Continue" => :spend, "Stop" => :deny)
      expect(state).to eq("cap" => 6.0, "step" => 3.0)
      expect(bundle.stops).to be_empty
      expect(notices(bundle).last).to eq(["cap raised to $6.00", :info])

      generation(bundle)
      expect(bundle.questions.size).to eq(1)
    end

    it "takes Continue as a plain String or by its index, and raises past a big overshoot in whole steps" do
      bundle = plugin(cost: 7.5)
      bundle.answer({ selected: "Continue" })
      generation(bundle)
      expect(bundle.questions.last.question).to end_with("Continue raises it to $9.00.")
      expect(state["cap"]).to eq(9.0)

      bundle.set(cost: 9.0)
      bundle.answer({ selected: [], selected_indices: [0] })
      generation(bundle)
      expect(state["cap"]).to eq(12.0)
    end

    it "shows a sub-dime cap and spend with up to four decimals, not as $0.00" do
      bundle = plugin({ "default" => 0.003 }, cost: 0.0066525)
      bundle.answer({ selected: ["Stop"] })
      generation(bundle)
      expect(bundle.questions.last.question).to eq("Cost cap reached: $0.0067 spent of $0.003. Continue raises it to $0.009.")
      expect(bundle.command("/cap")).to start_with("cost-cap: $0.0067 spent of $0.003 (reported $0.0067, estimated $0.00")
    end

    it "stops the turn with a card on Stop" do
      bundle = plugin(cost: { reported: 3.0, estimated: 0.04, side: 0.02 })
      bundle.answer({ selected: ["Stop"] })
      generation(bundle)

      expect(bundle.turn_stops.map(&:reason)).to eq(["cost cap reached ($3.04 of $3.00)"])
      card = bundle.cards.last
      expect(card).to include(title: "cost-cap stopped the turn", level: :warn)
      expect(card[:body]).to include("reported $3.00, estimated $0.04, side $0.02", "`/cap N` raises it",
                                     "`/cap off` removes it")
      expect(File).not_to exist(state_file)
    end

    it "stops the turn with a card when no one can be asked (nil)" do
      bundle = plugin(cost: 5.0)
      generation(bundle)
      expect(bundle.questions.size).to eq(1)
      expect(bundle.turn_stops.size).to eq(1)
      expect(bundle.cards.last[:title]).to eq("cost-cap stopped the turn")
    end

    it "warns once when the cost isn't known, and never asks" do
      bundle = plugin(cost: { known: false })
      3.times { generation(bundle) }
      expect(notices(bundle)).to eq([["the $3.00 cap can't be enforced: test:model reports no cost and has no price",
                                      :warn]])
      expect(bundle.questions).to be_empty
    end

    it "warns after the first unpriced generation, so a one-generation turn gets the notice too" do
      # Known (nothing ran) at the first generation's start, unknown once it ran unpriced.
      ran = false
      bundle = plugin(cost: -> { ran ? { known: false } : 0.0 })
      generation(bundle)
      expect(bundle.notices).to be_empty

      ran = true
      bundle.fire(:after_generation, iteration: 1)
      expect(bundle.notices.size).to eq(1)
      generation(bundle)
      bundle.fire(:after_generation, iteration: 2)
      expect(bundle.notices.size).to eq(1)
    end

    it "never asks or stops after a generation, even past the cap (the next generation asks)" do
      bundle = plugin(cost: 5.0)
      bundle.fire(:after_generation, iteration: 1)
      expect([bundle.questions, bundle.stops]).to all(be_empty)
    end

    it "uses child: for a delegate, else default:" do
      bundle = plugin({ "default" => 5.0, "child" => 2.0 }, cost: 2.5)
      allow(bundle.ctx).to receive(:delegate?).and_return(true)
      generation(bundle)
      expect(bundle.questions.last.question).to include("$2.50 spent of $2.00")

      other = plugin({ "default" => 5.0, "child" => 2.0 }, cost: 2.5)
      allow(other.ctx).to receive(:delegate?).and_return(false)
      generation(other)
      expect(other.questions).to be_empty
    end

    it "uses default: for a delegate when child: is absent" do
      bundle = plugin({ "default" => 2.0 }, cost: 2.5)
      allow(bundle.ctx).to receive(:delegate?).and_return(true)
      generation(bundle)
      expect(bundle.questions.size).to eq(1)
    end

    it "takes a session's own cap: (chi --set cost-cap.cap=N) over child: and default:, under the state file" do
      bundle = shipped_bundle("cost-cap", settings: { "default" => 5.0, "child" => 2.0 }, session_settings: { cap: 0.5 },
                                          host: { cost: 0.6 })
      allow(bundle.ctx).to receive(:delegate?).and_return(true)
      expect(bundle.command("/cap")).to start_with("cost-cap: $0.60 spent of $0.50")
      bundle.answer({ selected: ["Continue"] })
      generation(bundle)
      expect(bundle.questions.last.question).to end_with("Continue raises it to $1.00.")
      expect(state).to eq("cap" => 1.0, "step" => 0.5)

      bundle.command("/cap 4")
      expect(bundle.command("/cap")).to start_with("cost-cap: $0.60 spent of $4.00")
    end

    it "takes cap: false, 0 or a negative number (--set cost-cap.cap=off, 0, -1) as no cap for the session, over default:" do
      bundle = shipped_bundle("cost-cap", settings: { "default" => 0.1 }, session_settings: { cap: false }, host: { cost: 1.0 })
      generation(bundle)
      expect(bundle.questions).to be_empty
      expect(bundle.command("/cap")).to eq("cost-cap: no cap ($1.00 spent)")
      [0, -1].each do |cap|
        expect(shipped_bundle("cost-cap", settings: { "default" => 0.1 }, session_settings: { cap: cap }, host: { cost: 1.0 })
          .command("/cap")).to eq("cost-cap: no cap ($1.00 spent)"), cap.to_s
      end
    end

    it "lists cap as its one session setting, a number or off (the manifest types it, so --set refuses another value)" do
      expect { shipped_bundle("cost-cap", session_settings: { default: 1 }) }
        .to raise_error(ArgumentError, "session_settings cost-cap.default: cost-cap takes cap")
      expect { shipped_bundle("cost-cap", session_settings: { cap: "five" }) }
        .to raise_error(ArgumentError, "session_settings cost-cap.cap: cost-cap takes a number (or off) for cap, not \"five\"")
    end

    it "reads a cap written .5, 1e1 or $2 (a value config.yml's YAML or an older session kept as text)" do
      { { "default" => "1e1" } => [10.5, "$10.50 spent of $10.00"], { "default" => 3.0, "cap" => ".5" } => [0.6, "$0.60 spent of $0.50"],
        { "child" => "$2", "default" => "2E1" } => [2.5, "$2.50 spent of $2.00"] }.each do |settings, (cost, asked)|
        bundle = plugin(settings, cost: cost)
        allow(bundle.ctx).to receive(:delegate?).and_return(true)
        generation(bundle)
        expect(bundle.questions.last&.question).to include(asked), settings.inspect
        expect(bundle.notices).to be_empty
      end
    end

    it "warns once when cap: can't be read, and uses child: or default: instead of no cap" do
      bundle = plugin({ "cap" => "five", "default" => 5.0 }, cost: 9.0)
      bundle.answer({ selected: ["Stop"] })
      2.times { generation(bundle) }
      expect(notices(bundle).first).to eq(["cost-cap: cap: \"five\" isn't a number or off; using default: ($5.00)", :warn])
      expect(notices(bundle).count { |text, _| text.include?("isn't a number") }).to eq(1)
      expect(bundle.questions.first.question).to include("$9.00 spent of $5.00")

      delegate = plugin({ "cap" => true, "child" => "2x", "default" => 1.0 }, cost: 9.0)
      allow(delegate.ctx).to receive(:delegate?).and_return(true)
      generation(delegate)
      expect(notices(delegate).first)
        .to eq(["cost-cap: cap: true and child: \"2x\" aren't a number or off; using default: ($1.00)", :warn])
    end

    it "reads 5. as 5 on any Ruby, and takes an infinite cap (1e400) as one it can't read" do
      bundle = plugin({ "default" => "5." }, cost: 6.0)
      expect(%w[5. 5.e1 2.5e1].map { |text| bundle.namespace::Plugin.float_text(text) }).to eq(%w[5.0 5.0e1 2.5e1])
      generation(bundle)
      expect(bundle.questions.last.question).to include("$6.00 spent of $5.00")

      %w[1e400 $1e400].each do |text|
        unread = plugin({ "default" => text }, cost: 9.0)
        generation(unread)
        expect(unread.questions).to be_empty, text
        expect(notices(unread)).to eq([["cost-cap: default: #{text.inspect} isn't a number or off; no cap", :warn]]), text
      end
      infinite = plugin({ "default" => Float::INFINITY }, cost: 9.0)
      generation(infinite)
      expect(notices(infinite).first.first).to start_with("cost-cap: default: Infinity isn't a number")
      expect(plugin(cost: 0.1).command("/cap 1e400")).to eq("usage: /cap [N | $N | off] (USD; /cap alone shows the spend)")
    end

    it "warns when default: can't be read: no cap, but not silently" do
      bundle = plugin({ "default" => "five" }, cost: 9.0)
      generation(bundle)
      expect(bundle.questions).to be_empty
      expect(notices(bundle)).to eq([["cost-cap: default: \"five\" isn't a number or off; no cap", :warn]])
      expect(bundle.command("/cap")).to eq("cost-cap: no cap ($9.00 spent)")
    end

    it "resolves the cap once per session: delegate? is read once across generations" do
      bundle = plugin({ "default" => 3.0, "child" => 2.0 }, cost: 1.0)
      allow(bundle.ctx).to receive(:delegate?).and_return(false)
      4.times { generation(bundle) }
      expect(bundle.ctx).to have_received(:delegate?).once

      bundle.set(session_id: "another")
      generation(bundle)
      expect(bundle.ctx).to have_received(:delegate?).twice
    end
  end

  describe "/cap" do
    it "shows the spend and the cap, with the breakdown" do
      bundle = plugin(cost: { reported: 1.1, estimated: 0.1, side: 0.02 })
      expect(bundle.command("/cap")).to eq("cost-cap: $1.20 spent of $3.00 (reported $1.10, estimated $0.10, side $0.02)")
    end

    it "says no cap, and when the cap can't be enforced" do
      expect(plugin({}, cost: 0.5).command("/cap")).to eq("cost-cap: no cap ($0.50 spent)")
      expect(plugin(cost: { known: false }).command("/cap"))
        .to eq("cost-cap: $0.00 spent of $3.00 (reported $0.00, estimated $0.00, side $0.00) " \
               "(can't be enforced: no cost reported or priced)")
    end

    it "sets the cap and step, in the $ form too, at or under the spend as well" do
      bundle = plugin(cost: 1.2)
      expect(bundle.command("/cap 5")).to eq("cost-cap: cap set to $5.00 ($1.20 spent)")
      expect(state).to eq("cap" => 5.0, "step" => 5.0)
      bundle.command("/cap $0.50")
      expect(state).to eq("cap" => 0.5, "step" => 0.5)

      bundle.answer({ selected: ["Stop"] })
      generation(bundle)
      expect(bundle.questions.last.question).to include("$1.20 spent of $0.50")
    end

    it "turns the cap off for this session over the config default" do
      bundle = plugin(cost: 9.0)
      expect(bundle.command("/cap off")).to eq("cost-cap: no cap for this session")
      expect(state).to eq("cap" => nil)
      generation(bundle)
      expect(bundle.questions).to be_empty
      expect(bundle.command("/cap")).to eq("cost-cap: no cap ($9.00 spent)")
    end

    it "takes .5 and 1e1 as /cap does any number" do
      bundle = plugin(cost: 0.1)
      expect(bundle.command("/cap .5")).to eq("cost-cap: cap set to $0.50 ($0.10 spent)")
      expect(bundle.command("/cap 1e1")).to eq("cost-cap: cap set to $10.00 ($0.10 spent)")
      expect(state).to eq("cap" => 10.0, "step" => 10.0)
    end

    it "logs why the command failed (a state file it can't write), and says so" do
      bundle = plugin(cost: 0.1)
      blocker = File.join(sandbox.root, "not-a-dir")
      File.write(blocker, "")
      allow(bundle.ctx).to receive(:data_dir).and_return(blocker)
      allow(bundle.ctx.log).to receive(:warn)
      expect(bundle.command("/cap 5")).to start_with("cost-cap: ")
      expect(bundle.ctx.log).to have_received(:warn).with(:cap_command_failed, error: start_with("Errno::"))
    end

    it "answers a bad value with the usage line" do
      bundle = plugin
      %w[five -1 $ 5x].each do |arg|
        expect(bundle.command("/cap #{arg}")).to eq("usage: /cap [N | $N | off] (USD; /cap alone shows the spend)")
      end
      expect(File).not_to exist(state_file)
    end

    it "keeps the cap across a reload of the bundle (the same data dir)" do
      plugin(cost: 1.0).command("/cap 4")
      reloaded = plugin(cost: 3.9)
      expect(reloaded.command("/cap")).to start_with("cost-cap: $3.90 spent of $4.00")
    end
  end
end
