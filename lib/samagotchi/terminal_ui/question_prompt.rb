# frozen_string_literal: true

require_relative "question_slot"
require_relative "../turn_flow"
require_relative "../question_desk"

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
    # in "Deny"). The step-limit question (kind "continue") reads the
    # continue words (TurnFlow.continue_decision): Enter, yes, y or
    # /continue continue; no stops; "no, why" stops with the reason; 1 and
    # 2 pick the options.
    class QuestionPrompt
      DIFF_CODES = { "+" => 32, "-" => 31, "@" => 2, "\\" => 2 }.freeze

      # A parsed answer. +error+ set: re-ask. +note+: print, then accept.
      Answer = Struct.new(:selected, :freeform, :error, :note, keyword_init: true) do
        def ok? = error.nil?
      end

      attr_reader :id, :question, :options, :header
      # @return [String, nil] the parent's short id while this question waits
      #   in its card too (the approval relay)
      attr_reader :relayed_to

      # @param pending [Hash] Engine#pending_question (symbol or string keys)
      def initialize(pending)
        field = ->(key) { pending[key] || pending[key.to_s] }
        approval = field.call(:approval)
        @preview = approval.is_a?(Hash) ? (approval[:preview] || approval["preview"]) : nil
        @id = field.call(:id).to_s
        @question = field.call(:question).to_s
        # A delegate's approval relayed here: the delegate's own text is the
        # question, who asks a dim line (#note).
        relay = field.call(:relay)
        if relay.is_a?(Hash)
          get = ->(key) { relay[key] || relay[key.to_s] }
          chain = Array(get.call(:chain)).map(&:to_s)
          chain = [get.call(:child_id).to_s[0, 8]] if chain.empty?
          @delegate = chain.reverse.join(" → ")
          @delegate_task = get.call(:task).to_s
          @question = get.call(:asked).to_s unless get.call(:asked).to_s.strip.empty?
        end
        self.relayed_to = field.call(:relayed_to)
        @options = Array(field.call(:options)).map { |v| v.to_s.strip }.reject(&:empty?)
        header = field.call(:header).to_s.strip
        @header = header.empty? ? nil : header
        @multi = !!field.call(:multi_select)
        @free = !!field.call(:allow_freeform)
        @approval = field.call(:kind).to_s == "approval"
        @continue = field.call(:kind).to_s == "continue"
      end

      def multi? = @multi
      def free? = @free
      def approval? = @approval
      def continue? = @continue

      # The relay mark (QuestionDesk#annotate's relayed_to: a Hash, or the
      # short id), or nil when cleared.
      def relayed_to=(value)
        short = value.is_a?(Hash) ? (value[:parent_short] || value["parent_short"]) : value
        @relayed_to = short.to_s.strip.empty? ? nil : short.to_s
      end

      # The dim line under the header: which delegate asks (and its task),
      # or that this question waits in a parent too.
      def note
        if @delegate
          task = @delegate_task.empty? ? "" : " · #{@delegate_task}"
          return "  delegate #{@delegate}#{task}"
        end
        "  waiting in parent #{@relayed_to} too (answering here works)" if @relayed_to
      end

      # The line a question dismissed in a --non-interactive run leaves (no
      # one could answer it there): the REPL's own, and an attached UI's on
      # its cancel (QuestionDesk::UNANSWERABLE_REASON).
      UNANSWERABLE_TEXT = "(dismissed: no one to answer in a non-interactive run)"

      # What a question closed with no answer here says: a relayed approval
      # names where it went; else "(question cancelled)".
      def closed_text(reason)
        return UNANSWERABLE_TEXT if reason.to_s == QuestionDesk::UNANSWERABLE_REASON
        return CONTINUE_CLOSED.fetch(reason.to_s, "(question cancelled)") if continue?
        return "(question cancelled)" unless @delegate

        case reason.to_s
        when "answered_on_child" then "(answered in #{@delegate})"
        when "child_gone" then "(#{@delegate}'s worker is gone)"
        when "dismissed" then "(denied)"
        else "(left open in #{@delegate})"
        end
      end

      # The widget as slot content, fitted to the rows it gets (QuestionSlot).
      # @return [QuestionSlot]
      def slot(paint: ->(text, _code) { text })
        first, *rest = question.lines.map(&:chomp)
        keys = options.each_index.map { |idx| (idx + 1).to_s }
        QuestionSlot.new(header: approval? ? (header || "Approve tool call?") : header,
                         question: first.to_s, mark: mark, details: rest,
                         options: keys.zip(options).map { |key, label| QuestionSlot::Option.new(key, label) },
                         hint: slot_hint, question_code: approval? ? 33 : 94, paint: paint, note: note)
      end

      # Why a step-limit question closed unanswered here.
      CONTINUE_CLOSED = { "dropped" => "(dropped: a new prompt came)", "answered" => "(answered with /continue)",
                          "superseded" => "(set aside for another question)", "replaced" => "(asked again)" }.freeze

      # The most diff lines #preview_lines prints; the web shows them all.
      PREVIEW_LINES = 40

      # An edit/write approval's dry-run diff (approval.preview, symbol or
      # string keys: nested keys are strings after a reload or SSE), as
      # lines to print above the slot: coloured +/-, dim @@, cut at
      # PREVIEW_LINES. [] for none.
      def preview_lines(paint: ->(text, _code) { text })
        preview = @preview
        return [] unless preview.is_a?(Hash)

        get = ->(key) { preview[key] || preview[key.to_s] }
        return [paint.call("this edit would fail: #{get.call(:error)}", 33)] if get.call(:error)
        return [paint.call("diff not shown: #{get.call(:skipped)}", 2)] if get.call(:skipped)

        lines = get.call(:text).to_s.split("\n")
        return [] if lines.empty?

        # TextDiff's own cut note ("… N more lines") counts toward the rest.
        cut = lines.last.to_s[/\A… (\d+) more lines\z/, 1]
        lines.pop if cut
        hidden = [lines.size - PREVIEW_LINES, 0].max + cut.to_i
        shown = lines.first(PREVIEW_LINES).map { |line| paint.call(line, diff_code(line)) }
        shown.unshift(paint.call("new file", 2)) if get.call(:new_file)
        shown << paint.call("… #{hidden} more lines (full diff on the web)", 2) if hidden.positive?
        shown
      end

      # The one line that stays in the scrollback once the question closes:
      # the question and what became of it.
      # @param outcome [String] the answer (#answer_text) or what closed it
      def summary(outcome, paint: ->(text, _code) { text })
        who = @delegate ? "#{@delegate}: " : ""
        "#{paint.call("#{mark}#{who}#{question.lines.first.to_s.chomp}", approval? ? 33 : 94)} → #{outcome}"
      end

      # @param answer [Answer] an accepted one
      # @return [String] "Banana", "Apple, Cherry; ripe ones", "Deny: use a PR"
      def answer_text(answer)
        picked = answer.selected.to_a
        if approval? || continue?
          choice = picked.first || options.last
          return answer.freeform ? "#{choice}: #{answer.freeform}" : choice
        end

        [picked.join(", "), answer.freeform].reject { |part| part.to_s.empty? }.join("; ")
      end

      # @param raw [String] the typed line, not empty
      # @return [Answer]
      def parse(raw)
        return parse_approval(raw) if approval?
        return parse_continue(raw) if continue?

        raw = raw.to_s.strip
        # "1,3; my text": the first ';' separates the selection from freeform text.
        sel_part, free_part = raw.include?(";") ? raw.split(";", 2).map(&:strip) : [raw, nil]
        free_part = nil if free_part && free_part.empty?
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
        if continue?
          return "Enter or yes = #{options.first}; no = #{options.last}; no, <reason> = #{options.last} and tell the model why"
        end
        if approval?
          return "1-#{options.size}, y = #{options.first}, n = #{options.last}; add '; reason' to tell the model why; " \
                 "Enter alone denies"
        end

        hint = [multi? ? "Select one or more (e.g. 1,3)" : "Select one (e.g. 2)"]
        hint << "add '; text' for your own answer" if free?
        hint << "Enter alone cancels"
        hint.join("; ")
      end

      # The continue words, or an option's number. Empty is Continue (Enter
      # alone, as at the REPL's continue prompt).
      def parse_continue(raw)
        text = raw.to_s.strip
        if text.match?(/\A\d+\z/)
          idx = text.to_i - 1
          return Answer.new(selected: [options[idx]]) if idx.between?(0, options.size - 1)
        end
        decision, reason = TurnFlow.continue_decision(text)
        case decision
        when :resume then Answer.new(selected: [options.first])
        when :abort then Answer.new(selected: [options.last])
        when :abort_with_reason then Answer.new(selected: [options.last], freeform: reason)
        else Answer.new(error: "Answer yes (Enter alone too), no, or no, <reason>.")
        end
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

      # "+" green, "-" red, "@@" and "\ No newline" dim, context plain.
      def diff_code(line) = DIFF_CODES.fetch(line[0], 0)
    end
  end
end
