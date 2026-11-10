# frozen_string_literal: true

require "samagotchi/bridge/card_store"
require "samagotchi/bridge/turn_notice"

# A turn's rows (TurnNotice) as CardStore keeps them: the fields of
# TurnNotice::FIELDS, the one list a join's replay (TurnAccumulator) and a
# reload (this store) read, so a field added there reaches both.
RSpec.describe Samagotchi::Bridge::CardStore do
  fields = Samagotchi::Bridge::TurnNotice::FIELDS
  # What the store adds to a turn's row: where it is, whose it is.
  store_keys = %i[type in_turn turn_id of_turn opening_id iteration calls current turns_since].freeze

  def event_for(type, keys)
    keys.to_h { |key| [key, key == :pending_question ? { id: "q1", question: "Go?" } : "#{type}-#{key}"] }
        .merge(type: type, unrelated: "dropped")
  end

  %i[hook_notice empty_answer_retry steer_cut llm_context_edited].each do |type|
    it "keeps a #{type} row with exactly TurnNotice::FIELDS' keys" do
      store = described_class.new
      store.call({ type: :turn_started, turn_id: "t1" })
      event = event_for(type, fields.fetch(type))
      store.call(event)

      entry = store.list.last
      expect(entry[:type]).to eq(type)
      expect(entry.keys - store_keys).to match_array(fields.fetch(type) - [:iteration])
      expect(entry.slice(*fields.fetch(type))).to eq(event.slice(*fields.fetch(type)))
    end
  end

  it "keeps a question with TurnNotice::FIELDS' keys for question_requested" do
    store = described_class.new
    store.call({ type: :turn_started, turn_id: "t1" })
    store.call(event_for(:question_requested, fields.fetch(:question_requested)))

    entry = store.list.last
    expect(entry[:type]).to eq(:question)
    expect(entry.keys - store_keys).to match_array(fields.fetch(:question_requested))
  end

  it "saves after each TurnNotice event" do
    expect(described_class::SAVED_ON).to include(*fields.keys)
  end
end
