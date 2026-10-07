#!/usr/bin/env ruby
# frozen_string_literal: true

# The llm_context replay benchmark: replays stored chi sessions offline and
# reports what each context strategy would have changed (freed tokens,
# wrongly forgotten outputs, one-step re-reads, re-prefilled tokens).
#
#   ruby script/llm_context_bench.rb [SESSIONS_DIR] [options]   # --help lists them
#
# SESSIONS_DIR (or $LLM_CONTEXT_BENCH_SESSIONS) holds <session id>.json
# files; chi's own sessions folder by default. Opt-in: no spec runs it on
# real sessions. See docs/internals/llm-context-bench.md.

require_relative "llm_context_bench/cli"

exit LLMContextBench::CLI.new(ARGV).run
