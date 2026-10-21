# frozen_string_literal: true

require_relative "formatting"

module Samagotchi
  class TerminalUI
    # The status row under the prompt, the same for both TUIs:
    # `status> Title | model=… | ↳ parent | ⑂ 2 running · 1 waiting | ctx=12.3% (under20) | mem: … | muted: …`.
    # A UI feeds it what it learns (attached mode from the Bridge's events,
    # the REPL from its Engine's) through #update, and the row is redrawn in
    # the surface's status slot only when its text changes.
    class StatusRow
      include Formatting

      # Memory names shown before ", +N".
      MEMORY_LIMIT = 8
      # What the row shows:
      #   title                 the session's own title (Session#title; not
      #                         the first message's preview), or nil
      #   model, default_model  the model in use, and the config's default
      #                         (named beside another model)
      #   served                [served, asked, expected]: what the server said it
      #                         served for the name asked (ServedModel), and
      #                         the host whose served: expects it (or nil)
      #   parent_id             the session that delegated this one
      #   children              its delegates' ChildrenStatus::Counts, or
      #                         nil (the segment shows running and waiting)
      #   context               the kernel's estimate {est_pct:, bucket:}
      #   used_memories         the memories the session read
      #   preloaded             its --memory list (shown until a turn
      #                         records them as used)
      #   muted                 its --mute list
      #   running               a turn runs: the row trails STEER_HINT
      FIELDS = %i[title model default_model served parent_id children context used_memories preloaded muted running].freeze

      # The tail while a turn runs: where a typed line goes (the next step)
      # and the two other choices. Dropped whole first when the row is cut.
      STEER_HINT = " · typing goes in at the next step (/cut, /queue)"

      # The longest title shown, and the share of the row it may take on a
      # narrow terminal: the rest of the row still fits.
      TITLE_MAX = 32
      TITLE_SHARE = 3

      # The turn events that end a turn (the hint goes).
      TURN_END_EVENTS = %i[turn_completed turn_canceled turn_failed].freeze

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
        fields = { served: state[:served_model] ? [state[:served_model], state[:served_model_for], state[:served_expected_by]] : nil }
        fields.merge!(model: state[:model_name], default_model: default_model) if state[:model_name]
        STATE_LISTS.each { |field, key| fields[field] = Array(state[key]) if state.key?(key) }
        fields[:parent_id] = state[:parent_id] if state.key?(:parent_id)
        fields[:title] = state[:title] if state.key?(:title)
        # The last turn's ctx, so it shows before the next turn's.
        fields[:context] = state[:context_status] if state[:context_status].is_a?(Hash)
        update(**fields)
      end

      # The memory lists' fields and the state keys they come from.
      STATE_LISTS = { used_memories: :used_memory_names, preloaded: :preloaded_memory_names,
                      muted: :muted_memory_names }.freeze

      # Take what a turn event says about the row (the Engine's events in
      # the REPL, the Bridge's in attached mode): ctx, the memories used,
      # the model the server served, whether a turn runs (the steer
      # hint). Other events change nothing.
      def take_event(event)
        case event[:type]
        # usage nil (a /model whose window didn't resolve) clears it.
        when :context_status
          update(context: event[:usage] ? { est_pct: event.dig(:usage, :estimated_pct), bucket: event[:bucket] } : nil)
        when :used_memories_updated then update(used_memories: Array(event[:used_memory_names]))
        when :generation_completed
          update(served: [event[:served_model], event[:requested_model], event[:served_expected_by]]) if event[:served_model]
        when :turn_started then update(running: true)
        when *TURN_END_EVENTS then update(running: false)
        end
      end

      # Whether the row is drawn at all (status.line): a UI computes what
      # only the row shows (the children's counts) only then.
      def enabled? = status_line_enabled?

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
        served, served_for, expected = @values[:served]
        model = @values[:model]
        parent = @values[:parent_id]
        model_text = ""
        if model
          model_text = status_model_text(model, @values[:default_model], served: served, served_for: served_for,
                                                                         expected: expected.is_a?(String))
        end
        segments = [title_text(@values[:title], width),
                    model_text,
                    parent ? "↳ #{parent.to_s[0, 8]}" : "",
                    children_text(@values[:children]),
                    status_context_text(estimate: @values[:context]),
                    status_memory_text(Array(@values[:used_memories]) | Array(@values[:preloaded]), MEMORY_LIMIT),
                    status_memory_text(@values[:muted], MEMORY_LIMIT, label: "muted")].reject(&:empty?)
        status_rows(with_steer_hint(segments, width), width)
      end

      private

      # +segments+ with STEER_HINT after the last while a turn runs, when
      # the whole row fits +width+ with it: on a narrow terminal the hint
      # goes first, whole, before anything else is cut.
      def with_steer_hint(segments, width)
        return segments unless @values[:running] && segments.any?
        return segments if "status> #{segments.join(" | ")}#{STEER_HINT}".length > width

        segments[0..-2] + ["#{segments.last}#{STEER_HINT}"]
      end

      # The title cut to TITLE_MAX, and to a TITLE_SHARE-th of +width+
      # (the row's other segments come after it); "" without one.
      def title_text(title, width)
        title = title.to_s.strip
        return "" if title.empty?

        max = [TITLE_MAX, width / TITLE_SHARE].min
        return title if title.length <= max

        max > 1 ? "#{title[0, max - 1]}…" : ""
      end

      # `⑂ 2 running · 1 waiting`, the counts there are; "" with neither (no
      # children, or all ended). Not "not reported": a REPL parent is never
      # given its children's replies (no wakes there), and a worker moves
      # the cursors only after the turn_completed a terminal refreshes on.
      def children_text(counts)
        return "" unless counts

        parts = [[counts.running, "running"], [counts.waiting, "waiting"]]
                .select { |n, _| n.positive? }.map { |n, word| "#{n} #{word}" }
        parts.empty? ? "" : "⑂ #{parts.join(" · ")}"
      end
    end
  end
end
