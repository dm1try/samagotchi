# frozen_string_literal: true

module Samagotchi
  class SessionMetrics
    # The session's work so far (SessionMetrics#usage, what a bundle's
    # ctx.usage reads), across its turns and workers: the same numbers
    # /stats and `chi sessions stats` show.
    # +turns+: finished turns plus the running one. +tool_calls+ and
    # +tool_calls_by_tool+ (canonical names: an alias counts under the tool
    # it resolved to, a call_tool call under the inner tool): every call,
    # running ones included. +steps+: the loop rounds that dispatched tools
    # (the snapshot's iterations_total). +active_ms+: work time, the
    # generations' time plus the finished tool calls' time (approval waits
    # left out; ask_user_question's, a wait on the user, not counted),
    # never a question's wait between them; +tool_ms_by_tool+ is the tool
    # part by tool (the same names), so a reader can leave a waiting tool's
    # time (task_wait, a blocking delegate) out.
    # Bundles use its methods only, never this constant's name.
    Usage = Data.define(:turns, :tool_calls, :tool_calls_by_tool, :steps, :active_ms, :tool_ms_by_tool) do
      def self.zero = new(turns: 0, tool_calls: 0, tool_calls_by_tool: {}, steps: 0, active_ms: 0, tool_ms_by_tool: {})

      # Data freezes itself, not its hashes: these are copied and frozen.
      def initialize(tool_calls_by_tool:, tool_ms_by_tool:, **)
        super(tool_calls_by_tool: tool_calls_by_tool.dup.freeze, tool_ms_by_tool: tool_ms_by_tool.dup.freeze, **)
      end

      # @return [Float] active_ms in minutes
      def active_minutes = active_ms / 60_000.0
    end
  end
end
