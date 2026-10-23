# frozen_string_literal: true

require "delegate"
require "json"

require_relative "chi_invocation"
require_relative "cli/exit"
require_relative "pending_question"
require_relative "session"
require_relative "turn_checkpoint"
require_relative "guardrails/parent_policy"

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
    #   answered the step-limit question), removed (the queued message was
    #   taken back before it ran), no_answer, error, worker_gone, stopped
    #   or running
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
        when "removed" then "removed"
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
    # @param strategy [Guardrails::ParentPolicy::Strategy, nil] what a parent
    #   may pick on the waited-for session (#strategy_for); nil: config.yml's
    # @param via [ChiInvocation] how the printed commands are spelled (this
    #   machine's chi, or chi --remote NAME); each function here takes it
    def json(result, session_id:, timeout: nil, extra: {}, strategy: nil, via: ChiInvocation::HERE)
      report = { status: status(result), session_id: session_id }
      report[:turn_id] = result.turn_id unless result.turn_id.to_s.empty?
      case report[:status]
      when "answered" then report[:text] = result.text.to_s
      when "question"
        question = question(result.question, strategy: strategy)
        report[:question] = question
        report[:answer_with] = answer_with(session_id, question, via: via)
      else
        report.merge!(stop_facts(result))
        report[:detail] = detail(result, session_id: session_id, timeout: timeout, strategy: strategy, via: via)
      end
      report.merge(extra)
    end

    # Why a failed or canceled turn stopped, as far as last_turn knows
    # (ReplyWait::Result): error_kind and retryable, cancel_reason and
    # stopped_by; absent when unknown.
    # @return [Hash]
    def stop_facts(result)
      case status(result)
      when "failed" then { error_kind: result.error_kind, retryable: result.retryable, kept_steps: result.kept_steps }.compact
      when "canceled" then { cancel_reason: result.cancel_reason, stopped_by: result.stopped_by }.compact
      else {}
      end
    end

    # @return [String] the JSON object as one line
    def json_line(result, session_id:, timeout: nil, extra: {}, strategy: nil, via: ChiInvocation::HERE)
      JSON.generate(json(result, session_id: session_id, timeout: timeout, extra: extra, strategy: strategy, via: via))
    end

    # Print a wait's end the way the commands do: the JSON object on
    # stdout, or the reply on stdout and anything else on stderr (a
    # question in full) after "chi send: ".
    # @param command [String] "chi send", "chi answer"
    # @param extra [Hash] more keys for the JSON object (#json)
    # @return [Integer] the exit status
    def report(result, session_id:, stdout:, stderr:, command:, json: false, timeout: nil, extra: {}, strategy: nil,
               via: ChiInvocation::HERE)
      if json
        stdout.puts(json_line(result, session_id: session_id, timeout: timeout, extra: extra, strategy: strategy, via: via))
      elsif result.status == :done
        stdout.puts(result.text)
      else
        stdout.flush
        text = if result.status == :waiting_for_answer
                 question_text(result.question, session_id: session_id, strategy: strategy, via: via)
               else
                 "#{detail(result, session_id: session_id, timeout: timeout, turn_id: result.turn_id, strategy: strategy,
                                   via: via)}\n"
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

    # A pending question (Session#pending_question, a PendingQuestion) as a
    # parent sees it.
    # kind is "question" for the model's own (the desk stores none),
    # "hook", "approval" or "continue" (the step-limit question, with the
    # turn's limit). allowed_options: the options a parent may pick, by
    # +strategy+ (nil: this process's guardrails.parent_answers;
    # Guardrails::ParentPolicy), when that is not all of them.
    # @return [Hash]
    def question(pending, strategy: nil)
      pending = PendingQuestion.from_file(pending) || PendingQuestion.new
      approval = pending.approval.is_a?(Hash) ? symbolize(pending.approval) : nil
      options = Array(pending.options).map(&:to_s)
      allowed = allowed_options(pending, strategy: strategy)
      {
        id: pending.id.to_s,
        kind: (pending.kind || "question").to_s,
        header: blank(pending.header),
        text: pending.question.to_s,
        options: options,
        multi_select: !!pending.multi_select,
        allow_freeform: !!pending.allow_freeform,
        allowed_options: (allowed unless allowed == options),
        limit: pending.limit,
        approval: approval&.slice(*APPROVAL_KEYS)
      }.compact
    end

    # The command that answers +question+; N is the parent's to fill in.
    # An approval's is a deny: a wider allow is the user's (#question_text
    # lists an Allow once a parent may give). A step-limit question's
    # continues the turn, or stops it where a parent may not continue (its
    # other form is in #question_text).
    def answer_with(session_id, question, via: ChiInvocation::HERE)
      return answer_command(session_id, question, "Deny --text WHY", via: via) if approval?(question)
      return stop_command(session_id, question, via: via) if continue?(question) && !may_continue?(question)
      return answer_command(session_id, question, "Continue", via: via) if continue?(question)

      # The one option a parent may pick (cost-cap's Stop under hard).
      only = Array(question[:allowed_options])
      return answer_command(session_id, question, option_arg(only.first), via: via) if only.size == 1

      answer_command(session_id, question, "N", via: via)
    end

    # chi answer ID --question QID --option +option+ (its words after
    # --option: a label, maybe --text).
    def answer_command(session_id, question, option, via: ChiInvocation::HERE)
      via.command("answer #{session_id} --question #{question[:id]} --option #{option}")
    end

    # What a parent does with an approval it may not allow.
    DENY_AND_TELL = "deny it, and tell your user"

    # The labels a parent may pick on +pending+ (a PendingQuestion, or a
    # Hash with its fields) by +strategy+ (nil: this process's).
    # @return [Array<String>]
    def allowed_options(pending, strategy: nil)
      pending = PendingQuestion.from_file(pending) || PendingQuestion.new
      Guardrails::ParentPolicy.allowed_options(pending, strategy: policy(strategy))
    end

    # What a parent may pick on the session +session_id+: config.yml's
    # level tightened by the session file's own parent_answers
    # (Guardrails::ParentPolicy.for_session); config.yml's when there is no
    # such session, hard (the strictest) when its file can't be read.
    # @return [Guardrails::ParentPolicy::Strategy]
    def strategy_for(session_id, state_dir:)
      return Guardrails::ParentPolicy.current unless Session.exist?(session_id, state_dir: state_dir)

      Guardrails::ParentPolicy.for_session(Session.load(session_id, state_dir: state_dir))
    rescue ArgumentError, KeyError, TypeError, NoMethodError, SystemCallError, JSON::ParserError
      Guardrails::ParentPolicy.strategy(Guardrails::ParentPolicy::HARD)
    end

    # +strategy+, or this process's config.yml's.
    def policy(strategy) = strategy || Guardrails::ParentPolicy.current

    # An approval's options a parent may allow (Allow once under soft).
    def allowed_allows(question, strategy: nil)
      question = question(question, strategy: strategy) unless question.is_a?(Hash) && question.key?(:text)
      deny = Guardrails::Approval::DENY
      question.fetch(:allowed_options, question[:options]).reject { |label| label == deny }
    end

    # What a parent does with an approval: deny it and tell its user, or
    # give the Allow once its strategy lets it.
    def approval_advice(question, strategy: nil)
      allows = allowed_allows(question, strategy: strategy)
      return DENY_AND_TELL if allows.empty?

      "#{allows.join(" or ")} is yours to give (#{policy(strategy).label}); " \
        "anything wider is up to your user: #{DENY_AND_TELL}"
    end

    # Whether a parent may answer Continue to a step-limit question.
    def may_continue?(question, strategy: nil)
      question = question(question, strategy: strategy) unless question.is_a?(Hash) && question.key?(:text)
      question.fetch(:allowed_options, question[:options]).include?(Guardrails::ParentPolicy::CONTINUE)
    end

    def stop_command(session_id, question, via: ChiInvocation::HERE)
      answer_command(session_id, question, "Stop --text WHY", via: via)
    end

    def option_arg(label) = label.match?(/\A[\w.-]+\z/) ? label : label.inspect

    # The other way: the user answers it in chi (the web's bell and badge
    # say it waits), and a wait with no message waits past it.
    def leave_open(session_id, via: ChiInvocation::HERE)
      web = via.remote? ? via.web : "chi web"
      "or leave it open: tell your user it waits in #{web} (session #{session_id[0, 8]}); " \
        "#{via.command("send --wait --format json #{session_id}")} waits until they answer"
    end

    # @param question [PendingQuestion, Hash, nil] a pending question, or a
    #   Hash with its kind (#question's, Session#waiting_question's)
    def approval?(question) = kind_of(question) == "approval"

    # The step-limit question (ContinueOffer).
    def continue?(question) = kind_of(question) == "continue"

    def kind_of(question)
      case question
      when PendingQuestion then question.kind.to_s
      when Hash then (question[:kind] || question["kind"]).to_s
      end
    end

    # What a message does to a step-limit question.
    def message_drops(session_id, via: ChiInvocation::HERE)
      "a message instead (#{via.command("send #{session_id} -m …")}) drops it and starts a new turn"
    end

    # What a wait that ended without an answer says, one line.
    def detail(result, session_id:, timeout: nil, turn_id: nil, strategy: nil, via: ChiInvocation::HERE)
      shows = via.shows(session_id)
      case result.status
      when :waiting_for_answer
        q = question(result.question, strategy: strategy)
        if approval?(q)
          "waiting for an approval: #{first_line(q[:text])}; #{approval_advice(q, strategy: strategy)}"
        elsif continue?(q) && !may_continue?(q)
          "waiting at the step limit: #{first_line(q[:text])}; a parent may only stop it here " \
            "(#{policy(strategy).label}): #{stop_command(session_id, q, via: via)}, or tell your user it waits"
        elsif continue?(q)
          "waiting at the step limit: #{first_line(q[:text])}; " \
            "answer Continue or Stop: #{answer_command(session_id, q, "Continue", via: via)}"
        else
          "waiting for an answer: #{first_line(q[:text])}; open it: #{via.open_it(session_id)}"
        end
      when :no_reply then "#{no_reply_line(result, session_id, strategy: strategy, via: via)}; #{shows} shows it"
      when :error then "the worker failed: #{result.text}; #{shows} shows what happened"
      when :worker_gone then "the worker is gone; #{shows} shows what happened"
      when :stopped then "the session was stopped (chi sessions stop)"
      else
        wait_again = via.command("send --wait --turn #{turn_id} #{session_id}") unless turn_id.to_s.empty?
        hint = wait_again || shows
        timeout ? "still running after #{format("%g", timeout)} s: #{hint}" : "still running: #{hint}"
      end
    end

    # The whole question for stderr: header, text, numbered options, what
    # else it takes, and the commands that answer it.
    # @return [String] lines, newline-terminated
    def question_text(pending, session_id:, strategy: nil, via: ChiInvocation::HERE)
      q = question(pending, strategy: strategy)
      lines = ["waiting for an answer (#{q[:kind]}): #{q[:header] || first_line(q[:text])}"]
      text_lines = q[:text].strip.lines.map(&:rstrip)
      text_lines = text_lines.drop(1) unless q[:header]
      lines.concat(text_lines.map { |line| "  #{line}" })
      q[:options].each_with_index { |option, i| lines << "    #{i + 1}. #{option}" }
      if approval?(q)
        allows = allowed_allows(q)
        if allows.empty?
          lines << "  allowing it is up to your user: #{DENY_AND_TELL}"
        else
          lines << "  #{approval_advice(q, strategy: strategy)}"
          allows.each { |label| lines << "  allow: #{answer_command(session_id, q, option_arg(label), via: via)}" }
        end
        lines << "  deny: #{answer_with(session_id, q, via: via)}"
        lines << "  #{leave_open(session_id, via: via)}"
      elsif continue?(q)
        lines << if may_continue?(q)
                   "  continue: #{answer_with(session_id, q, via: via)}"
                 else
                   "  continuing it is up to your user (#{policy(strategy).label}): stop it, or tell your user it waits"
                 end
        lines << "  stop: #{stop_command(session_id, q, via: via)} (the text is optional; the model reads it)"
        lines << "  #{message_drops(session_id, via: via)}"
      else
        lines << "  more than one allowed: repeat --option" if q[:multi_select]
        lines << "  free text allowed: --text" if q[:allow_freeform]
        if q[:allowed_options]
          lines << "  a parent may pick #{q[:allowed_options].map { |o| option_arg(o) }.join(", ")}; the others are up to your user"
        end
        lines << "  answer: #{answer_with(session_id, q, via: via)}"
        lines << "  or open it: #{via.open_it(session_id)}"
      end
      lines.map { |line| "#{line}\n" }.join
    end

    def no_reply_line(result, session_id = nil, strategy: nil, via: ChiInvocation::HERE)
      return command_line(result) if result.origin == TurnCheckpoint::COMMAND_ORIGIN

      case result.outcome
      when "failed" then failed_line(result)
      when "canceled"
        # A turn its worker died in, settled by the next (TurnCheckpoint.settle).
        result.cancel_reason == "worker_stopped" ? "the turn was canceled: its worker exited mid-turn" : "the turn was canceled"
      when "completed" then "the turn ended with no visible answer"
      when "not_continued" then "the turn was not continued (Stop); its work so far stays"
      when "removed" then "the queued message was removed before it ran; no turn ran for it"
      when "exhausted"
        ran_out = "the turn ran out of iterations#{" (#{result.limit} steps)" if result.limit} before it answered"
        strategy = policy(strategy)
        if strategy.allow?(Guardrails::ParentPolicy::SPEND)
          "#{ran_out}; #{via.command("send #{session_id} -m '/continue yes'")} continues it, a message drops it"
        else
          # No /continue yes hint: a parent may not continue it here.
          "#{ran_out}; continuing it is up to your user (#{strategy.label}), a message drops it"
        end
      else "the turn ended without a reply (canceled, failed or empty)"
      end
    end

    # A file-delivered session command's outcome: no turn ran for it.
    def command_line(result)
      case result.outcome
      when "completed" then "the command ran (no turn)"
      when "failed" then "the command failed"
      else "the command was refused (#{result.cancel_reason || "canceled"})"
      end
    end

    # A failed turn's line; one whose work stayed says so, so the task isn't
    # sent again over what it changed.
    def failed_line(result)
      why = result.text.to_s.strip
      steps = result.kept_steps
      return why.empty? ? "the turn failed" : "the turn failed: #{why}" unless steps.is_a?(Integer)

      "the turn failed after #{steps} tool step#{"s" if steps != 1}#{": #{why}" unless why.empty?}; its work so far stays"
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
