# frozen_string_literal: true

require "spec_helper"
require "samagotchi/command_steps"

RSpec.describe Samagotchi::CommandSteps do
  def parse(text) = described_class.parse(text)&.to_h

  it "splits a chain at its operators, each step's text as written" do
    expect(parse(%(rg -n "a && b" lib; git log --oneline -3 || echo none | wc -l))).to eq(
      steps: [{ text: %(rg -n "a && b" lib) }, { text: "git log --oneline -3", op: ";" },
              { text: "echo none", op: "||" }, { text: "wc -l", op: "|" }]
    )
  end

  it "keeps a ( … ) subshell and a $(…) one step" do
    expect(parse("(cd x && make) && echo $(date; id)")).to eq(
      steps: [{ text: "(cd x && make)" }, { text: "echo $(date; id)", op: "&&" }]
    )
  end

  it "joins lines as steps, a blank line or a ; before a newline no extra step" do
    expect(parse("a;\n\nb\nc &\nd")).to eq(
      steps: [{ text: "a" }, { text: "b", op: ";" }, { text: "c", op: "\n" }, { text: "d", op: "&" }]
    )
  end

  describe "the leading cd" do
    it "becomes cd for && and ;" do
      expect(parse("cd /p/app && ls")).to eq(cd: "/p/app", steps: [{ text: "ls" }])
      expect(parse(%(cd "/p/my app"; ls))).to eq(cd: "/p/my app", steps: [{ text: "ls" }])
    end

    it "stays a step alone, later, before a pipe or as a substitution" do
      expect(parse("cd /p/app")).to eq(steps: [{ text: "cd /p/app" }])
      expect(parse("ls && cd x && ls")[:steps].map { |s| s[:text] }).to eq(["ls", "cd x", "ls"])
      expect(parse("cd x\nls")[:cd]).to be_nil
      expect(parse("cd $(git rev-parse --show-toplevel) && ls")[:cd]).to be_nil
    end
  end

  describe "limits" do
    {
      "| head -20" => "head 20", "| head -n 20" => "head 20", "| head -n20" => "head 20", "| tail -5" => "tail 5",
      "| tail -n +3" => "tail +3", "| head -c 60" => "head -c 60", "| head" => "head", "2>&1 | tail -3" => "tail 3"
    }.each do |tail, limit|
      it "#{tail.inspect} -> #{limit.inspect}" do
        expect(parse("rg x lib #{tail}")).to eq(steps: [{ text: "rg x lib#{" 2>&1" if tail.start_with?("2")}", limit: limit }])
      end
    end

    it "only the last in a pipeline, and not tail -f or a file" do
      expect(parse("a | head -50 | tail -10")).to eq(steps: [{ text: "a" }, { text: "head -50", op: "|", limit: "tail 10" }])
      expect(parse("a | head -5 | wc -l")[:steps].size).to eq(3)
      expect(parse("a | tail -f")[:steps].size).to eq(2)
      expect(parse("a | head -5 x.txt")[:steps].size).to eq(2)
      expect(parse("head -5 x.txt")).to eq(steps: [{ text: "head -5 x.txt" }])
    end

    it "per pipeline in a chain" do
      expect(parse("rg a | head -2; rg b | tail -3")).to eq(
        steps: [{ text: "rg a", limit: "head 2" }, { text: "rg b", op: ";", limit: "tail 3" }]
      )
    end
  end

  describe "labels" do
    it "a marker echo labels the next step, its op kept" do
      expect(parse(%(ls; echo "=== git ===" && git status && echo '--- diff ---' && git diff; echo "## tail" && tail x))).to eq(
        steps: [{ text: "ls" }, { text: "git status", op: ";", label: "git" },
                { text: "git diff", op: "&&", label: "diff" }, { text: "tail x", op: ";", label: "tail" }]
      )
      expect(parse(%(echo "===Gemfile===" && cat Gemfile))).to eq(steps: [{ text: "cat Gemfile", label: "Gemfile" }])
    end

    it "a bare marker or empty echo goes; other echoes and a trailing label stay" do
      expect(parse(%(a; echo ---; b && echo "" && c))).to eq(
        steps: [{ text: "a" }, { text: "b", op: ";" }, { text: "c", op: "&&" }]
      )
      expect(parse(%(a && echo "done: ok"))[:steps].size).to eq(2)
      expect(parse(%(a && echo "=== end ==="))).to eq(steps: [{ text: "a" }, { text: %(echo "=== end ==="), op: "&&" }])
      expect(parse("echo $(ls) && a")[:steps].size).to eq(2)
    end
  end

  describe "heredocs" do
    it "cuts a body out of its step" do
      expect(parse("cat > /tmp/x.sh <<'EOF'\nrm -rf /p\nit's\nEOF\nchmod +x /tmp/x.sh && echo ready")).to eq(
        steps: [{ text: "cat > /tmp/x.sh <<'EOF'", heredoc: { tag: "EOF", lines: 2 } },
                { text: "chmod +x /tmp/x.sh", op: "\n" }, { text: "echo ready", op: "&&" }]
      )
      expect(parse("cat <<-END | wc -l\n\ta\n\tEND")).to eq(
        steps: [{ text: "cat <<-END", heredoc: { tag: "END", lines: 1 } }, { text: "wc -l", op: "|" }]
      )
    end

    it "one inside $(…): git commit -m \"$(cat <<'EOF' … EOF)\" is one step" do
      text = "cd /p/app && git add -A && git commit -m \"$(cat <<'EOF'\nFix (a) thing\n\nBody: it's done.\nEOF\n)\" && git log --oneline -1"
      expect(parse(text)).to eq(
        cd: "/p/app",
        steps: [{ text: "git add -A" }, { text: %(git commit -m "$(cat <<'EOF')"), op: "&&", heredoc: { tag: "EOF", lines: 3 } },
                { text: "git log --oneline -1", op: "&&" }]
      )
    end

    it "<< in quotes or $((…)) is no heredoc" do
      expect(parse("echo '<<EOF' && echo $((1<<3))")).to eq(steps: [{ text: "echo '<<EOF'" }, { text: "echo $((1<<3))", op: "&&" }])
    end
  end

  describe "fallback (nil)" do
    [
      "for f in *.rb; do ruby -c $f; done", "while read l; do echo $l; done < x", "ls | while read f; do :; done",
      "if [ -f x ]; then cat x; fi", "case $1 in a) ls;; esac", "f() { ls; }", "{ ls; pwd; } > out",
      "echo 'open", "cat <<EOF\nno end", "echo $(echo \")\")", "echo (", "echo )", "", "  \n", "# only a comment"
    ].each do |text|
      it text.inspect do
        expect(parse(text)).to be_nil
      end
    end

    it "keeps keywords that are arguments" do
      expect(parse("echo done for if && git log --grep while")[:steps].size).to eq(2)
    end
  end
end
