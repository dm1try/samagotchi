# frozen_string_literal: true

require_relative "formatting"

module Samagotchi
  class TerminalUI
    # The status row under the prompt, the same for both TUIs:
    # `status> model=… | ↳ parent | ctx=12.3% (under20) | mem: … | muted: …`.
    # A UI feeds it what it learns (attached mode from the Bridge's events,
    # the REPL from its Engine's) through #update, and the row is redrawn in
    # the surface's status slot only when its text changes.
    class StatusRow
      include Formatting

      # Memory names shown before ", +N".
      MEMORY_LIMIT = 8
      # What the row shows:
      #   model, default_model  the model in use, and the config's default
      #                         (named beside another model)
      #   served                [served, asked]: what the server said it
      #                         served for the name asked (ServedModel)
      #   parent_id             the session that delegated this one
      #   context               the kernel's estimate {est_pct:, bucket:}
      #   used_memories         the memories the session read
      #   preloaded             its --memory list (shown until a turn
      #                         records them as used)
      #   muted                 its --mute list
      FIELDS = %i[model default_model served parent_id context used_memories preloaded muted].freeze

      # @param surface [Surface] with #columns
      def initialize(surface)
        @surface = surface
        @values = { used_memories: [], preloaded: [], muted: [] }
        @shown = nil
      end

      # The surface it draws on (the REPL swaps in a live region): the row
      # is drawn there at the next change.
      def surface=(surface)
        @surface = surface
        @shown = nil
      end

      def [](field) = @values[field]

      # Change some fields; the row is redrawn when its text changed.
      def update(**fields)
        unknown = fields.keys - FIELDS
        raise ArgumentError, "unknown status field(s): #{unknown.join(", ")}" if unknown.any?

        @values.merge!(fields)
        refresh
      end

      # Take a session's state: the REPL's Engine#session_state_snapshot, or
      # the one a worker sends an attached TUI when it joins. A key the state
      # lacks (an older worker's) leaves its field as it was; the served pair
      # is cleared without one, and the model is kept without a name.
      # @param default_model [String, nil] the config's default, named beside
      #   another model
      def take_state(state, default_model: nil)
        fields = { served: state[:served_model] ? [state[:served_model], state[:served_model_for]] : nil }
        fields.merge!(model: state[:model_name], default_model: default_model) if state[:model_name]
        STATE_LISTS.each { |field, key| fields[field] = Array(state[key]) if state.key?(key) }
        fields[:parent_id] = state[:parent_id] if state.key?(:parent_id)
        # The last turn's ctx, so it shows before the next turn's.
        fields[:context] = state[:context_status] if state[:context_status].is_a?(Hash)
        update(**fields)
      end

      # The memory lists' fields and the state keys they come from.
      STATE_LISTS = { used_memories: :used_memory_names, preloaded: :preloaded_memory_names,
                      muted: :muted_memory_names }.freeze

      # Take what a turn event says about the row (the Engine's events in
      # the REPL, the Bridge's in attached mode): ctx, the memories used,
      # the model the server served. Other events change nothing.
      def take_event(event)
        case event[:type]
        when :context_status then update(context: { est_pct: event.dig(:usage, :estimated_pct), bucket: event[:bucket] })
        when :used_memories_updated then update(used_memories: Array(event[:used_memory_names]))
        when :generation_completed
          update(served: [event[:served_model], event[:requested_model]]) if event[:served_model]
        end
      end

      # Draw the row unless it shows that already (status.line: off draws
      # nothing).
      def refresh
        return unless status_line_enabled?

        rows = rows(@surface.columns - 1)
        return if rows == @shown

        @shown = rows
        rows.empty? ? @surface.clear_slot(:status) : @surface.set_slot(:status, rows)
      end

      # @return [Array<String>] the row cut to +width+ (none with nothing to say)
      def rows(width)
        served, served_for = @values[:served]
        model = @values[:model]
        parent = @values[:parent_id]
        segments = [model ? status_model_text(model, @values[:default_model], served: served, served_for: served_for) : "",
                    parent ? "↳ #{parent.to_s[0, 8]}" : "",
                    status_context_text(estimate: @values[:context]),
                    status_memory_text(Array(@values[:used_memories]) | Array(@values[:preloaded]), MEMORY_LIMIT),
                    status_memory_text(@values[:muted], MEMORY_LIMIT, label: "muted")].reject(&:empty?)
        status_rows(segments, width)
      end
    end
  end
end
