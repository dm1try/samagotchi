# frozen_string_literal: true

require "json"
require_relative "../llm_context_bench/replay"
require_relative "../model_notes_report/session_stats"

module LLMContextLive
  # A finished run's numbers, from its session file, analytics.json and the
  # repo's diff against the base commit. Nothing of the session's text.
  #
  # - steps, tool_calls, edits, commits: SessionReader's.
  # - reads, re_reads, re_reads_after_stub (_forget, _stale): Replay#read_counts.
  # - stale_stubs, forget_calls, forget_ids, forget_freed (tokens, chars/4):
  #   Replay#stubs.
  # - prompt_tokens (sent, summed over requests), cached_tokens,
  #   reprefill_tokens, completion_tokens, cost: the turn records' sums.
  # - peak_context: the largest prompt of any turn (prompt_tokens_max; the
  #   last turn-end prompt for a record saved before it).
  # - files_read (distinct paths read), files_read_outside and
  #   files_changed_outside (not in the fix's set), diff_lines (added +
  #   removed against the base commit, untracked files included).
  class Collector
    def initialize(shell:)
      @shell = shell
    end

    # @return [Hash] metric => number; {} when the session file is missing
    def collect(task, workspace, session_id)
      path = File.join(workspace.sessions_dir, "#{session_id}.json")
      return {} unless session_id && File.file?(path)

      replay = LLMContextBench::Replay.load(path)
      stats = ModelNotesReport::SessionReader.read(path)
      records = ModelNotesReport::SessionReader.turn_records(File.join(workspace.sessions_dir, session_id, "analytics.json")) || []
      { steps: stats.steps, tool_calls: stats.calls, edits: stats.edits, commits: stats.commits,
        **reads(replay), **stubs(replay), **tokens(records), **scope(task, workspace, replay) }
    end

    private

    def reads(replay)
      counts = replay.read_counts
      { reads: counts.reads, re_reads: counts.re_reads, re_reads_after_stub: counts.after_stub,
        re_reads_after_forget: counts.after_forget, re_reads_after_stale: counts.after_stale }
    end

    def stubs(replay)
      stubs = replay.stubs
      { stale_stubs: stubs.stale, stale_freed: stubs.stale_tokens, forget_calls: stubs.forget_calls,
        forget_ids: stubs.forget, forget_freed: stubs.forget_tokens }
    end

    def tokens(records)
      sum = ->(key) { records.sum { |record| record[key].to_i } }
      peak = records.map { |record| (record["prompt_tokens_max"] || record["prompt_tokens"]).to_i }.max
      { prompt_tokens: sum.call("prompt_tokens_sum"), cached_tokens: sum.call("cached_tokens_sum"),
        reprefill_tokens: sum.call("reprefill_tokens_sum"), completion_tokens: sum.call("completion_tokens"),
        cost: records.sum { |record| record["cost"].to_f }.round(4), peak_context: peak.to_i }
    end

    def scope(task, workspace, replay)
      read = replay.outputs.select(&:read?).flat_map { |output| output.target.keys }.uniq
      changed = numstat(workspace.repo)
      { files_read: read.size, files_read_outside: (read - task.fix_files).size,
        files_changed: changed.size, files_changed_outside: (changed.keys - task.fix_files).size,
        diff_lines: changed.values.sum }
    end

    # Changed paths => lines added + removed, against the base commit
    # (the first one), untracked files included (intent-to-add).
    def numstat(repo)
      base = @shell.run(["git", "-C", repo, "rev-list", "--max-parents=0", "HEAD"]).out.split.first
      return {} unless base

      @shell.run(["git", "-C", repo, "add", "-A", "-N"])
      @shell.run(["git", "-C", repo, "diff", "--numstat", base]).out.lines.to_h do |line|
        added, removed, file = line.chomp.split("\t", 3)
        [file, added.to_i + removed.to_i]
      end
    end
  end
end
