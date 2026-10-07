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

    # What the turn's last entry is: "answer" (the model's final prose, no
    # calls), "tool_result" (it stopped mid-task on a tool's output, e.g.
    # cut off or the session saved there), "turn_note" (chi's note on a
    # turn that ended without an answer), "tool_call" (calls never
    # answered), "empty" (a model entry with neither), else the entry's
    # kind or role.
    def ends
      last = replay.turns[turn].end - 1
      entry = replay.messages[last]
      case replay.role(last)
      when "model" then model_end(entry, last)
      when "tool_response" then "tool_result"
      else (entry[:kind] || replay.role(last)).to_s
      end
    end

    def answer_ended? = ends == "answer"

    # The turn's own tool output tokens.
    def tool_tokens
      range = replay.turns[turn]
      replay.outputs.select { |output| range.cover?(output.entry_index) }.sum(&:tokens)
    end

    # The outputs in request +at+'s prompt.
    def outputs = replay.outputs.select { |output| output.entry_index < replay.prompt_end(at) }

    private

    def model_end(entry, index)
      return "tool_call" unless replay.calls[replay.request_of(index)].empty?

      replay.parts(entry).first.strip.empty? ? "empty" : "answer"
    end
  end

  module Cases
    # The candidate rule of the spike (candidates.py): a turn's own tool
    # output of at least this many tokens.
    MIN_TURN_TOOL = 3000
    # Which turn ends a case may have (Case#ends): answer, only turns that
    # end with the model's final answer, the point a forget-at-turn-end
    # offer would come; any, every turn.
    ENDS = %w[answer any].freeze

    module_function

    # The scorable cases of +replays+: those +names+ lists ("<id8>_t<N>"),
    # else every turn with a next turn and at least +min_turn_tool+ tokens
    # of its own tool output; of them, those +ends+ allows. By default
    # (nil) the turn-size rule keeps answer-ended turns only and named
    # cases are kept as named (any).
    # @return [Array<Case>]
    def select(replays, names: nil, min_turn_tool: MIN_TURN_TOOL, ends: nil)
      ends ||= names ? "any" : "answer"
      raise ArgumentError, "ends: #{ENDS.join(" or ")}" unless ENDS.include?(ends)

      replays.flat_map do |replay|
        (0...(replay.turns.size - 1)).map { |turn| Case.new(replay: replay, turn: turn) }
      end.select do |kase|
        next false unless kase.scorable?
        next false unless names ? names.include?(kase.name) : kase.tool_tokens >= min_turn_tool

        ends == "any" || kase.answer_ended?
      end
    end

    # "answer 3, tool_result 7, turn_note 2": how many cases end each way.
    # @param endings [Array<String>] Case#ends of each case
    def ends_tally(endings)
      endings.tally.sort.map { |ending, n| "#{ending} #{n}" }.join(", ")
    end

    # Case names from a file: one per line, "#" comments and blanks skipped.
    def read_names(path)
      File.readlines(path, chomp: true).map { |line| line.sub(/#.*/, "").strip }.reject(&:empty?)
    end
  end
end
