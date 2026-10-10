# frozen_string_literal: true

require_relative "tool_activity"
require_relative "tool_view"
require_relative "file_ref"

module Samagotchi
  # The fields a tool row shows beyond its params, built from the call in
  # one place for every path: the live tool_call_started (ToolRunner#run)
  # and a reload from the saved call (Web::MessageParts#tool_part). The
  # bridge's snapshot and replay (Bridge::TurnAccumulator) copy them by
  # these lists, so a new field is added here and travels everywhere.
  #
  # They travel in two places:
  # * ACTIVITY_KEYS: top-level on tool_call_started, inside +activity+ on
  #   tool_call_completed (ToolActivity.tool_activity_event builds that
  #   activity itself, for the TUI and the metrics);
  # * EVENT_KEYS: top-level on both, so a UI that missed the start (a
  #   replay gap) builds its row from the completed event.
  #
  # params and label stay where they are: their sources differ per path
  # (the registry's preview, a plugin's label, the saved shown params).
  module ToolRowFields
    ACTIVITY_KEYS = %i[title called_as].freeze
    EVENT_KEYS = %i[view ref].freeze
    KEYS = (ACTIVITY_KEYS + EVENT_KEYS).freeze

    module_function

    # @param cwd [String, nil] the session's working directory (the title is
    #   relative to it when inside it)
    # @return [Hash] title (a few words: a project-relative path, a command
    #   without its "cd … &&"), called_as (the name the model called it by
    #   when that was an alias's: bash), view (ToolView: the full command)
    #   and ref (FileRef: the file a file tool touched), each only when
    #   there is one
    def for(tool_name, call, cwd:)
      {
        title: ToolActivity.tool_title(tool_name, call, cwd: cwd),
        called_as: call[:called_as],
        view: ToolView.for(tool_name, call)&.to_h,
        ref: FileRef.for(tool_name, call, cwd: cwd)&.to_h
      }.compact
    end
  end
end
