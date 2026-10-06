# frozen_string_literal: true

require "spec_helper"
require "samagotchi/hooks/registry"
require "samagotchi/plugin/api"
require "samagotchi/plugin/loader"
require "samagotchi/plugin/context"

# ctx.notify / ask_user / steer / stop_turn / stop_generation
# (docs/plugins.md, "Inside a handler"): inside a plugin's event handler
# they act as that fire's event[:x] (scoped to the event: stop_turn denies
# the pending call in before_tool_call, steer / stop_turn /
# stop_generation do nothing after the turn); anywhere else (a command, a
# thread the handler started) they act anytime, through the Host.
RSpec.describe "a plugin's ctx helpers and the current event" do
  let(:label) { "plugin.rb (bundle demo)" }

  let(:calls) { [] }
  let(:registry) do
    Samagotchi::Hooks::Registry.new.tap do |reg|
      reg.runtime = Samagotchi::Hooks::Runtime.new(
        notify: ->(text:, level:, hook:, fallback_for: nil) { calls << [:event_notify, text, level, hook, fallback_for].compact },
        ask_user: lambda { |question:, options:, header:, allow_freeform:, hook:|
          calls << [:event_ask_user, question, hook]
          { selected: [options.first], freeform: nil }
        },
        stop_turn: ->(reason:, hook:) { calls << [:event_stop_turn, reason, hook] },
        steer: ->(text:, hook:) { calls << [:event_steer, text, hook] },
        stop_generation: ->(reason:, hook:) { calls << [:event_stop_generation, reason, hook] }
      )
    end
  end
  let(:host) do
    Samagotchi::Plugin::Host.new(
      notify: ->(text, level, label, fallback_for:) { calls << [:host_notify, text, level, label, fallback_for].compact },
      ask_user: lambda { |question:, options:, header:, allow_freeform:, hook:|
        calls << [:host_ask_user, question, hook]
        { selected: [options.last], freeform: nil }
      },
      steer: ->(text, label) { calls << [:host_steer, text, label] },
      stop_turn: ->(reason, label) { calls << [:host_stop_turn, reason, label] },
      stop_generation: ->(reason, label) { calls << [:host_stop_generation, reason, label] }
    )
  end
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "demo", label: label, settings: {}, host: host) }

  # Register +block+ as the plugin's handler for +event+, as Loader does.
  def on(event, context: ctx, &block)
    registries = Samagotchi::Plugin::Registries.new(commands: nil, tools: nil, hooks: registry)
    api = Samagotchi::Plugin::Api.new(bundle: context.bundle, label: label, registries: registries, context: context)
    api.on(event, &block)
    api.commit!
  end

  def all_helpers(context)
    [context.notify("hi", level: :warn),
     context.ask_user(question: "go?", options: %w[yes no])&.dig(:selected),
     context.steer("look"),
     context.stop_turn("enough"),
     context.stop_generation("loops")]
  end

  it "inside a handler they go through the fire's helpers, labelled by the plugin" do
    results = nil
    on(:before_turn) { |_event, c| results = all_helpers(c) }

    registry.fire(:before_turn, { type: :before_turn })

    expect(results).to eq([nil, ["yes"], true, true, true])
    expect(calls).to eq([[:event_notify, "hi", :warn, label], [:event_ask_user, "go?", label],
                         [:event_steer, "look", label], [:event_stop_turn, "enough", label],
                         [:event_stop_generation, "loops", label]])
  end

  it "ctx.stop_turn in before_tool_call also denies the pending call" do
    gate = double("guardrail")
    expect(gate).to receive(:deny!).with("the turn was stopped by #{label}: enough")
    on(:before_tool_call) { |_event, c| c.stop_turn("enough") }

    registry.fire(:before_tool_call, { type: :before_tool_call, guardrail: gate })

    expect(calls).to eq([[:event_stop_turn, "enough", label]])
  end

  it "after the turn steer, stop_turn and stop_generation do nothing; notify and ask_user still work" do
    results = nil
    on(:after_turn) { |_event, c| results = all_helpers(c) }

    registry.fire(:after_turn, { type: :after_turn })

    expect(results).to eq([nil, ["yes"], false, false, false])
    expect(calls.map(&:first)).to eq(%i[event_notify event_ask_user])
  end

  it "a fire site's own helper counts (a stream hook's ask_user asks no one)" do
    answer = :unset
    on(:generation_progress) { |_event, c| answer = c.ask_user(question: "go?", options: %w[yes no]) }

    registry.fire(:generation_progress, { type: :generation_progress, ask_user: ->(**) {} })

    expect(answer).to be_nil
    expect(calls).to be_empty
  end

  it "outside a handler (a command) they act anytime, through the Host" do
    expect(all_helpers(ctx)).to eq([nil, ["no"], true, true, true])
    expect(calls.map(&:first)).to eq(%i[host_notify host_ask_user host_steer host_stop_turn host_stop_generation])
    expect(calls.map(&:last)).to all(eq(label))
  end

  it "a thread the handler starts acts anytime, even after the turn" do
    thread = nil
    on(:after_turn) { |_event, c| thread = Thread.new { c.steer("later") } }

    registry.fire(:after_turn, { type: :after_turn })

    expect(thread.value).to be(true)
    expect(calls).to eq([[:host_steer, "later", label]])
  end

  it "the handler's event is gone once it returns, and a raising handler leaves none behind" do
    on(:after_turn) { |_event, _c| raise "boom" }
    registry.fire(:after_turn, { type: :after_turn })

    expect(ctx.steer("now")).to be(true)
    expect(calls).to eq([[:host_steer, "now", label]])
  end

  it "a fire nested in a handler gets its own event; the outer one is back after it" do
    seen = []
    on(:before_turn) { |_event, c| seen << [:inner, c.steer("in")] }
    on(:after_turn) do |_event, c|
      seen << [:outer_before, c.steer("x")]
      registry.fire(:before_turn, { type: :before_turn })
      seen << [:outer_after, c.steer("y")]
    end

    registry.fire(:after_turn, { type: :after_turn })

    expect(seen).to eq([[:outer_before, false], [:inner, true], [:outer_after, false]])
    expect(calls).to eq([[:event_steer, "in", label]])
  end

  it "another plugin's ctx inside this plugin's handler acts anytime" do
    other = Samagotchi::Plugin::Context.new(bundle: "other", label: "plugin.rb (bundle other)", settings: {}, host: host)
    on(:after_turn) { |_event, _c| other.steer("from beside") }

    registry.fire(:after_turn, { type: :after_turn })

    expect(calls).to eq([[:host_steer, "from beside", "plugin.rb (bundle other)"]])
  end
end
