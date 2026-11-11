# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_continue"

# What a continue carries (SessionContinue::CARRY): the one place a new
# per-session store a continue should carry is added, with its undo.
RSpec.describe Samagotchi::SessionContinue, "CARRY" do
  it "carries the delegates, the attached context, the objectives and the notes, in that order, each with its undo" do
    rows = described_class::CARRY.map { |step| [step.name, step.store, step.carry, step.undo] }

    expect(rows).to eq(
      [
        [:children, :session_files, :carry_children, { moved_back: :undo_move, link_stopped: :return_rings }],
        # Copies (the previous link keeps its sources); the link's go with its delete.
        [:context, :context_sources, :carry_context, {}],
        # A note in the link only, never given back; it goes with its delete.
        [:objectives, :session_files, :carry_objectives, {}],
        # Last: the objectives' carry reads a pending /objectives edit from the notes first.
        [:notes, :session_files, :carry_notes, { link_unlinked: :give_back_notes, link_deleted: :give_back_strays }]
      ]
    )
  end

  it "names a method for every carry and undo, and only known undo phases" do
    described_class::CARRY.each do |step|
      expect(described_class.respond_to?(step.carry, true)).to be(true), step.carry.to_s
      expect(step.undo.keys - described_class::UNDO_PHASES).to be_empty
      step.undo.each_value { |name| expect(described_class.respond_to?(name, true)).to be(true), name.to_s }
    end
  end

  # A new store in SessionManager::SESSION_STATE_STORES is either carried
  # (a CARRY step) or named in NOT_CARRIED with the reason.
  it "accounts for every session state store: carried or deliberately left with the previous link" do
    carried = described_class::CARRY.map(&:store).uniq
    left = described_class::NOT_CARRIED.keys

    expect(carried & left).to be_empty
    expect(carried + left).to match_array(Samagotchi::SessionManager::SESSION_STATE_STORES)
    expect(left).to contain_exactly(:plugin_session_state, :participants, :system_one_runs, :context_candidates_log)
  end
end
