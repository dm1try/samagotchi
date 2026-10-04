# frozen_string_literal: true

require "json"
require "samagotchi/guardrails/shell_lex"

# ShellLex.lex_with_spans: lex's tokens with where each was read from, for
# a display (CommandSteps). Additive: lex itself must not change.
RSpec.describe Samagotchi::Guardrails::ShellLex, ".lex_with_spans" do
  fixtures = File.expand_path("../fixtures/command_steps", __dir__)
  corpus = JSON.parse(File.read(File.join(fixtures, "corpus.json")))
  # lex / simple_commands over the corpus, recorded before spans were added.
  golden = JSON.parse(File.read(File.join(fixtures, "corpus_lex.json")))

  def slices(text)
    described_class.lex_with_spans(text).map { |*token, span| [token[0], token[1], text[span]] }
  end

  it "leaves lex and simple_commands as they were on the corpus" do
    corpus.each_with_index do |text, i|
      tokens = described_class.lex(text)
      expect(JSON.parse(JSON.generate(tokens))).to eq(golden[i]["lex"]), text
      expect(JSON.parse(JSON.generate(described_class.simple_commands(tokens)))).to eq(golden[i]["simple_commands"]), text
    end
  end

  it "gives lex's tokens, each with a range inside the text" do
    corpus.each do |text|
      with_spans = described_class.lex_with_spans(text)
      expect(with_spans.map { |token| token[0..-2] }).to eq(described_class.lex(text))
      expect(with_spans.map(&:last)).to all(satisfy { |r| r.is_a?(Range) && r.end <= text.size && r.begin <= r.end })
    end
  end

  it "spans words as written, quotes and substitutions included, and operators" do
    expect(slices(%(cd "a b" && echo 'x'y $(ls) | head -2))).to eq(
      [[:word, "cd", "cd"], [:word, "a b", '"a b"'], [:op, "&&", "&&"], [:word, "echo", "echo"],
       [:word, "xy", "'x'y"], [:word, described_class::SUBST, "$(ls)"], [:op, "|", "|"],
       [:word, "head", "head"], [:word, "-2", "-2"]]
    )
  end

  it "spans a heredoc body with its terminator line" do
    text = "cat <<EOF > f\nhi\nEOF\nls"
    expect(slices(text)).to eq(
      [[:word, "cat", "cat"], [:word, "<<EOF", "<<EOF"], [:word, described_class::HEREDOC, "hi\nEOF"],
       [:word, ">", ">"], [:word, "f", "f"], [:op, "\n", "\n"], [:word, "ls", "ls"]]
    )
    expect(slices("cat <<A <<B\na\nA\nb\nB").map(&:last)).to eq(["cat", "<<A", "a\nA", "<<B", "b\nB", "\n"])
  end

  it "keeps a span inside the text for an unbalanced quote" do
    expect(slices("echo 'abc")).to eq([[:word, "echo", "echo"], [:word, "abc", "'abc"]])
    expect(slices('echo "abc')).to eq([[:word, "echo", "echo"], [:word, "abc", '"abc']])
  end

  describe "Lexer#unterminated? and #heredoc_spans" do
    def lexer(text) = described_class::Lexer.new(text).tap(&:tokens)

    it "notes a quote, substitution or heredoc left open" do
      ["echo 'a", 'echo "a', "echo `a", "echo $(a", "cat <<EOF\nx", "cat <<EOF", 'echo $(echo ")")'].each do |text|
        expect(lexer(text)).to be_unterminated, text
      end
      ["a && b", "echo $((1<<3))", "echo '<<EOF'", "cat <<EOF\nx\nEOF"].each do |text|
        expect(lexer(text)).not_to be_unterminated, text
      end
    end

    it "lists the heredocs read, in order" do
      expect(lexer("cat <<A <<'B'\na\nA\nb\nB\nls").heredoc_spans).to eq([{ tag: "A", span: 14...17 },
                                                                          { tag: "B", span: 18...21 }])
      expect(lexer("echo '<<EOF'").heredoc_spans).to eq([])
    end
  end
end
