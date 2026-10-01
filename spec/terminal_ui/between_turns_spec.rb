# frozen_string_literal: true

require "samagotchi/terminal_ui/between_turns"
require "samagotchi/terminal_ui/attached_view"
require_relative "../support/recording_surface"

# The REPL's prints between turns, on their own; terminal_ui_commands_spec
# drives them through an Engine.
RSpec.describe Samagotchi::TerminalUI::BetweenTurns do
  let(:surface) { RecordingSurface.new }
  let(:view) { Samagotchi::TerminalUI::AttachedView.new(surface, tick_interval: nil) }
  let(:running) { [false] }
  let(:quiet) { false }
  let(:between_turns) do
    described_class.new(surface: surface, view: view, renderer: Samagotchi::TerminalUI::EventRenderer.new(view),
                        turn_running: -> { running.first }, quiet: quiet)
  end
  let(:notice) { { type: :hook_notice, hook: "plugin.rb (bundle b)", text: "saved", level: :info, between_turns: true } }

  it "keeps what is announced off the main thread until a flush, and prints it once" do
    Thread.new { between_turns.observe(notice) }.join
    expect(surface.lines).to be_empty

    between_turns.flush_cards
    between_turns.flush_cards
    expect(surface.lines).to eq(["b> saved"])
  end

  it "prints an anytime command's card at once on the main thread" do
    between_turns.observe({ type: :card, id: "c1", source: "b", title: "Now", anytime: true })
    expect(surface.lines.join("\n")).to include("┌ Now · b")
  end

  it "prints an anytime command's output beside a running turn, else keeps it for the flush" do
    between_turns.show_or_keep({ type: :command_output, text: "kept" })
    expect(surface.lines).to be_empty
    running[0] = true
    between_turns.show_or_keep({ type: :command_output, text: "now" })
    expect(surface.lines).to eq(["now"])

    between_turns.flush_cards
    expect(surface.lines).to eq(%w[now kept])
  end

  it "leaves a turn's card and a notice not marked between turns to the turn" do
    between_turns.observe({ type: :card, id: "c1", source: "b", title: "mid", in_turn: true })
    between_turns.observe(notice.except(:between_turns))
    between_turns.flush_cards
    expect(surface.lines).to be_empty
  end

  context "with --non-interactive" do
    let(:quiet) { true }

    it "prints no init lines or load warnings" do
      between_turns.observe({ type: :plugin_init_finished, bundle: "mcp", id: "1", label: "x", ok: true, summary: "x ready" })
      between_turns.observe({ type: :guardrail_warning, label: "g", message: "boom" })
      between_turns.flush_cards
      expect(surface.lines).to be_empty
    end
  end

  it "prints an idle recap at the next flush, and drops one that lands during a turn" do
    between_turns.take_recap({ type: :recap_ready, recap: "Did Y." })
    between_turns.flush_recap
    between_turns.flush_recap
    running[0] = true
    between_turns.take_recap({ type: :recap_ready, recap: "Did Z." })
    between_turns.flush_recap

    expect(surface.lines).to eq(["recap> Did Y."])
  end

  it "prints on the surface it was moved to" do
    other = RecordingSurface.new
    between_turns.keep({ type: :command_output, text: "here" })
    between_turns.surface = other
    between_turns.flush_cards

    expect(other.lines).to eq(["here"])
  end
end
