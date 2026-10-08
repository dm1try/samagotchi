#!/usr/bin/env ruby
# frozen_string_literal: true

# The model notes report: reads stored chi sessions and groups them by model
# and by the model notes their system prompt carried (the session file's
# prompt_notes), with the numbers a model note is meant to move: tool calls
# to the first edit and the first commit, commits per 100 steps, bare `&` in
# execute, the longest run of calls with no edit, and the Continues and
# steers a session needed (--help defines each).
#
#   ruby script/model_notes_report.rb [--sessions DIR] [--model GLOB] [--since DATE] [--min-steps N] [--json]
#
# DIR holds <session id>.json files (and each session's <id>/analytics.json);
# chi's own sessions folder by default. Opt-in: it only reads, prints no
# session text (ids, model names, note names and digests, dates, numbers),
# and no spec runs it on real sessions. See docs/testing.md.

require_relative "model_notes_report/cli"

exit ModelNotesReport::CLI.new(ARGV).run
