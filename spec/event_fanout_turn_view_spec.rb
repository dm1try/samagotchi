# frozen_string_literal: true

require "spec_helper"
require "samagotchi/event_fanout"

# EventFanout#turn_view: the running turn's copy, handed out only while the
# turn it was taken in runs (the turn-id guard), and dropped at a turn's end.
RSpec.describe Samagotchi::EventFanout, "turn view" do
  let(:running) { { context: Struct.new(:id, :settings).new("turn-1", nil) } }
  let(:conversation) { [{ role: "user", content: "go" }] }
  let(:session) { Struct.new(:working_directory).new("/work") }
  let(:fanout) do
    nothing = -> {}
    described_class.new(
      observer: nothing, used_memories: nothing, muted: -> { [] }, steer_cut: nothing, thinking_notices: nothing,
      metrics: nothing, hooks: nothing, turn_context: -> { running[:context] }, last_turn_context: nothing,
      model_settings: -> { Struct.new(:turn_llm_context).new(nil) }, session: -> { session },
      live_conversation: -> { conversation }, used_memory_names: -> { [] }, served_expected_by: ->(_) {},
      working_set_snapshot: ->(*) {}, turn_running: -> { !running[:context].nil? }, announce_or_hold: ->(_) {},
      keep_context_status: ->(_) {}
    )
  end

  before { fanout.send(:keep_turn_view) }

  it "hands out the copy while its turn runs" do
    expect(fanout.turn_view).to have_attributes(turn_id: "turn-1", at: 1, cwd: "/work", conversation: conversation)
    expect(fanout.turn_view.conversation.first).not_to equal(conversation.first)
  end

  it "refuses a stale view while another turn runs, and with none running" do
    running[:context] = Struct.new(:id, :settings).new("turn-2", nil)
    expect(fanout.turn_view).to be_nil
    running[:context] = nil
    expect(fanout.turn_view).to be_nil
  end

  it "drops it at the turn's end (#drop_turn_view), though the turn still reads as running" do
    fanout.drop_turn_view
    expect(fanout.turn_view).to be_nil
  end
end
