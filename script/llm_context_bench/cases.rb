# frozen_string_literal: true

require_relative "replay"

module LLMContextBench
  # A point to score a strategy at: the end of a turn that has a next turn,
  # where the next turn's first request (+at+) is the first that could send
  # an edit made by then. Named like the spike's cases: "<session id's
  # first 8>_t<turn>".
  Case = Data.define(:replay, :turn) do
    def name = "#{replay.short_id}_t#{turn}"

    # The next turn's first request, nil when it has none.
    def at
      next_turn = replay.turns[turn + 1]
      return nil unless next_turn

      request = replay.request_after(next_turn.begin - 1)
      request if request && next_turn.cover?(replay.prompt_end(request))
    end

    def scorable? = !at.nil?

    # The turn's own tool output tokens.
    def tool_tokens
      range = replay.turns[turn]
      replay.outputs.select { |output| range.cover?(output.entry_index) }.sum(&:tokens)
    end

    # The outputs in request +at+'s prompt.
    def outputs = replay.outputs.select { |output| output.entry_index < replay.prompt_end(at) }
  end

  module Cases
    # The candidate rule of the spike (candidates.py): a turn's own tool
    # output of at least this many tokens.
    MIN_TURN_TOOL = 3000

    module_function

    # The scorable cases of +replays+: those +names+ lists ("<id8>_t<N>"),
    # else every turn with a next turn and at least +min_turn_tool+ tokens
    # of its own tool output.
    # @return [Array<Case>]
    def select(replays, names: nil, min_turn_tool: MIN_TURN_TOOL)
      replays.flat_map do |replay|
        (0...(replay.turns.size - 1)).map { |turn| Case.new(replay: replay, turn: turn) }
      end.select do |kase|
        next false unless kase.scorable?

        names ? names.include?(kase.name) : kase.tool_tokens >= min_turn_tool
      end
    end

    # Case names from a file: one per line, "#" comments and blanks skipped.
    def read_names(path)
      File.readlines(path, chomp: true).map { |line| line.sub(/#.*/, "").strip }.reject(&:empty?)
    end
  end
end
