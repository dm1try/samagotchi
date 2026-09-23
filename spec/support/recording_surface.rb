# frozen_string_literal: true

require "samagotchi/terminal_ui/surface"

# A Surface that records what a UI draws instead of writing it.
class RecordingSurface
  include Samagotchi::TerminalUI::Surface

  # @return [Array<String>] committed output
  attr_reader :lines
  # @return [Hash{Symbol => Array<String>}] what each slot shows now
  attr_reader :slots
  # @return [Array<Array>] every call, in order: [:commit, text],
  #   [:set_slot, name, rows], [:clear_slot, name]
  attr_reader :events
  attr_reader :columns

  def initialize(columns: 80)
    @columns = columns
    @lines = []
    @slots = {}
    @events = []
  end

  def commit(text)
    @events << [:commit, text]
    @lines << text
  end

  def set_slot(name, rows)
    check_slot!(name)
    @events << [:set_slot, name, rows]
    @slots[name] = rows
  end

  def clear_slot(name)
    check_slot!(name)
    @events << [:clear_slot, name]
    !@slots.delete(name).nil?
  end

  def synchronize = yield

  # The activity slot's history as one row per change (nil: cleared).
  def statuses
    @events.select { |_kind, name| name == :activity }
           .map { |kind, _name, rows| kind == :set_slot ? rows.first : nil }
  end
end
