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

    it "keeps a body fed to anything but cat or tee as one script word" do
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

    it "keeps $(cat <<'EOF' … EOF) one opaque word" do
      text = "git commit -m \"$(cat <<'EOF'\nit's\nEOF\n)\" && git push"
      expect(commands(text)).to eq([["git", "commit", "-m", subst], %w[git push]])
    end
  end
end
