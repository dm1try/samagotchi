# frozen_string_literal: true

require "samagotchi/tools/execute"
require "samagotchi/tools/shell"

RSpec.describe Samagotchi::Tools::Shell do
  describe ".program" do
    it "is zsh in sh emulation on macOS when /bin/zsh is there" do
      expect(described_class.program(host_os: "darwin25.0", zsh: true))
        .to eq(["/bin/zsh", "--emulate", "sh", "+o", "ignore_braces", "+o", "sh_glob", "-o", "bash_rematch",
                "+o", "bsd_echo"])
    end

    it "is /bin/sh on macOS without zsh, and on Linux" do
      expect(described_class.program(host_os: "darwin25.0", zsh: false)).to eq(["/bin/sh"])
      expect(described_class.program(host_os: "linux-gnu", zsh: true)).to eq(["/bin/sh"])
    end
  end

  it "builds a -c argv" do
    allow(described_class).to receive(:program).and_return(["/bin/sh"])
    expect(described_class.argv("echo hi")).to eq(["/bin/sh", "-c", "echo hi"])
  end

  # Through execute, in whatever shell this host picks.
  describe "commands the models write" do
    def run(command) = Samagotchi::Tools::Execute.call(command)

    it "runs a commit message heredoc with an apostrophe inside $( )" do
      result = run(%(msg="$(cat <<'EOF'\nit's done\nEOF\n)"; printf '%s\\n' "$msg"))
      expect(result).to include("it's done").and end_with("exit: 0")
    end

    # The zsh mode's promise; Linux's /bin/sh (dash on CI) has none of these.
    it "keeps bash habits: brace ranges, [[ ]] with =~ groups, arrays, $'..', &>" do
      skip "only where commands run in zsh emulating sh (macOS)" unless described_class.program.first.end_with?("zsh")

      result = run(<<~'SH')
        echo {1..3}
        [[ abc =~ ^a(b) ]] && echo "m:${BASH_REMATCH[1]}"
        a=(one two three); echo "${a[1]} ${#a[@]}"
        printf '%s\n' $'x\ty'
        ls /nonexistent-chi-dir &> /dev/null || echo quiet
      SH
      expect(result).to include("1 2 3", "m:b", "two 3", "x\ty", "quiet")
    end

    it "splits words and leaves an unmatched glob as is, as sh does" do
      result = run(%(x="a b"; for w in $x; do echo "[$w]"; done; echo *.no-such-ext-chi))
      expect(result).to include("[a]\n[b]", "*.no-such-ext-chi").and end_with("exit: 0")
    end
  end
end
