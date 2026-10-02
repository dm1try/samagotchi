# frozen_string_literal: true

require "json"

module Samagotchi
  # How a wait's end (ReplyWait::Result) reads to whoever runs chi as a
  # sub-agent: `chi send --wait` and `chi answer`. One JSON object for
  # --format json, or a line (a block for a question) for stderr, and the
  # exit status. A question carries everything needed to answer it, so a
  # parent agent can answer from the output alone. Kept apart from the
  # commands so a later delegate_answer tool reports the same shape.
  module ParentReport
    EXIT_ANSWERED = 0
    EXIT_FAILED = 1
    EXIT_QUESTION = 3
    EXIT_RUNNING = 4

    # The approval facts a parent needs; the rest (preview, branch) is the
    # card's.
    APPROVAL_KEYS = %i[tool label command paths args cwd rule source reason scopes].freeze

    module_function

    # @param result [ReplyWait::Result]
    # @return [String] answered, question, failed, canceled, no_answer,
    #   error, worker_gone, stopped or running
    def status(result)
      case result.status
      when :done then "answered"
      when :waiting_for_answer then "question"
      when :no_reply
        case result.outcome
        when "failed" then "failed"
        when "canceled" then "canceled"
        else "no_answer"
        end
      when :error then "error"
      when :worker_gone then "worker_gone"
      when :stopped then "stopped"
      # ReplyWait's own :canceled is the caller giving up (its cancelled:),
      # and :timeout the deadline: the turn goes on either way.
      else "running"
      end
    end

    # @return [Integer] 0 answered, 3 a question waits, 4 still running,
    #   1 anything else
    def exit_status(result)
      case status(result)
      when "answered" then EXIT_ANSWERED
      when "question" then EXIT_QUESTION
      when "running" then EXIT_RUNNING
      else EXIT_FAILED
      end
    end

    # @param session_id [String]
    # @param timeout [Numeric, nil] the wait's --timeout (for the running detail)
    # @return [Hash] the --format json object
    def json(result, session_id:, timeout: nil)
      report = { status: status(result), session_id: session_id }
      case report[:status]
      when "answered" then report[:text] = result.text.to_s
      when "question"
        question = question(result.question)
        report[:question] = question
        report[:answer_with] = answer_with(session_id, question)
      else report[:detail] = detail(result, session_id: session_id, timeout: timeout)
      end
      report
    end

    # @return [String] the JSON object as one line
    def json_line(result, session_id:, timeout: nil)
      JSON.generate(json(result, session_id: session_id, timeout: timeout))
    end

    # A pending question (Session#pending_question) as a parent sees it.
    # kind is "question" for the model's own (the desk stores none),
    # "hook" or "approval".
    # @return [Hash]
    def question(pending)
      pending ||= {}
      approval = pending[:approval].is_a?(Hash) ? symbolize(pending[:approval]) : nil
      {
        id: pending[:id].to_s,
        kind: (pending[:kind] || "question").to_s,
        header: blank(pending[:header]),
        text: pending[:question].to_s,
        options: Array(pending[:options]).map(&:to_s),
        multi_select: !!pending[:multi_select],
        allow_freeform: !!pending[:allow_freeform],
        approval: approval&.slice(*APPROVAL_KEYS)
      }.compact
    end

    # The command that answers +question+; N is the parent's to fill in.
    def answer_with(session_id, question)
      "chi answer #{session_id} --question #{question[:id]} --option N"
    end

    # What a wait that ended without an answer says, one line.
    def detail(result, session_id:, timeout: nil)
      attach = "chi --attach #{session_id}"
      case result.status
      when :waiting_for_answer
        "waiting for an answer: #{first_line(result.question&.dig(:question))}; open it: #{attach} or the web"
      when :no_reply then "#{no_reply_line(result)}; #{attach} shows it"
      when :error then "the worker failed: #{result.text}; #{attach} shows what happened"
      when :worker_gone then "the worker is gone; #{attach} shows what happened"
      when :stopped then "the session was stopped (chi sessions stop)"
      else timeout ? "still running after #{format("%g", timeout)} s: #{attach}" : "still running: #{attach}"
      end
    end

    # The whole question for stderr: header, text, numbered options, what
    # else it takes, and the commands that answer it.
    # @return [String] lines, newline-terminated
    def question_text(pending, session_id:)
      q = question(pending)
      lines = ["waiting for an answer (#{q[:kind]}): #{q[:header] || first_line(q[:text])}"]
      text_lines = q[:text].strip.lines.map(&:rstrip)
      text_lines = text_lines.drop(1) unless q[:header]
      lines.concat(text_lines.map { |line| "  #{line}" })
      q[:options].each_with_index { |option, i| lines << "    #{i + 1}. #{option}" }
      lines << "  more than one allowed: repeat --option" if q[:multi_select]
      lines << "  free text allowed: --text" if q[:allow_freeform]
      lines << "  answer: #{answer_with(session_id, q)}"
      lines << "  or open it: chi --attach #{session_id} or the web"
      lines.map { |line| "#{line}\n" }.join
    end

    def no_reply_line(result)
      case result.outcome
      when "failed" then result.text.to_s.strip.empty? ? "the turn failed" : "the turn failed: #{result.text.strip}"
      when "canceled" then "the turn was canceled"
      when "completed" then "the turn ended with no visible answer"
      else "the turn ended without a reply (canceled, failed or empty)"
      end
    end

    def first_line(text)
      text.to_s.strip.lines.first.to_s.strip
    end

    def blank(value)
      value.to_s.strip.empty? ? nil : value.to_s
    end

    def symbolize(hash)
      hash.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
    end
  end
end
