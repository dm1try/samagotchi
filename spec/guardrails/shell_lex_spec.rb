# frozen_string_literal: true

require "json"
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
  describe "substitutions" do
    it "ends at the ) that closes it, not at one inside a quoted string" do
      expect(commands('echo "$(echo ")" rm x)"')).to eq([["echo", subst]])
    end

    it "ends after a heredoc body inside it, not at a ) in that body" do
      expect(commands("x=$(cat <<'EOF'\na ) b\nEOF\n)")).to eq([["x=#{subst}"]])
      expect(commands("echo $(a (b) c)")).to eq([["echo", subst]])
    end
  end

  describe "heredocs" do
    heredoc = described_class::HEREDOC

    it "keeps an apostrophe in a body from hiding the command after it" do
      expect(commands("cat <<EOF\nit's\nEOF\ngit push origin main"))
        .to eq([["cat", "<<EOF", heredoc], %w[git push origin main]])
    end

    it "sees a heredoc body as data past a redirection written with a space" do
      ["> /tmp/x cat <<EOF\nrm -rf /\nEOF\n",
       "2> err cat <<EOF\nrm -rf /\nEOF\n",
       ">/tmp/x cat <<EOF\nrm -rf /\nEOF\n"].each do |text|
        words = described_class.lex(text).filter_map { |kind, value, _s| value if kind == :word }
        expect(words).to include("cat", heredoc)
      end
    end

    it "reads quoted and bare tags" do
      expect(commands("cat <<'EOF'\nrm -rf /\nEOF\nls")).to eq([["cat", "<<EOF", heredoc], %w[ls]])
      expect(commands("cat <<\"END\"\nrm -rf /\nEND\nls")).to eq([["cat", "<<END", heredoc], %w[ls]])
      expect(commands("cat << EOF\nrm -rf /\nEOF\nls")).to eq([["cat", "<<EOF", heredoc], %w[ls]])
      expect(commands("cat<<EOF\nx\nEOF")).to eq([["cat", "<<EOF", heredoc]])
    end

    it "strips leading tabs from the terminator for <<-" do
      expect(commands("cat <<-EOF\n\tit's\n\tEOF\nls")).to eq([["cat", "<<-EOF", heredoc], %w[ls]])
      expect(commands("cat <<EOF\nx\n\tEOF\nEOF\nls")).to eq([["cat", "<<EOF", heredoc], %w[ls]])
    end

    it "reads several heredocs on one line in order, each into its own command" do
      text = "cat <<A > /tmp/a; cat <<'B' > /tmp/b\nit's a\nA\nit's b\nB\ngit push"
      expect(commands(text)).to eq([["cat", "<<A", heredoc, ">", "/tmp/a"], ["cat", "<<B", heredoc, ">", "/tmp/b"],
                                    %w[git push]])
    end

    it "reads a heredoc a git or gh command takes its text from data" do
      expect(commands("git commit -F - <<'EOF'\nrm -rf /\nEOF\nls"))
        .to eq([["git", "commit", "-F", "-", "<<EOF", heredoc], %w[ls]])
      expect(commands("git commit <<'EOF' -F -\nx\nEOF")).to eq([["git", "commit", "<<EOF", heredoc, "-F", "-"]])
      expect(commands("gh pr create --body-file - <<'EOF'\nx\nEOF"))
        .to eq([["gh", "pr", "create", "--body-file", "-", "<<EOF", heredoc]])
    end

    it "keeps such a body a script when it is piped on, in a group, or holds a substitution" do
      expect(commands("git commit -F - <<'EOF' | tee log\nx\nEOF"))
        .to eq([["git", "commit", "-F", "-", "<<EOF", "x\n"], %w[tee log]])
      expect(commands("(git commit -F - <<'EOF'; true) | sh\nx\nEOF"))
        .to eq([:open, ["git", "commit", "-F", "-", "<<EOF", "x\n"], %w[true], :close, %w[sh]])
      expect(commands("git commit -F - <<EOF\n$(id)\nEOF")).to eq([["git", "commit", "-F", "-", "<<EOF", subst]])
    end

    it "keeps a body fed to anything but a data reader as one script word" do
      expect(commands("bash <<'EOF'\nrm -rf /\nEOF\nls")).to eq([["bash", "<<EOF", "rm -rf /\n"], %w[ls]])
      expect(commands("cat <<'EOF' | sh\nrm -rf /\nEOF")).to eq([["cat", "<<EOF", "rm -rf /\n"], %w[sh]])
    end

    it "makes an unquoted body with a substitution a SUBST" do
      expect(commands("cat <<EOF\n$(rm -rf /)\nEOF")).to eq([["cat", "<<EOF", subst]])
      expect(commands("cat <<'EOF'\n$(rm -rf /)\nEOF")).to eq([["cat", "<<EOF", heredoc]])
    end

    it "leaves a here-string alone" do
      expect(commands("cat <<<'it is' && ls")).to eq([["cat", "<<<it is"], %w[ls]])
      expect(commands("cat <<< x\nit's")).to eq([["cat", "<<<", "x"], ["its"]])
    end

    it "lexes the rest as commands when the terminator never comes" do
      expect(commands("cat > /tmp/x <<EOF\nrm -rf /\nls"))
        .to eq([["cat", ">", "/tmp/x", "<<EOF"], ["rm", "-rf", "/"], %w[ls]])
    end

    it "keeps a body whose command is piped on, backgrounded or output into a process substitution a script" do
      expect(commands("(cat <<'EOF') | bash\nx\nEOF")).to eq([:open, ["cat", "<<EOF", "x\n"], :close, %w[bash]])
      expect(commands("cat <<'EOF' > >(bash)\nx\nEOF")).to eq([["cat", "<<EOF", "x\n", ">", ">"], :open, %w[bash], :close])
      expect(commands("cat <<'EOF' &>r.sh; bash r.sh\nx\nEOF")).to eq([["cat", "<<EOF", "x\n"], [">r.sh"], %w[bash r.sh]])
      expect(commands("cat <<'EOF' &\nx\nEOF")).to eq([["cat", "<<EOF", "x\n"]])
    end

    it "keeps a body inside an open ( or { group a script, whatever follows its command" do
      expect(commands("{ true; cat <<'EOF'; } | bash\nx\nEOF"))
        .to eq([["{", "true"], ["cat", "<<EOF", "x\n"], %w[}], %w[bash]])
      expect(commands("(cat <<'EOF'; true) | bash\nx\nEOF"))
        .to eq([:open, ["cat", "<<EOF", "x\n"], %w[true], :close, %w[bash]])
      expect(commands("bash <(cat <<'EOF'\nx\nEOF\n)")).to eq([["bash", "<"], :open, ["cat", "<<EOF", "x\n"], :close])
      expect(commands("case a in a) (cat <<'EOF'; true) | bash;; esac\nx\nEOF"))
        .to eq([%w[case a in a], :close, :open, ["cat", "<<EOF", "x\n"], %w[true], :close, %w[bash], %w[esac]])
    end

    it "still reads a body as data after a plain separator or outside any group" do
      expect(commands("cat <<'EOF' && ls\nx\nEOF")).to eq([["cat", "<<EOF", heredoc], %w[ls]])
      expect(commands("cat <<'EOF' || ls\nx\nEOF")).to eq([["cat", "<<EOF", heredoc], %w[ls]])
      expect(commands("cat <<'EOF'; ls\nx\nEOF")).to eq([["cat", "<<EOF", heredoc], %w[ls]])
      expect(commands("f() { true; }; cat <<'EOF'\nx\nEOF")).to include(["cat", "<<EOF", heredoc])
    end

    it "keeps $(cat <<'EOF' … EOF) one opaque word" do
      text = "git commit -m \"$(cat <<'EOF'\nit's\nEOF\n)\" && git push"
      expect(commands(text)).to eq([["git", "commit", "-m", subst], %w[git push]])
    end
  end

  describe ".code_text" do
    # Whether +lines+ appear in +of+ in that order.
    def subsequence?(lines, of)
      rest = of.dup
      lines.all? do |line|
        at = rest.index(line)
        rest = rest[(at + 1)..] if at
        at
      end
    end

    it "cuts a stdout cat's body, keeping the <<TAG word and the terminator line" do
      expect(described_class.code_text("cat <<'EOF'\nrake release\nEOF\nls")).to eq("cat <<'EOF'\nEOF\nls")
      expect(described_class.code_text("cat <<-EOF\n\trake release\n\tEOF\nls")).to eq("cat <<-EOF\n\tEOF\nls")
      expect(described_class.code_text("cat <<A; cat <<'B'\na\nA\nb\nB\nls")).to eq("cat <<A; cat <<'B'\nA\nB\nls")
      expect(described_class.code_text("git commit -F - <<'EOF'\nx\nEOF")).to eq("git commit -F - <<'EOF'\nEOF")
    end

    it "leaves the text as it was for a body that may run or is not known to be data" do
      ["bash <<'EOF'\nrm -rf /\nEOF", "cat <<'EOF' | sh\nrm -rf /\nEOF", "cat <<EOF\n$(rm -rf /)\nEOF",
       "cat > f <<'EOF'\nx\nEOF", "cat <<'EOF' > f\nx\nEOF", "cat <<'EOF' &>f\nx\nEOF",
       "(cat <<'EOF') | bash\nx\nEOF", "cat <<EOF\nx",
       "echo '<<EOF'\nx\nEOF", "echo hi", ""].each do |text|
        expect(described_class.code_text(text)).to eq(text), text
      end
    end

    it "only removes lines, and changes nothing of a text without <<" do
      corpus = JSON.parse(File.read(File.expand_path("../fixtures/command_steps/corpus.json", __dir__)))
      corpus.each do |text|
        code = described_class.code_text(text)
        expect(subsequence?(code.lines, text.lines)).to be(true), text
        expect(code).to eq(text), text unless text.include?("<<")
      end
    end
  end

  describe ".unterminated?" do
    it "is true for an open quote, $( or heredoc" do
      ["echo 'a", "echo \"a", "echo $(date", "cat <<EOF\nx"].each do |text|
        expect(described_class.unterminated?(text)).to be(true), text
      end
    end

    it "is false for complete input" do
      ["echo 'a'", "echo $(date) && ls", "cat <<EOF\nx\nEOF\n", ""].each do |text|
        expect(described_class.unterminated?(text)).to be(false), text
      end
    end
  end
end
