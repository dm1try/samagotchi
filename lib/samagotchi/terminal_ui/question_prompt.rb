# frozen_string_literal: true

module Samagotchi
  class TerminalUI
    # An ask_user_question prompt as the terminal shows it: the widget's
    # lines and the parsing of a typed answer ("2", "1,3", "1 3; text",
    # option labels). No I/O: callers print the lines and messages, and
    # record the answer (the REPL on its Engine, an attached UI over the
    # Bridge).
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
      end

      def multi? = @multi
      def free? = @free

      # The widget, top down; +paint+ colours a string (text, code).
      # @return [Array<String>]
      def lines(paint: ->(text, _code) { text }, color: false)
        lines = []
        lines << paint.(header, 1) if header
        lines << paint.("? #{question}", 94)
        options.each_with_index { |opt, idx| lines << paint.("  #{idx + 1}) #{opt}", 92) }
        hint = [multi? ? "Select one or more (e.g. 1,3)" : "Select one (e.g. 2)"]
        hint << "add '; freeform text' when Other/freeform needed" if free?
        lines << paint.("  [#{hint.join('; ')}]", 90) if color
        lines
      end

      # @param raw [String] the typed line, not empty
      # @return [Answer]
      def parse(raw)
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
