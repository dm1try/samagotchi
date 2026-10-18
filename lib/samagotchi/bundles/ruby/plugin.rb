# frozen_string_literal: true

# The ruby bundle (docs/plugins.md, The ruby bundle): an `execute` that ran
# RSpec and got no examples at all steers a hint into the running turn.
#
# RSpec prints `0 examples, 0 failures` for a run whose path matched no
# file, whose filter (-e, --tag) matched no example, or whose .rspec
# --pattern hid the specs (a nested project's .rspec overrides one). The
# summary reads green, so the model takes the suite as passing and moves on
# with code no test ever loaded. after_tool_call checks the run: the command
# runs rspec, and every summary line in its output counted 0 examples.
#
# The command: one of its simple commands (split at &&, ||, ;, | and a
# newline, so after a leading `cd x &&` too) starts with `rspec`,
# `bin/rspec` (any path ending in /rspec) or `parallel_rspec`, once leading
# X=… assignments, `bundle exec` and `time` are left out. A program that
# only names rspec (`grep rspec README`, `echo "bundle exec rspec"`) is not
# a run. Only `execute` results count.
#
# The output: every `<N> examples, <M> failures` line (RSpec's summary,
# `0 examples, 0 failures` or `, 3 pending` after it) counts, and the hint
# comes when all of them are 0: parallel_rspec prints one per process, so a
# single process with examples leaves its 0 out of the total. An output with
# no summary line (a spec that fails to load, a missing path, a killed run)
# says what is wrong already: the hint doesn't repeat it.
#
# The hint is a steer: its own user message in the conversation at the
# loop's next boundary, shown as `ruby> nudged: …`, dropped (logged) if the
# model answers first. Nothing is remembered, so the next 0-example run
# hints again: a different command, and it may be the same mistake.
class Plugin
  HINT = "rspec ran 0 examples: check the path, the filter (-e/--tag) or the .rspec --pattern"
  PROGRAMS = %w[rspec parallel_rspec].freeze
  SUMMARY = /\b(\d+) examples?, (\d+) failures?\b/
  # Where a simple command ends: the next one runs its own program.
  SEGMENTS = /&&|\|\||[;|\n]/
  ASSIGNMENT = /\A[A-Za-z_][A-Za-z0-9_]*=/

  def register(chi)
    chi.on(:after_tool_call) { |event, ctx| after(event, ctx) }
  end

  def after(event, ctx)
    return unless event[:tool].to_s == "execute"
    return unless self.class.zero_examples?(event[:result])

    call = event[:call]
    return unless call.is_a?(Hash) && self.class.rspec?(call[:content])

    ctx.steer(HINT)
  end

  # Whether one of +command+'s simple commands runs rspec.
  def self.rspec?(command)
    command.to_s.split(SEGMENTS).any? { |segment| PROGRAMS.include?(File.basename(program(segment))) }
  end

  # The program a simple command starts: leading X=… assignments, `bundle
  # exec` and `time` left out ("" for none).
  def self.program(segment)
    words = segment.split(/\s+/).reject(&:empty?)
    words.shift while words.first&.match?(ASSIGNMENT)
    words.shift(2) if words[0] == "bundle" && words[1] == "exec"
    words.shift if words.first == "time"
    words.first.to_s
  end

  # Whether the output has summary lines and every one of them counts 0
  # examples.
  def self.zero_examples?(output)
    counts = output.to_s.scan(SUMMARY).map { |examples, _failures| examples.to_i }
    !counts.empty? && counts.all?(&:zero?)
  end
end
