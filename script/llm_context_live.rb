#!/usr/bin/env ruby
# frozen_string_literal: true

# The llm_context live runs (context strategies P6): real merged fixes
# replayed from their parent commits by chi itself, under each LLM context
# strategy, graded by the fix's held-back specs and scored on re-reads,
# scope and tokens.
#
#   ruby script/llm_context_live.rb validate TASKS ROOT
#   ruby script/llm_context_live.rb run TASKS ROOT --model openrouter:… [--samples 3] [--cap 8]
#   ruby script/llm_context_live.rb report ROOT
#
# TASKS and ROOT live outside the repo (plan D4: no session text in it).
# Calls a paid model: opt-in, no spec runs it. See
# docs/internals/llm-context-live.md.

require_relative "llm_context_live/cli"

exit LLMContextLive::CLI.new(ARGV).run
