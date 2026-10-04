# frozen_string_literal: true

require_relative "session"
require_relative "session_manager"
require_relative "bridge_client"
require_relative "reply_wait"
require_relative "parent_report"
require_relative "guardrails/parent_approvals"
require_relative "guardrails/parent_continue"
require_relative "cli/command"
require_relative "cli/flags"
require_relative "cli/parent_wait"

module Samagotchi
  # `chi answer`: answer the question a session's worker waits on (exit 3
  # from chi send --wait), then wait for what comes next and print it the
  # same way: the reply (0), the next question (3), still running (4). It is
  # how a parent agent running chi as a sub-agent answers; the web and
  # chi --attach answer the same question. See docs/sub-agent.md.
  #
  # An approval is the user's to allow: a parent may deny it, and allow it
  # only "once" when guardrails.parent_approvals (config.yml) says so. It is
  # checked here and again by the worker, which sees the answer marked as
  # chi answer's. That guards an honest but eager parent, not a boundary:
  # the Bridge and the localhost web take answers from any local process.
  class AnswerCommand
    include CLI::Command
    include CLI::ParentWait

    USAGE = <<~TEXT
      Usage: chi answer ID --question QID (--option N|LABEL)... [--text T] [--timeout S] [--format json]
             chi answer ID --question QID --dismiss [--timeout S] [--format json]
        Answers the question session ID waits on (chi send --wait exits 3
        with it), then waits for what comes next and prints it as chi send
        --wait does.
        --question QID  the question's id (chi send --wait prints it); a
                        question no longer open is not answered (the JSON
                        says "answered_here": false)
        --option N|LABEL
                        an option, by number (1-based) or label; repeat
                        on a multi-select question
        --text T        free text, where the question allows it; with an
                        approval, the reason for a Deny (text alone denies)
        --dismiss       leave it unanswered: chi does nothing it asked
                        about and finishes its reply
        --timeout S     give up waiting after S seconds (exit 4)
        --format json   one JSON object on stdout (see chi send --help)
        An approval (a guardrail's ask) can be denied here: deny it, and
        tell your user; allowing it is the user's. With
        guardrails.parent_approvals: once, "Allow once" is let through.
        A step-limit question (kind continue): --option Continue [--text
        STEER] (the text joins the continued turn as a steer), or
        --option Stop [--text WHY] (exit 0, status not_continued); it
        can't be dismissed.
        Exit: 0 answered, 1 failed, refused or the worker is gone, 2
        usage or an option the question doesn't offer, 3 a question waits,
        4 still running (--timeout), 130 Ctrl-C.
    TEXT

    FLAGS = CLI::Flags.new(help: CLI::Command::HELP_WORDS) do |f|
      f.value "--question"
      f.value "--option", key: :options, repeat: true
      f.value "--text"
      f.switch "--dismiss"
      f.value "--timeout"
      f.value "--format"
    end

    def initialize(argv, stdout: $stdout, stderr: $stderr, state_dir: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
    end

    private

    def command_name = "chi answer"

    def parse
      parsed = parse_flags(FLAGS, @argv, options: [])
      return parsed if parsed.is_a?(Integer)

      options = parsed.options
      return usage_error("give one session id") unless parsed.args.size == 1
      return usage_error("--question QID is required (chi send --wait prints it)") if options[:question].to_s.strip.empty?

      if options[:dismiss]
        return usage_error("--dismiss takes no --option or --text") if !options[:options].empty? || options[:text]
      elsif options[:options].empty? && options[:text].nil?
        return usage_error("nothing to answer with: --option, --text or --dismiss")
      end
      return usage_error("--format takes text or json") if options[:format] && !FORMATS.include?(options[:format])

      if options[:timeout]
        options[:timeout] = Float(options[:timeout], exception: false)
        return usage_error("--timeout takes seconds") unless options[:timeout]&.positive?
      end
      options.merge(id: parsed.args.first)
    end

    # Answer, then wait for what comes next.
    # @return [Integer] the exit status
    def run_parsed(options)
      id = resolve(options[:id]) or return 1
      qid = options[:question].strip
      session = Session.load(id, state_dir: @state_dir)
      pending = session.pending_question
      # Taken before the answer goes in, with the question answered as the
      # one already reported: the file keeps it until the turn thread
      # wakes, and it must not come back as exit 3.
      cursor = ReplyWait.newest_reply(id, state_dir: @state_dir)
      baseline = ReplyWait.baseline_of(session, question_id: qid)

      if pending && pending[:id].to_s == qid
        return failure(not_dismissable(pending)) if options[:dismiss] && ParentReport.continue?(pending)

        selected = selection(pending, options) or return @selection_status
        refusal = approval_refusal(pending, selected, id) || continue_refusal(pending, selected)
        return failure(refusal) if refusal

        posted = post(id, qid, selected, options)
        return posted if posted.is_a?(Integer)
      elsif session.status != Session::STATUS_RUNNING
        return failure("no question #{qid} waits in #{id[0, 8]}; nothing to answer")
      else
        not_open(qid)
      end
      # Answered here, or no longer open (answered elsewhere, or a newer
      # question): what comes next either way.
      wait_for_reply(id, cursor: cursor, baseline: baseline, timeout: options[:timeout])
    end

    # The labels to send. A number is an option's place (1-based); an
    # exact label wins over a number.
    # @return [Array<String>, nil] nil after a usage error
    def selection(pending, options)
      offered = Array(pending[:options]).map(&:to_s)
      labels = options[:options].map do |given|
        next given if offered.include?(given)

        index = Integer(given, exception: false)
        next offered[index - 1] if index&.between?(1, offered.size)

        listed = offered.each_with_index.map { |label, i| "#{i + 1}. #{label}" }.join(", ")
        @selection_status = usage_failure("no option #{given}; the options: #{listed}")
        return nil
      end
      if labels.uniq.size > 1 && !pending[:multi_select]
        @selection_status = usage_failure("one option only: the question is single-select")
        return nil
      end
      labels.uniq
    end

    # Why a parent may not give this answer to an approval, or nil
    # (Guardrails::ParentApprovals, with this process's config.yml). A
    # Deny, text alone or a dismissal always passes: each one denies. The
    # worker checks it again with its own config.
    def approval_refusal(pending, selected, id)
      offered = Array(pending[:options]).map(&:to_s)
      indices = selected.map { |label| offered.index(label) }
      reason = Guardrails::ParentApprovals.refusal(pending, indices, setting: Guardrails::ParentApprovals.setting)
      reason && Guardrails::ParentApprovals.message(reason)
    end

    # Why a parent may not answer Continue (turn.parent_continue: false in
    # this process's config.yml), or nil; the worker checks it again.
    def continue_refusal(pending, selected)
      Guardrails::ParentContinue.refusal(pending, selected) && Guardrails::ParentContinue.message
    end

    # A step-limit question can't be left unanswered: the turn waits on it.
    def not_dismissable(pending)
      "the step-limit question can't be dismissed: answer #{Array(pending[:options]).join(' or ')} " \
        "(--option Stop --text WHY stops it)"
    end

    # Post the answer (or the dismissal) to the live worker's Bridge.
    # @return [Integer, nil] an exit status when it didn't go in; nil to
    #   wait (it went in, or the question was no longer open: 409)
    def post(id, qid, selected, options)
      client = BridgeClient.discover(id, session_dir: Session.session_dir(id, state_dir: @state_dir))
      return failure(worker_gone(id)) unless client

      reply = nil
      2.times do
        reply = if options[:dismiss]
                  client.dismiss_question(id: qid)
                else
                  client.answer(id: qid, selected: selected, freeform: options[:text],
                                client_id: Guardrails::ParentApprovals::CLIENT_ID)
                end
        break unless reply.status == 408
      end

      case reply.status
      when 200 then nil
      when 409
        return failure(reply.json&.dig("detail").to_s) if reply.json&.dig("error") == "not_dismissable"

        not_open(qid)
      when 400 then usage_failure(reply.json&.dig("detail") || "the worker refused the answer")
      # The worker's own guardrails.parent_approvals refused the allow.
      when 403 then failure(reply.json&.dig("detail") || "the worker refused the allow: deny it, and tell your user")
      when 408 then failure("the worker did not take the answer in time; the question is still open: try again")
      when 404
        return failure(worker_gone(id)) if reply.json&.dig("error") == "unknown_session"

        cant = options[:dismiss] ? "dismiss a question" : "take an answer"
        failure(BridgeClient.stale_worker_message(id, cant: cant))
      else failure("the worker answered #{reply.status}: #{reply.json&.dig("detail") || reply.body}")
      end
    rescue Errno::ETIMEDOUT
      failure("the worker did not take the answer in time; the question is still open: try again")
    rescue SystemCallError, IOError, SocketError
      failure(worker_gone(id))
    end

    # The question was answered elsewhere (the web first), or another one
    # waits now: said, then what comes next is waited for (the JSON says
    # answered_here: false).
    # @return [nil]
    def not_open(qid)
      @answered_here = false
      error_line("#{command_name}: question #{qid} is no longer open; not answered here, waiting for what comes next")
      nil
    end

    def worker_gone(id)
      "the worker is gone and the question with it; send the task again: chi send --wait -m \"…\" #{id}"
    end

    # @return [Integer] 1, after the line
    def failure(line)
      error_line("#{command_name}: #{line}")
      1
    end

    # The Bridge refused the answer itself (an option not offered, two on a
    # single-select question): a usage error, the question still open.
    def usage_failure(line)
      error_line("#{command_name}: #{line}")
      CLI::Exit::USAGE
    end
  end
end
