# frozen_string_literal: true

require_relative "log"
require_relative "session"
require_relative "side_judgments"
require_relative "system_one/runs"

module Samagotchi
  # The candidates' record, `context_candidates.jsonl` in the state dir
  # (beside the sessions folder; SideJudgments.log: 0600, one line under a
  # lock, the oldest half dropped past 5 MB): what happened to each
  # session's candidates, for `chi context report` (ContextReportCommand).
  # Local only: nothing here leaves the machine, so it is written in every
  # context.candidates.mode, off too.
  #
  # Kinds (every line has session_id, name and at):
  # - proposed: a plugin's ctx.context.propose recorded it (title, by)
  # - mentioned: an owner prompt named it and it was attached (mention)
  # - judged: System 1's ask (ContextJudge.ask: run_id, p, task_p, stated,
  #   would, …)
  # - judge_attached: on mode attached it (p ≥ threshold; p)
  # - carded: on mode showed its card (the middle band; p): once per
  #   candidate, read back by ContextCandidateChoice.carded?
  # - attached / declined with by "command": /context attach|decline NAME
  #   (the card's buttons)
  # - attached / declined / detached with by "user": the derived status
  #   changed since the last line said otherwise, seen at an owner turn's
  #   start (#look): the user's own doing (chi context add, chi web's chip
  #   ×, chi context rm; a removed source is declined)
  # - withdrawn: the plugin took the candidate back
  module ContextCandidatesLog
    FILE = "context_candidates.jsonl"
    # What a logged prompt keeps of its text.
    PROMPT_MAX = 200
    # The status each kind leaves a candidate in (#statuses).
    STATUS_OF = { "proposed" => "proposed", "mentioned" => "attached", "judge_attached" => "attached", "attached" => "attached",
                  "declined" => "declined", "detached" => "proposed", "withdrawn" => nil }.freeze

    # The kinds #look sees that are a removal: a chip's ×, chi context rm. One
    # removed after the session's last turn is never seen.
    REMOVED = %w[declined detached].freeze

    module_function

    # @param state_dir [String, nil] the sessions folder (Session.default_state_dir)
    def path(state_dir = nil) = File.join(File.dirname(state_dir || Session.default_state_dir), FILE)

    # @return [SystemOne::Log]
    def log_for(state_dir = nil) = SideJudgments.log(path(state_dir), tag: :context, event: "context_candidates_log_failed")

    # One line; never raises.
    # @return [Boolean] whether it was written
    def event(kind, session_id:, name:, state_dir: nil, log: nil, **fields)
      (log || log_for(state_dir)).entry(kind, { "session_id" => session_id.to_s, "name" => name.to_s }.merge(fields.compact))
    rescue StandardError => e
      Log.warn(:context, "context_candidates_log_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      false
    end

    # +session_id+'s lines, oldest first.
    def records_for(log, session_id) = log.records.select { |line| line["session_id"] == session_id.to_s }

    # Explicit `chi sessions delete`: everything the session left in the log
    # goes with it, including the `judged` lines that keep 200 characters of
    # its prompts. Never raises.
    # @return [Integer] how many lines were dropped
    def purge_session(session_id, state_dir: nil)
      log_for(state_dir).prune { |line| line["session_id"] != session_id.to_s }
    rescue StandardError => e
      Log.warn(:context, "context_candidates_log_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      0
    end

    # The status the lines last left each candidate in, by name (a
    # withdrawn one is gone).
    # @return [Hash{String => String}]
    def statuses(records)
      records.each_with_object({}) do |line, known|
        next unless STATUS_OF.key?(line["kind"])

        status = STATUS_OF[line["kind"]]
        status ? known[line["name"]] = status : known.delete(line["name"])
      end
    end

    # The derived statuses now (+rows+: ContextCandidates.with_status)
    # against the last ones logged: each change is a line (attached,
    # declined, detached). A candidate never logged counts as proposed.
    # @return [Array<String>] the kinds written
    def look(log, session_id, rows, records)
      known = statuses(records)
      rows.filter_map do |candidate, status|
        next if status == (known[candidate.name] || "proposed")

        kind = status == "proposed" ? "detached" : status
        event(kind, session_id: session_id, name: candidate.name, log: log, by: "user")
        label_run(records, candidate.name, kind, by: "user", root: log.dir) if REMOVED.include?(kind)
        kind
      end
    end

    # The user's say on a candidate, as a label on the latest ask about it
    # (the judged line's run, question "about"). No ask with a run: nothing.
    # Never raises.
    # @param records [Array<Hash>] the session's lines (#records_for)
    # @param root [String, nil] the state dir; nil: from +sessions_dir+
    # @return [Boolean] whether a label was written
    def label_run(records, name, value, by:, sessions_dir: nil, root: nil)
      judged = records.reverse_each.find { |line| line["kind"] == "judged" && line["name"] == name && line["run_id"] }
      return false if judged.nil?

      runs = SystemOne::Runs.in(root || File.dirname(sessions_dir || Session.default_state_dir))
      runs.label(judged["run_id"], value, by: by, question: "about")
    rescue StandardError => e
      Log.warn(:context, "context_candidates_log_failed", error: e.class.name, msg: e.message.to_s[0, 200])
      false
    end

    # +text+ as a log line keeps it: one line, at most PROMPT_MAX chars.
    def short(text)
      line = text.to_s.gsub(/\s+/, " ").strip
      line.length > PROMPT_MAX ? "#{line[0, PROMPT_MAX - 1]}…" : line
    end
  end
end
