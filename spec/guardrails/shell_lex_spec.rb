# frozen_string_literal: true

require "samagotchi/guardrails/shell_lex"

# The guardrails' shell lexer: words and operators, never anything run.
RSpec.describe Samagotchi::Guardrails::ShellLex do
  def commands(text) = described_class.simple_commands(described_class.lex(text))

  subst = described_class::SUBST

  table = {
    "ls -la ~/x" => [%w[ls -la ~/x]],
    "a && b || c; d | e" => [%w[a], %w[b], %w[c], %w[d], %w[e]],
    "echo 'a && b' \"c; d\"" => [["echo", "a && b", "c; d"]],
    "cat a\\ b # comment && rm x" => [["cat", "a b"]],
    "git push 2>&1 >> log" => [%w[git push 2>&1 >> log]],
    "(cd x && make)" => [:open, %w[cd x], %w[make], :close],
    "echo $(rm -rf /) `id`" => [["echo", subst, subst]],
    "a\nb" => [%w[a], %w[b]],
    "" => []
  }.freeze

  table.each do |text, expected|
    it "#{text.inspect} -> #{expected.inspect}" do
      expect(commands(text)).to eq(expected)
    end
  end
end
