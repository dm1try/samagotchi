# frozen_string_literal: true

require "reline"

module Samagotchi
  class TerminalUI
    # A question's rows as slot content (Surface): laid out afresh for the
    # rows it gets. With room it shows everything, top down: a header, the
    # question (wrapped), detail lines, one row per option and a hint row.
    # When short, rows give way in this order: the hint, the details (and
    # the question's wrapped rows), the header; then the options fold into
    # as few packed rows as the width allows. The question's first row and
    # the options stay to the last.
    class QuestionSlot
      # A numbered option shows as "1) Apple", a word as "yes: continue".
      Option = Struct.new(:key, :label) do
        def text = key.match?(/\A\d+\z/) ? "#{key}) #{label}" : "#{key}: #{label}"
      end

      CONTINUE_QUESTION = "The turn ran out of iterations. Continue it?"

      # A continue offer (TurnFlow): what the answers at the ? prompt do.
      # @param context [Hash, nil] the offer's context (last_model_intent)
      def self.continue_offer(context = nil, paint: ->(text, _code) { text })
        intent = (context || {})[:last_model_intent] || (context || {})["last_model_intent"]
        details = intent.to_s.strip.empty? ? [] : ["  last step: #{intent.to_s.strip.tr("\n", " ")}"]
        new(question: CONTINUE_QUESTION, mark: "? ", details: details, question_code: 33, paint: paint,
            options: [Option.new("yes", "continue (Enter alone too)"), Option.new("no", "stop here"),
                      Option.new("no, <reason>", "stop and tell the model why")])
      end

      # The line a continue offer leaves in the scrollback.
      def self.continue_summary(outcome, paint: ->(text, _code) { text })
        "#{paint.call("? #{CONTINUE_QUESTION}", 33)} → #{outcome}"
      end

      # @param question [String] the first row's text, wrapped when there is room
      # @param mark [String] its prefix ("? ", "! ")
      # @param options [Array<Option>] key ("1", "yes") and label
      # @param paint [#call] (text, code) -> coloured text
      # @param note [String, nil] a dim row under the header (a relayed
      #   approval's delegate, or where else it waits); gives way with it
      def initialize(question:, mark:, options:, header: nil, details: [], hint: nil, question_code: 94,
                     paint: ->(text, _code) { text }, note: nil)
        @header = header
        @note = note
        @question = question.to_s
        @mark = mark
        @details = details
        @options = options
        @hint = hint
        @question_code = question_code
        @paint = paint
      end

      # @param width [Integer]
      # @param height [Integer, nil] nil: no limit
      # @return [Array<String>]
      def fit(width:, height:)
        width = [width.to_i, 10].max
        full = layout(width, hint: true, details: true, header: true, folded: false)
        return full if height.nil? || full.size <= height

        [
          { hint: false, details: true, header: true, folded: false },
          { hint: false, details: false, header: true, folded: false },
          { hint: false, details: false, header: false, folded: false },
          { hint: false, details: false, header: false, folded: true }
        ].each do |level|
          rows = layout(width, **level)
          return rows if rows.size <= height
        end
        layout(width, hint: false, details: false, header: false, folded: true).first([height, 0].max)
      end

      private

      def layout(width, hint:, details:, header:, folded:)
        rows = []
        rows << @paint.call(@header, 1) if header && @header
        rows << @paint.call(@note, 2) if header && @note
        question_rows = wrap(@question, width, first: @mark, indent: " " * @mark.size)
        question_rows = question_rows.first(1) unless details
        rows.concat(question_rows.map { |row| @paint.call(row, @question_code) })
        rows.concat(@details.map { |row| @paint.call(row, @question_code) }) if details
        rows.concat(folded ? folded_options(width) : @options.map { |o| @paint.call("  #{o.text}", 92) })
        rows << @paint.call("  [#{@hint}]", 90) if hint && @hint
        rows
      end

      # The options packed into rows of +width+: "  1) Allow once · 2) Deny".
      def folded_options(width)
        rows = []
        line = +""
        @options.each do |option|
          item = option.text
          candidate = line.empty? ? "  #{item}" : "#{line} · #{item}"
          if !line.empty? && display_width(candidate) > width
            rows << line
            line = "  #{item}"
          else
            line = +candidate
          end
        end
        rows << line unless line.empty?
        rows.map { |row| @paint.call(row, 92) }
      end

      # Word wrap at +width+ columns, the first row after +first+, the others
      # after +indent+; a word longer than a row is cut.
      def wrap(text, width, first:, indent:)
        rows = []
        line = first.dup
        words = false
        text.split(/(?<= )/).each do |word|
          if words && display_width(line + word.rstrip) > width
            rows << line.rstrip
            line = indent.dup
          end
          line << word
          words = true
          while display_width(line.rstrip) > width
            head, = Reline::Unicode.take_mbchar_range(line, 0, width, padding: false)
            rows << head
            line = "#{indent}#{line[head.size..]}"
          end
        end
        rows << line.rstrip unless line.strip.empty? && !rows.empty?
        rows
      end

      def display_width(text) = Reline::Unicode.calculate_width(text, true)
    end
  end
end
