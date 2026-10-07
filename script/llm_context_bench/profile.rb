# frozen_string_literal: true

require "json"
require_relative "replay"

module LLMContextBench
  # What fills the sessions' context under none, the spike's Part A: the
  # resent tokens by category, the tool outputs by tool and size, the turns,
  # how much of a turn's output a later turn refers to (re-read or re-run,
  # its path mentioned, an identifier it brought in mentioned), and how
  # often a file is read again.
  class Profile
    # Categories counted as resent (thinking is stored, never resent).
    RESENT = %w[tool_output tool_call_args system_prompt model_prose user context_notes inline_thinking].freeze
    REFERENCES = %w[reread path_mention new_ident_mention any].freeze
    # A big output, in tokens.
    BIG = 2000

    attr_reader :categories, :by_tool, :sizes, :turns, :references, :reference_counts, :by_tool_reference, :reads,
                :args_by_tool

    # @param replays [Array<Replay>]
    def initialize(replays)
      @categories = Hash.new(0.0)
      @by_tool = Hash.new { |hash, key| hash[key] = { tokens: 0.0, count: 0 } }
      @args_by_tool = Hash.new(0.0)
      @sizes = []
      @turns = []
      @references = Hash.new(0.0)
      @reference_counts = Hash.new(0)
      @by_tool_reference = Hash.new { |hash, key| hash[key] = Hash.new(0.0) }
      @reads = { reads: 0, files: 0, files_read_twice: 0, repeat_reads: 0 }
      replays.each { |replay| add(replay) }
    end

    def resent_total = RESENT.sum { |key| categories[key] }

    def share(key) = resent_total.zero? ? 0.0 : categories[key] / resent_total

    # The size at +fraction+ (0..1) of the sorted output sizes.
    def size_at(fraction)
      sorted = sizes.sort
      sorted.empty? ? 0.0 : sorted[(fraction * (sorted.size - 1)).to_i]
    end

    # The JSON-able numbers.
    def to_h
      { categories: categories, resent_total: resent_total, by_tool: by_tool, args_by_tool: args_by_tool,
        sizes: size_summary,
        turns: turn_summary, references: references, reference_counts: reference_counts, reads: reads }
    end

    # Output sizes: percentiles, and the outputs of BIG tokens or more (their
    # share of the count and of the tokens).
    def size_summary
      big = sizes.select { |size| size >= BIG }
      total = sizes.sum
      { count: sizes.size, p50: size_at(0.5), p90: size_at(0.9), p99: size_at(0.99), max: sizes.max || 0,
        big_count_share: sizes.empty? ? 0.0 : big.size.fdiv(sizes.size), big_token_share: total.zero? ? 0.0 : big.sum / total }
    end

    def turn_summary
      totals = turns.map { |turn| turn[:total] }.sort
      return { count: 0 } if totals.empty?

      top = turns.sort_by { |turn| -turn[:total] }.first([1, turns.size / 10].max)
      top_total = top.sum { |turn| turn[:total] }
      { count: totals.size, p50: totals[totals.size / 2], p90: totals[(0.9 * (totals.size - 1)).to_i], max: totals.last,
        top_tenth_share: top_total / totals.sum, top_tenth_tool_share: top.sum { |turn| turn[:tool] } / top_total,
        heaviest: top.first(5).map { |turn| turn.slice(:session, :turn, :model, :tool, :calls, :args, :total) } }
    end

    private

    def add(replay)
      add_categories(replay)
      add_turns(replay)
      add_references(replay)
      add_reads(replay)
    end

    def add_categories(replay)
      replay.messages.each_with_index do |entry, index|
        case entry[:role].to_s
        when "system"
          categories[entry[:kind].nil? ? "system_prompt" : "context_notes"] += TextRefs.tokens(entry[:content])
        when "user" then categories["user"] += TextRefs.tokens(entry[:content])
        when "model" then add_model(replay, entry, index)
        end
      end
      replay.outputs.each do |output|
        categories["tool_output"] += output.tokens
        by_tool[output.name][:tokens] += output.tokens
        by_tool[output.name][:count] += 1
        sizes << output.tokens
      end
    end

    def add_model(replay, entry, index)
      prose, thinking, _native = replay.parts(entry)
      categories["model_prose"] += TextRefs.tokens(prose)
      categories["inline_thinking"] += TextRefs.tokens(thinking)
      categories["thinking"] += TextRefs.tokens(entry[:thinking])
      replay.calls[replay.request_of(index)].each do |call|
        tokens = TextRefs.tokens(JSON.generate(call.args))
        categories["tool_call_args"] += tokens
        args_by_tool[call.name] += tokens
      end
    end

    def add_turns(replay)
      replay.turns.each_with_index do |range, index|
        outputs = replay.outputs.select { |output| range.cover?(output.entry_index) }
        row = { session: replay.short_id, turn: index, model: replay.model_name, tool: outputs.sum(&:tokens),
                calls: outputs.size, args: 0.0, prose: 0.0, user: 0.0, system: 0.0 }
        range.each do |entry_index|
          entry = replay.messages[entry_index]
          case replay.role(entry_index)
          when "model"
            prose, thinking, = replay.parts(entry)
            row[:prose] += TextRefs.tokens(prose) + TextRefs.tokens(thinking)
            row[:args] += replay.calls[replay.request_of(entry_index)].sum { |call| TextRefs.tokens(JSON.generate(call.args)) }
          when "user" then row[:user] += TextRefs.tokens(entry[:content])
          when "system" then row[:system] += TextRefs.tokens(entry[:content])
          end
        end
        row[:total] = row.values_at(:tool, :args, :prose, :user, :system).sum
        turns << row
      end
    end

    # A turn's outputs against every later turn (the spike's proxy): the
    # last turn has none after it, so it isn't counted.
    def add_references(replay)
      replay.turns.each_with_index do |range, index|
        next if index + 1 >= replay.turns.size

        later = Later.new(replay, range.end...replay.messages.size)
        replay.outputs.select { |output| range.cover?(output.entry_index) }.each do |output|
          hits = later.references(output)
          add_reference(output, "all")
          REFERENCES.each { |key| add_reference(output, key) if hits[key] }
        end
      end
    end

    def add_reference(output, key)
      references[key] += output.tokens
      reference_counts[key] += 1
      by_tool_reference[output.name][key] += output.tokens
    end

    def add_reads(replay)
      counts = Hash.new(0)
      replay.calls.flatten.each do |call|
        call.target.keys.each { |key| counts[key] += 1 } if call.name == "read"
      end
      reads[:reads] += counts.values.sum
      reads[:files] += counts.size
      reads[:files_read_twice] += counts.count { |_key, count| count > 1 }
      reads[:repeat_reads] += counts.values.sum { |count| count - 1 }
    end
  end

  # The calls and model text of a span of a replay's entries, and whether
  # they refer to an output: re-read or re-run it (strict), mention its
  # path, or mention an identifier it brought in (loose).
  class Later
    attr_reader :calls

    def initialize(replay, range)
      models = range.select { |index| replay.role(index) == "model" }
      @calls = models.flat_map { |index| replay.calls[replay.request_of(index)] }
      texts = models.map { |index| replay.parts(replay.messages[index]).first }
      @text = (texts + @calls.map { |call| JSON.generate(call.args) }).join("\n")
    end

    def reread?(output) = calls.any? { |call| output.target.touches?(call.target) }

    def path_mention?(output)
      output.target.keys.any? { |key| @text.include?(key) || @text.include?(File.basename(key)) }
    end

    def ident_mention?(output) = output.new_idents.any? { |ident| @text.include?(ident) }

    def loose?(output) = reread?(output) || path_mention?(output) || ident_mention?(output)

    def references(output)
      hits = { "reread" => reread?(output), "path_mention" => path_mention?(output),
               "new_ident_mention" => ident_mention?(output) }
      hits.merge("any" => hits.values.any?)
    end
  end
end
