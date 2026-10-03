# frozen_string_literal: true

require "delegate"
require "json"

require_relative "cli/exit"

module Samagotchi
  # How a wait's end (ReplyWait::Result) reads to whoever runs chi as a
  # sub-agent: `chi send --wait` and `chi answer`. One JSON object for
  # --format json, or a line (a block for a question) for stderr, and the
  # exit status. A question carries everything needed to answer it, so a
  # parent agent can answer from the output alone. Kept apart from the
  # commands so a later delegate_answer tool reports the same shape.
  module ParentReport
    # The approval facts a parent needs; the rest (preview, branch) is the
    # card's.
    APPROVAL_KEYS = %i[tool label command paths args cwd rule source reason scopes].freeze

    # stderr that keeps its last line: with --format json a failure before
    # any wait is reported from it (#error_line).
    class LastLine < SimpleDelegator
      attr_reader :last

      def puts(*lines)
        @last = lines.last.to_s.chomp unless lines.empty?
        __getobj__.puts(*lines)
      end
    end

    module_function

    # @param result [ReplyWait::Result]
    # @return [String] answered, question, failed, canceled, limit (the
    #   turn ran out of iterations, nobody asked), not_continued (a Stop
    #   answered the step-limit question), no_answer, error, worker_gone,
    #   stopped or running
    def status(result)
      case result.status
      when :done then "answered"
      when :waiting_for_answer then "question"
      when :no_reply
        case result.outcome
        when "failed" then "failed"
        when "canceled" then "canceled"
        when "exhausted" then "limit"
        when "not_continued" then "not_continued"
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

    # @return [Integer] 0 answered (or not continued: the Stop asked for
    #   was carried out), 3 a question waits, 4 still running, 1 anything
    #   else
    def exit_status(result)
      case status(result)
      when "answered", "not_continued" then CLI::Exit::OK
      when "question" then CLI::Exit::QUESTION
      when "running" then CLI::Exit::RUNNING
      else CLI::Exit::FAILED
      end
    end

    # @param session_id [String]
    # @param timeout [Numeric, nil] the wait's --timeout (for the running detail)
    # @param extra [Hash] more keys for the object (chi answer's
    #   answered_here: false)
    # @return [Hash] the --format json object
    def json(result, session_id:, timeout: nil, extra: {})
      report = { status: status(result), session_id: session_id }
      case report[:status]
      when "answered" then report[:text] = result.text.to_s
      when "question"
        question = question(result.question)
        report[:question] = question
        report[:answer_with] = answer_with(session_id, question)
      else report[:detail] = detail(result, session_id: session_id, timeout: timeout)
      end
      report.merge(extra)
    end

    # @return [String] the JSON object as one line
    def json_line(result, session_id:, timeout: nil, extra: {})
      JSON.generate(json(result, session_id: session_id, timeout: timeout, extra: extra))
    end

    # Print a wait's end the way the commands do: the JSON object on
    # stdout, or the reply on stdout and anything else on stderr (a
    # question in full) after "chi send: ".
    # @param command [String] "chi send", "chi answer"
    # @param extra [Hash] more keys for the JSON object (#json)
    # @return [Integer] the exit status
    def report(result, session_id:, stdout:, stderr:, command:, json: false, timeout: nil, extra: {})
      if json
        stdout.puts(json_line(result, session_id: session_id, timeout: timeout, extra: extra))
      elsif result.status == :done
        stdout.puts(result.text)
      else
        stdout.flush
        text = if result.status == :waiting_for_answer
                 question_text(result.question, session_id: session_id)
               else
                 "#{detail(result, session_id: session_id, timeout: timeout)}\n"
               end
        stderr.print("#{command}: #{text}")
      end
      stdout.flush
      exit_status(result)
    end

    # A failure before any wait (no such session, a busy one, a message
    # that didn't go in) as the JSON object.
    # @param session_id [String, nil]
    def error_line(detail, session_id: nil)
      JSON.generate({ status: "error", session_id: session_id, detail: detail.to_s })
    end

    # A pending question (Session#pending_question) as a parent sees it.
    # kind is "question" for the model's own (the desk stores none),
    # "hook", "approval" or "continue" (the step-limit question, with the
    # turn's limit).
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
        limit: pending[:limit],
        approval: approval&.slice(*APPROVAL_KEYS)
      }.compact
    end

    # The command that answers +question+; N is the parent's to fill in.
    # An approval's is a deny: allowing it is the user's
    # (Guardrails::ParentApprovals). A step-limit question's continues the
    # turn (its Stop form is in #question_text).
    def answer_with(session_id, question)
      return "chi answer #{session_id} --question #{question[:id]} --option Deny --text WHY" if approval?(question)
      return "chi answer #{session_id} --question #{question[:id]} --option Continue" if continue?(question)

      "chi answer #{session_id} --question #{question[:id]} --option N"
    end

    # What a parent does with an approval.
    DENY_AND_TELL = "deny it, and tell your user"

    # The other way: the user answers it in chi (the web's bell and badge
    # say it waits), and a wait with no message waits past it.
    def leave_open(session_id)
      "or leave it open: tell your user it waits in chi web (session #{session_id[0, 8]}); " \
        "chi send --wait --format json #{session_id} waits until they answer"
    end

    def approval?(question)
      question.is_a?(Hash) && (question[:kind] || question["kind"]).to_s == "approval"
    end

    # The step-limit question (ContinueOffer).
    def continue?(question)
      question.is_a?(Hash) && (question[:kind] || question["kind"]).to_s == "continue"
    end

    # What a message does to a step-limit question.
    def message_drops(session_id)
      "a message instead (chi send #{session_id} -m …) drops it and starts a new turn"
    end

    # What a wait that ended without an answer says, one line.
    def detail(result, session_id:, timeout: nil)
      attach = "chi --attach #{session_id}"
      case result.status
      when :waiting_for_answer
        if approval?(result.question)
          "waiting for an approval: #{first_line(result.question[:question])}; #{DENY_AND_TELL}"
        elsif continue?(result.question)
          "waiting at the step limit: #{first_line(result.question[:question])}; " \
            "answer Continue or Stop: chi answer #{session_id} --question #{result.question[:id]} --option Continue"
        else
          "waiting for an answer: #{first_line(result.question&.dig(:question))}; open it: #{attach} or the web"
        end
      when :no_reply then "#{no_reply_line(result, session_id)}; #{attach} shows it"
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
      if approval?(q)
        lines << "  allowing it is up to your user: #{DENY_AND_TELL}"
        lines << "  deny: #{answer_with(session_id, q)}"
        lines << "  #{leave_open(session_id)}"
      elsif continue?(q)
        lines << "  continue: #{answer_with(session_id, q)}"
        lines << "  stop: chi answer #{session_id} --question #{q[:id]} --option Stop --text WHY (the text is optional; the model reads it)"
        lines << "  #{message_drops(session_id)}"
      else
        lines << "  more than one allowed: repeat --option" if q[:multi_select]
        lines << "  free text allowed: --text" if q[:allow_freeform]
        lines << "  answer: #{answer_with(session_id, q)}"
        lines << "  or open it: chi --attach #{session_id} or the web"
      end
      lines.map { |line| "#{line}\n" }.join
    end

    def no_reply_line(result, session_id = nil)
      case result.outcome
      when "failed" then result.text.to_s.strip.empty? ? "the turn failed" : "the turn failed: #{result.text.strip}"
      when "canceled" then "the turn was canceled"
      when "completed" then "the turn ended with no visible answer"
      when "not_continued" then "the turn was not continued (Stop); its work so far stays"
      when "exhausted"
        "the turn ran out of iterations#{" (#{result.limit} steps)" if result.limit} before it answered; " \
          "chi send #{session_id} -m '/continue yes' continues it, a message drops it"
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
