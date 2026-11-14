# frozen_string_literal: true

require_relative "steer"
require_relative "tool_activity"
require_relative "tool_response"
require_relative "tool_names"

module Samagotchi
  module Objectives
    # What a move's own turn ran before it, derived by the harness from the
    # record (the model's evidence stays free text): +edits+ the edit and write
    # runs that succeeded; +command+ the status of the last finished execute or
    # task_wait run, OK, FAILED or nil; +edited_after_command+ a successful edit
    # or write came after the last command that itself ran after the turn's
    # first successful edit (false with none: a search before any edit, `rg` →
    # edit → done, checked no edit, so it can't be stale); +unbacked+ the one
    # flag: only for a DONE move after a command ran, when the last command
    # failed or an edit came after the last command that checked an edit. A move that is progress or blocked never flags,
    # and neither does a turn with edits and no command (a docs change would
    # flag every time). Information only, pure. See docs/internals/objectives.md.
    Backing = Data.define(:edits, :command, :edited_after_command, :unbacked) do
      def to_view = { "edits" => edits, "command" => command, "edited_after_command" => edited_after_command, "unbacked" => unbacked }

      # The /objectives line's and the page's words for a flagged move; nil
      # for one that isn't.
      def flag_words
        return nil unless unbacked

        command == Backing::FAILED ? "not backed: the last command failed" : "not backed: edited after the last command ran"
      end
    end

    class Backing
      OK = "ok"
      FAILED = "failed"
      CHANGES = [ToolNames::Edit::NAME, ToolNames::Write::NAME].freeze

      # +runs+ the move's turn's paired runs before it (LLMContextStale.paired_runs'),
      # in order; +state+ the move's.
      # @return [Backing]
      def self.of(runs, state)
        edits = 0
        command = nil
        # A command ran after an edit: only that one could have checked it.
        checked = false
        edited_after = false
        runs.each do |run|
          if edit?(run)
            edits += 1
            edited_after = true if checked
          elsif (status = command_status(run))
            command = status
            checked = true if edits.positive?
            edited_after = false
          end
        end
        unbacked = state == ToolNames::ObjectivesTool::DONE && !command.nil? && (command == FAILED || edited_after)
        new(edits: edits, command: command, edited_after_command: edited_after, unbacked: unbacked)
      end

      # The runs of the move at +position+ in +runs+ that are of its own turn:
      # after the nearest turn opening (Steer.turn_prompt?, what bounds a turn's
      # slice) before the move's entry, up to the move. Mid-turn the fold reads
      # the loop's own conversation too (Engine#live_conversation), which holds
      # the running turn's opening. A rollback that drops a turn drops its runs
      # with its moves.
      def self.turn_runs(conversation, runs, position)
        move = runs[position]
        start = (move.index - 1).downto(0).find { |i| Steer.turn_prompt?(conversation[i]) } || -1
        runs[0...position].select { |run| run.index > start }
      end

      # Work for the tracker's turn gate (ObjectivesTrack.worked_without_move?),
      # as the page's no-move mark counts it: an edit or write that succeeded,
      # an execute that finished ok (a failed, denied, stopped one isn't; one
      # handed over as a task still runs, and isn't either).
      def self.work?(run)
        edit?(run) || (run.call[:name].to_s == ToolNames::Execute::NAME && command_status(run) == OK)
      end

      def self.edit?(run)
        return false unless CHANGES.include?(run.call[:name].to_s) && !ToolResponse.interrupted_text?(run.text)

        ToolActivity.tool_activity_status(ToolActivity.saved_result_text(run.text), run.call[:name].to_s) == "ok"
      end
      private_class_method :edit?

      # A finished command's status, nil for no command: a call the guardrails
      # denied, one stopped or interrupted, an execute handed over as a task
      # (still running), and a task_wait whose task hadn't finished (a timeout,
      # a waiting message) or that waited on nothing (an Error:).
      def self.command_status(run)
        name = run.call[:name].to_s
        return nil unless [ToolNames::Execute::NAME, ToolNames::TaskWait::NAME].include?(name)
        return nil if ToolResponse.interrupted_text?(run.text)

        text = ToolActivity.saved_result_text(run.text)
        return nil if ToolActivity.guardrail_denied?(text)
        return task_status(text) if name == ToolNames::TaskWait::NAME
        return nil if ToolActivity.handed_over?(name, text)

        case ToolActivity.tool_activity_status(text, name, command: run.call[:content])
        when "ok" then OK
        when "error" then FAILED
        end
      end
      private_class_method :command_status

      def self.task_status(text)
        return nil if text.start_with?("Error:")

        case text.split(/^output_tail:$/, 2).first.to_s[/^status: (\S+)$/, 1]
        when "completed" then OK
        when "failed" then FAILED
        end
      end
      private_class_method :task_status
    end
  end
end
