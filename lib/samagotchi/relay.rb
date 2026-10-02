# frozen_string_literal: true

require_relative "guardrails/approval"

module Samagotchi
  # A delegate's approval reopened as the parent session's own (the
  # approval relay): the same kind "approval" and the same approval facts,
  # so every UI shows it as it shows the parent's own approvals, the diff
  # included, and Guardrails::ParentApprovals judges it the same way. The
  # question text names the delegate and its task over the child's own
  # text; `relay:` says which child and which of its questions it answers.
  # A relay of a relay (a grandchild's) grows relay.chain.
  module Relay
    # How much of the child's task the card keeps, and the question line.
    TASK_CHARS = 200
    TASK_LINE_CHARS = 80

    module_function

    # @param child [Session] the child as loaded (its id, its first prompt)
    # @param pending [Hash] the child's pending question (string keys inside
    #   when it came from a saved session)
    # @param relay_id [String] RelayDesk's id
    # @param more [Integer] other delegates' approvals waiting behind this one
    # @return [Hash] Engine#open_question fields
    def card(child, pending, relay_id:, more: 0)
      pending = deep_symbolize(pending)
      facts = pending[:approval].is_a?(Hash) ? pending[:approval] : {}
      short = child.id.to_s[0, 8]
      inner = pending[:relay].is_a?(Hash) ? pending[:relay] : nil
      chain = inner ? [*Array(inner[:chain]), short] : [short]
      asked = inner ? inner[:asked].to_s : pending[:question].to_s
      task = inner ? inner[:task].to_s : task_of(child)
      who = chain.reverse.join(" → ")
      {
        question: question_text(who, task, asked),
        options: relabel(Array(pending[:options]), facts[:scopes], who),
        header: header(who, more),
        multi_select: false,
        allow_freeform: pending.key?(:allow_freeform) ? !!pending[:allow_freeform] : true,
        kind: Guardrails::Approval::KIND,
        approval: facts,
        relay: { id: relay_id, child_id: child.id, child_short: short, child_question_id: pending[:id].to_s,
                 task: task, chain: chain, asked: asked, more: more.to_i }
      }
    end

    # delegate ab12 ("fix the flaky spec in …") asks:
    #   execute: git push origin main
    #     in /path/repo (repo samagotchi, branch main)
    def question_text(who, task, asked)
      line = task.empty? ? "delegate #{who} asks:" : "delegate #{who} (#{cut(task, TASK_LINE_CHARS).inspect}) asks:"
      [line, *asked.lines.map { |l| "  #{l.chomp}" }].join("\n")
    end

    def header(who, more)
      text = "Approve delegate #{who}'s tool call?"
      more.to_i.positive? ? "#{text} (+#{more} more delegate#{"s" if more.to_i > 1} waiting)" : text
    end

    # The child's options, by index: "session" is the child's session, so
    # it says whose; "once", "repo", "rule" and Deny keep their labels (the
    # approvals store is shared, a session scope keys on the child's id).
    def relabel(options, scopes, who)
      scopes = Array(scopes)
      options.each_with_index.map do |label, index|
        scopes[index].to_s == "session" ? "Allow this call for delegate #{who}'s session" : label.to_s
      end
    end

    # The child's task: its first prompt, on one line, cut.
    def task_of(child)
      raw = [child.first_preview, child.last_prompt].map(&:to_s).find { |text| !text.strip.empty? }
      cut(raw.to_s.gsub(/\s+/, " ").strip, TASK_CHARS)
    end

    def cut(text, limit) = text.length > limit ? "#{text[0, limit - 1]}…" : text

    # Session.load symbolizes only top-level keys.
    def deep_symbolize(value)
      case value
      when Hash then value.to_h { |key, inner| [key.to_sym, deep_symbolize(inner)] }
      when Array then value.map { |inner| deep_symbolize(inner) }
      else value
      end
    end
  end
end
