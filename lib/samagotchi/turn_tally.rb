# frozen_string_literal: true

module Samagotchi
  # A running count of one turn's tool calls, for the one-line tally a long,
  # tool-heavy turn shows under its activity row:
  #
  #   12 tool calls (2 failed) · execute ×7 · read_file ×3 · edit ×2 · last: execute command=rspec
  #
  # Built from the turn's :tool_call_started / :tool_call_completed events
  # (or a joined turn's snapshot parts), with no model call. The web builds
  # the same text from its activity rows (public/tally.js); both follow
  # spec/shared/tally_matrix.json.
  class TurnTally
    # Below this many calls the "running <tool>…" row says enough.
    MIN_CALLS = 3
    TOP_TOOLS = 3
    SEPARATOR = " · "

    def initialize
      reset
    end

    def reset
      @calls = {}
    end

    def count
      @calls.size
    end

    # @param key [Object] one call's identity within the turn (the event's
    #   [iteration, call_index])
    def started(key:, tool:, params: nil)
      call = (@calls[key] ||= { tool: tool.to_s, params: "", status: "running" })
      call[:tool] = tool.to_s unless tool.to_s.empty?
      call[:params] = params.to_s unless params.nil?
      call[:status] = "running"
      call
    end

    # A completion with no start seen still counts as a call (as the web's
    # activity rows do). Only "error" is a failure: a call a guardrail or an
    # approval blocked still counts as a call, not as a failed one.
    def completed(key:, tool:, status:, params: nil)
      call = @calls[key] || started(key: key, tool: tool, params: params)
      call[:params] = params.to_s if params
      call[:status] = status.to_s == "error" ? "error" : "ok"
      call
    end

    # Pick up a turn joined mid-way: its snapshot's tool parts.
    # @param parts [Array<Hash>] the Bridge snapshot's current_turn parts
    def seed(parts)
      Array(parts).each do |part|
        part = part.transform_keys(&:to_sym)
        next unless part[:kind].to_s == "tool"

        key = [part[:iteration].to_i, part[:call_index].to_i]
        started(key: key, tool: part[:tool], params: part[:params])
        completed(key: key, tool: part[:tool], status: part[:status]) unless part[:status].to_s == "running"
      end
      self
    end

    # @param width [Integer, nil] cut the text to this many characters
    # @param last [Boolean] end with the last call and its params
    # @return [String, nil] nil below MIN_CALLS
    def text(width: nil, last: true)
      self.class.format(@calls.values, last: last, width: width)
    end

    # @param calls [Array<Hash>] {tool:, params:, status:} in call order
    def self.format(calls, last: true, width: nil)
      return nil if calls.size < MIN_CALLS

      failed = calls.count { |c| c[:status] == "error" }
      head = "#{calls.size} tool calls"
      head += " (#{failed} failed)" if failed.positive?
      counts = calls.each_with_object(Hash.new(0)) { |c, h| h[c[:tool]] += 1 }
      # Ties go to the tool used first (a Hash keeps insertion order, and
      # sort_by is not stable, so the index breaks them).
      top = counts.each_with_index.sort_by { |(_, n), i| [-n, i] }.first(TOP_TOOLS)
      fields = [head] + top.map { |(tool, n), _| "#{tool} ×#{n}" }
      if last
        call = calls.last
        params = call[:params].to_s.gsub(/\s+/, " ").strip
        fields << "last: #{[call[:tool], params].reject(&:empty?).join(" ")}"
      end
      cut(fields.join(SEPARATOR), width)
    end

    def self.cut(text, width)
      return text if width.nil? || text.length <= width
      return text[0, width] if width < 2

      "#{text[0, width - 1]}…"
    end
  end
end
