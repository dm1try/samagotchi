# frozen_string_literal: true

require_relative "question_slot"

module Samagotchi
  class TerminalUI
    # An ask_user_question prompt as the terminal shows it: the widget as
    # slot content (#slot), the line it leaves (#summary) and the parsing of
    # a typed answer ("2", "1,3", "1 3; text", option labels). No I/O:
    # callers draw the slot and print the messages, and
    # record the answer (the REPL on its Engine, an attached UI over the
    # Bridge). An approval (kind "approval") takes only a number, an exact
    # label, y (the first option, Allow once) or n (the last, Deny), plus
    # an optional "; reason"; a substring would pick the wrong one ("y" is
    # in "Deny").
    class QuestionPrompt
      # A parsed answer. +error+ set: re-ask. +note+: print, then accept.
      Answer = Struct.new(:selected, :freeform, :error, :note, keyword_init: true) do
        def ok? = error.nil?
      end

      attr_reader :id, :question, :options, :header

      # @param pending [Hash] Engine#pending_question (symbol or string keys)
      def initialize(pending)
        field = ->(key) { pending[key] || pending[key.to_s] }
        @id = field.(:id).to_s
        @question = field.(:question).to_s
        @options = Array(field.(:options)).map { |v| v.to_s.strip }.reject(&:empty?)
        header = field.(:header).to_s.strip
        @header = header.empty? ? nil : header
        @multi = !!field.(:multi_select)
        @free = !!field.(:allow_freeform)
        @approval = field.(:kind).to_s == "approval"
      end

      def multi? = @multi
      def free? = @free
      def approval? = @approval

      # The widget as slot content, fitted to the rows it gets (QuestionSlot).
      # @return [QuestionSlot]
      def slot(paint: ->(text, _code) { text })
        first, *rest = question.lines.map(&:chomp)
        keys = options.each_index.map { |idx| (idx + 1).to_s }
        QuestionSlot.new(header: approval? ? (header || "Approve tool call?") : header,
                         question: first.to_s, mark: mark, details: rest,
                         options: keys.zip(options).map { |key, label| QuestionSlot::Option.new(key, label) },
                         hint: slot_hint, question_code: approval? ? 33 : 94, paint: paint)
      end

      # The one line that stays in the scrollback once the question closes:
      # the question and what became of it.
      # @param outcome [String] the answer (#answer_text) or what closed it
      def summary(outcome, paint: ->(text, _code) { text })
        "#{paint.("#{mark}#{question.lines.first.to_s.chomp}", approval? ? 33 : 94)} → #{outcome}"
      end

      # @param answer [Answer] an accepted one
      # @return [String] "Banana", "Apple, Cherry; ripe ones", "Deny: use a PR"
      def answer_text(answer)
        picked = answer.selected.to_a
        if approval?
          choice = picked.first || options.last
          return answer.freeform ? "#{choice}: #{answer.freeform}" : choice
        end

        [picked.join(", "), answer.freeform].reject { |part| part.to_s.empty? }.join("; ")
      end

      # @param raw [String] the typed line, not empty
      # @return [Answer]
      def parse(raw)
        return parse_approval(raw) if approval?

        raw = raw.to_s.strip
        # "1,3; my text": the first ';' separates the selection from freeform text.
        sel_part, free_part = raw.include?(";") ? raw.split(";", 2).map(&:strip) : [raw, nil]
        free_part = nil if free_part&.empty?
        # Models forget to flag freeform: accept it anyway, with a note.
        note = free_part && !free? ? "(note: freeform not flagged but accepting '#{free_part}')" : nil

        labels = []
        sel_part.split(/[,\s]+/).reject(&:empty?).each do |tok|
          label, error = option_for(tok)
          return Answer.new(error: error, note: note) if error

          labels << label
        end
        labels.uniq!

        return Answer.new(error: "No selection. Try again.", note: note) if labels.empty? && free_part.nil?
        return Answer.new(error: "This is single-select (pick one). Try again.", note: note) if !multi? && labels.size > 1

        Answer.new(selected: labels, freeform: free_part, note: note)
      end

      private

      def mark = approval? ? "! " : "? "

      def slot_hint
        if approval?
          return "1-#{options.size}, y = #{options.first}, n = #{options.last}; add '; reason' to tell the model why; " \
                 "Enter alone denies"
        end

        hint = [multi? ? "Select one or more (e.g. 1,3)" : "Select one (e.g. 2)"]
        hint << "add '; text' for your own answer" if free?
        hint << "Enter alone cancels"
        hint.join("; ")
      end

      def parse_approval(raw)
        sel_part, free_part = raw.to_s.strip.split(";", 2).map { |part| part.to_s.strip }
        free_part = nil if free_part.to_s.empty?
        return Answer.new(selected: [], freeform: free_part) if sel_part.to_s.empty? && free_part

        label = approval_option(sel_part.to_s)
        unless label
          return Answer.new(error: "Answer with 1-#{options.size}, y (#{options.first}) or n (#{options.last}).")
        end

        Answer.new(selected: [label], freeform: free_part)
      end

      def approval_option(token)
        down = token.downcase
        return options.first if %w[y yes].include?(down)
        return options.last if %w[n no].include?(down)

        if token.match?(/\A\d+\z/)
          idx = token.to_i - 1
          return idx.between?(0, options.size - 1) ? options[idx] : nil
        end
        options.find { |o| o.downcase == down }
      end

      # A number, or an option label (exact or substring, any case).
      def option_for(tok)
        if tok.match?(/\A\d+\z/)
          idx = tok.to_i - 1
          return [nil, "Invalid choice '#{tok}': pick 1-#{options.size}"] if idx.negative? || idx >= options.size

          return [options[idx], nil]
        end

        found = options.find { |o| o.downcase == tok.downcase || o.downcase.include?(tok.downcase) }
        found ? [found, nil] : [nil, "Unknown option '#{tok}'. Use numbers 1-#{options.size} or exact labels."]
      end
    end
  end
end
