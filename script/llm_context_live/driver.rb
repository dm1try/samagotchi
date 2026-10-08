# frozen_string_literal: true

require "json"

module LLMContextLive
  # Drives one run's session through chi send, the way a parent agent
  # would: --new with the first turn, then each later turn into the same
  # session, waiting for each (--wait --format json).
  #
  # What it answers: the model's own first question with "use your
  # judgement" (option 1 when it takes no text), later ones dismissed; an
  # approval denied; the step-limit question with Stop (no Continue: the
  # step limit is part of the task). A payment error (a 402: credits,
  # credits_held, over_budget) ends the run at once and is reported, so the
  # caller stops the whole matrix.
  class Driver
    ANSWER = "use your judgement"
    TURN_TIMEOUT = 2700
    PAYMENT_KINDS = %w[credits credits_held].freeze
    PAYMENT_RE = /\b402\b|over_budget|insufficient credits|credits/i
    # How a turn ended: chi send's status, seconds, questions answered,
    # whether it hit the step limit, and the detail of an unusual end.
    Turn = Data.define(:status, :seconds, :answered, :limit, :detail)
    Outcome = Data.define(:session_id, :turns, :payment, :timed_out, :wall_seconds, :error) do
      def to_h = super.merge(turns: turns.map(&:to_h))
    end

    def initialize(chi:, shell:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, log: $stderr)
      @chi = chi
      @shell = shell
      @clock = clock
      @log = log
    end

    # @param flags [Array<String>] chi send --new's strategy and budget flags
    # @return [Outcome]
    def run(task, workspace, model:, flags:)
      started = @clock.call
      @workspace = workspace
      @session = nil
      @questions = 0
      turns = []
      task.turns.each_index do |index|
        text = task.turn_text(index, repo: workspace.repo)
        argv = index.zero? ? ["--new", "--dir", workspace.repo, "--model", model, *flags] : [@session]
        turn = turn(argv, text)
        turns << turn
        break if turn.status == "payment" || stop?(turn)
      end
      outcome(turns, started)
    rescue Error => e
      Outcome.new(session_id: @session, turns: turns || [], payment: false, timed_out: false,
                  wall_seconds: (@clock.call - started).round, error: e.message)
    ensure
      stop_session
    end

    private

    # A turn that leaves nothing to send the next one into.
    def stop?(turn) = %w[error worker_gone stopped running].include?(turn.status)

    def outcome(turns, started)
      Outcome.new(session_id: @session, turns: turns, payment: turns.any? { |turn| turn.status == "payment" },
                  timed_out: turns.any? { |turn| turn.status == "running" }, wall_seconds: (@clock.call - started).round,
                  error: nil)
    end

    def turn(argv, text)
      started = @clock.call
      answered = 0
      limit = false
      report = chi("send", *argv, "--wait", "--format", "json", "--timeout", TURN_TIMEOUT.to_s, "-m", text)
      @session ||= report["session_id"]
      while report["status"] == "question"
        question = report["question"] || {}
        limit ||= question["kind"] == "continue"
        answered += 1
        report = answer(question, remaining(started))
      end
      status = payment?(report) ? "payment" : report["status"].to_s
      status = "limit" if limit && status == "not_continued"
      Turn.new(status: status, seconds: (@clock.call - started).round, answered: answered, limit: limit || status == "limit",
               detail: report["status"] == "answered" ? nil : report["detail"] || report["error_kind"])
    end

    def remaining(started) = [TURN_TIMEOUT - (@clock.call - started), 60].max.round

    def answer(question, timeout)
      words = case question["kind"]
              when "continue" then ["--option", "Stop", "--text", "the step limit is part of this task"]
              when "approval" then ["--option", "Deny", "--text", "not in this run; #{ANSWER}"]
              when "hook" then ["--dismiss"]
              else model_question(question)
              end
      chi("answer", @session, "--question", question["id"].to_s, *words, "--format", "json", "--timeout", timeout.to_s)
    end

    def model_question(question)
      @questions += 1
      return ["--dismiss"] if @questions > 1
      return ["--text", ANSWER] if question["allow_freeform"]

      ["--option", "1"]
    end

    def payment?(report)
      PAYMENT_KINDS.include?(report["error_kind"].to_s) ||
        (report["status"] != "answered" && report["detail"].to_s.match?(PAYMENT_RE))
    end

    # One chi command's JSON object (its last stdout line).
    def chi(*args)
      ran = @shell.run([@chi, *args], env: @workspace.env, chdir: @workspace.dir, timeout: TURN_TIMEOUT + 120, stdin: "")
      line = ran.out.lines.reverse.find { |text| text.start_with?("{") }
      raise Error, "chi #{args.first}: no JSON (exit #{ran.status.inspect}): #{ran.err.strip[-300..] || ran.err.strip}" unless line

      JSON.parse(line)
    end

    # Stops the session's worker through chi, then anything still running
    # from this run's own state dir (never a pid read from a file).
    def stop_session
      return unless @workspace

      @shell.run([@chi, "sessions", "stop", @session], env: @workspace.env, chdir: @workspace.dir, timeout: 60, stdin: "") if @session
      @shell.run(["pkill", "-f", @workspace.state_home], timeout: 30)
    end
  end
end
