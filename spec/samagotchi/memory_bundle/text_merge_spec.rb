# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

require "samagotchi/memory_bundle/text_merge"

RSpec.describe Samagotchi::MemoryBundle::TextMerge do
  let(:tmp) { Dir.mktmpdir("samagotchi-text-merge-") }

  after { FileUtils.rm_rf(tmp) }

  def merge(base, ours, theirs) = described_class.merge(base: base, ours: ours, theirs: theirs)

  def fake_git(body)
    dir = File.join(tmp, "bin")
    FileUtils.mkdir_p(dir)
    File.join(dir, "git").tap do |path|
      File.write(path, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, path)
    end
  end

  it "merges edits in different places, with no markers" do
    result = merge("a\n\nb\n\nc\n", "A\n\nb\n\nc\n", "a\n\nb\n\nC\n")

    expect(result).to be_clean
    expect(result.text).to eq("A\n\nb\n\nC\n")
    expect(result.hunks).to be_empty
  end

  it "calls edits of one line a conflict, with no text and the hunk's sides" do
    result = merge("# H\n\na\n", "# H\n\nmine\n", "# H\n\ntheirs\n")

    expect(result.status).to eq(:conflict)
    expect(result.text).to be_nil
    expect(result.hunks.map(&:to_h)).to eq([{ heading: "H", ours: ["mine\n"], base: ["a\n"], theirs: ["theirs\n"], union: false }])
  end

  it "counts every hunk against git's exit status" do
    middle = "one\ntwo\nthree\nfour\nfive\nsix\n"
    result = merge("a\n#{middle}b\n", "a1\n#{middle}b1\n", "a2\n#{middle}b2\n")

    expect(result.status).to eq(:conflict)
    expect(result.hunks.size).to eq(2)
  end

  it "keeps a line ending as the file has it" do
    result = merge("## Changelog\r\n- a\r\n", "## Changelog\r\n- a\r\n- b\r\n", "## Changelog\r\n- a\r\n- c\r\n")

    expect(result).to be_clean
    expect(result.text).to eq("## Changelog\r\n- a\r\n- b\r\n- c\r\n")
  end

  describe ".changed_sections" do
    def changed(base, theirs) = described_class.changed_sections(base, theirs)

    it "names each section the bundle changed or added, in its order" do
      base = "# T\n\nintro\n\n## A\n\nold\n\n## B\n\nsame\n"
      theirs = "# T\n\nintro\n\n## A\n\nnew\n\n## B\n\nsame\n\n### New\n\nmore\n"

      expect(changed(base, theirs)).to eq([["## A", "### New"], false])
    end

    it "names a section the bundle took out" do
      expect(changed("## A\n\none\n\n## B\n\ntwo\n", "## A\n\none\n")).to eq([["## B"], false])
    end

    it "says when text under no heading changed" do
      expect(changed("a\nb\n", "a\nc\n")).to eq([[], true])
      expect(changed("old\n\n## A\n\nx\n", "new\n\n## A\n\ny\n")).to eq([["## A"], true])
    end

    it "takes no fenced line for a heading, and puts a Changelog last" do
      base = "## Changelog\n\n- a\n\n## A\n\n```\n## not one\nx\n```\n"
      theirs = "## Changelog\n\n- a\n- b\n\n## A\n\n```\n## not one\ny\n```\n"

      expect(changed(base, theirs)).to eq([["## A", "## Changelog"], false])
    end

    it "finds nothing when nothing changed, or only moved" do
      expect(changed("## A\n\n1\n\n## B\n\n2\n", "## B\n\n2\n\n## A\n\n1\n")).to eq([[], false])
    end
  end

  describe "the Changelog rule" do
    let(:base) { "# T\n\n## Changelog\n- one\n" }

    def union(ours_tail, theirs_tail, base: self.base)
      merge(base, base + ours_tail, base + theirs_tail)
    end

    it "unions, yours then the bundle's" do
      result = union("- mine\n", "- theirs\n")

      expect(result).to be_clean
      expect(result.text).to eq("#{base}- mine\n- theirs\n")
      expect(result.hunks.map(&:heading)).to eq(["Changelog"])
    end

    it "takes the title in any case, with a colon or closing #s, and Change log" do
      ["## CHANGELOG\n", "## changelog:\n", "## Changelog ##\n", "# Change log\n"].each do |heading|
        expect(union("- m\n", "- t\n", base: "#{heading}- one\n")).to be_clean
      end
    end

    it "doesn't take a title that only mentions a changelog" do
      expect(union("- m\n", "- t\n", base: "## Why the changelog matters\n- one\n").status).to eq(:conflict)
      expect(union("- m\n", "- t\n", base: "## Changelog rules\n- one\n").status).to eq(:conflict)
    end

    it "doesn't union a side holding a heading" do
      expect(union("## Mine\n", "- theirs\n").status).to eq(:conflict)
      expect(union("- mine\n", "- x\n### Theirs\n- y\n").status).to eq(:conflict)
    end

    it "doesn't union a side holding a fence, a rule or an underline" do
      ["```\n", "~~~\n", "---\n", "***\n", "Title\n===\n"].each do |line|
        expect(union(line, "- theirs\n").status).to eq(:conflict), "#{line.inspect} unioned"
      end
    end

    it "takes no heading from a code fence: the real section's rules stay safe" do
      text = "## Rules\n\n```\n## Changelog\n```\n\nthe rule\n"
      expect(merge(text, "#{text}mine\n", "#{text}theirs\n").status).to eq(:conflict)
    end

    it "doesn't union inside a fence, an unclosed one too" do
      text = "## Changelog\n\n```\n- one\n"
      expect(merge(text, "#{text}- m\n", "#{text}- t\n").status).to eq(:conflict)
    end

    it "closes a fence only on its own character, as long or longer" do
      text = "## Rules\n\n````\n```\n## Changelog\n````\n\nthe rule\n"
      expect(merge(text, "#{text}m\n", "#{text}t\n").status).to eq(:conflict)

      closed = "````\nx\n`````\n\n## Changelog\n- one\n"
      expect(merge(closed, "#{closed}- m\n", "#{closed}- t\n")).to be_clean
    end

    it "looks at the last heading, wherever a clean merge put it" do
      ours = "#{base}- mine\n"
      theirs = "#{base}- theirs\n\n## Rules\n\nkeep this\n"
      expect(merge(base, ours, theirs).status).to eq(:conflict)
    end

    it "lets a rule or an underline end the section" do
      text = "## Changelog\n- one\n\n---\n\nthe rule\n"
      expect(merge(text, "#{text}m\n", "#{text}t\n").status).to eq(:conflict)

      setext = "## Changelog\n- one\n\nRules\n=====\n\nthe rule\n"
      expect(merge(setext, "#{setext}m\n", "#{setext}t\n").status).to eq(:conflict)
    end

    it "keeps an entry's indented lines with it, and an entry both sides added once" do
      ours = "#{base}- mine\n  more of mine\n- shared\n"
      theirs = "#{base}- theirs\n  more of mine\n- shared\n"
      result = merge(base, ours, theirs)

      expect(result).to be_clean
      expect(result.text).to eq("#{base}- mine\n  more of mine\n- shared\n- theirs\n  more of mine\n")
    end

    it "takes any list form, blank lines between entries too" do
      expect(union("* m\n\n+ m2\n", "1. t\n2) t2\n")).to be_clean
    end

    it "compares whole entries, so a nested item both sides share stays with each" do
      result = union("- a\n  - note\n", "- b\n  - note\n")

      expect(result).to be_clean
      expect(result.text).to end_with("- one\n- a\n  - note\n- b\n  - note\n")
    end

    it "takes an entry both sides added, nested item and all, once" do
      result = union("- a\n  - note\n- b\n", "- a\n  - note\n- c\n")

      expect(result).to be_clean
      expect(result.text.scan("  - note").size).to eq(1)
      expect(result.text).to end_with("- b\n- c\n")
    end

    it "keeps items at one indent as entries of their own" do
      result = union("  - a\n  - same\n", "  - b\n  - same\n")

      expect(result).to be_clean
      expect(result.text).to end_with("  - a\n  - same\n  - b\n")
    end

    it "doesn't union a line that isn't a list entry" do
      ["IMPORTANT: always ask before pushing.\n", "**Rules**\n", "#Rules\n", "plain text\n", "  indented, no entry above\n", "- - -\n"].each do |line|
        expect(union(line, "- theirs\n").status).to eq(:conflict), "#{line.inspect} unioned on ours"
        expect(union("- mine\n", line).status).to eq(:conflict), "#{line.inspect} unioned on theirs"
      end
    end

    it "doesn't take an indented heading, rule, fence or loose paragraph for more of an entry" do
      ["- m\n    ## Rules\n", "- m\n\t## Rules\n", "- m\n    ```\n", "- m\n    ---\n", "- m\n\n    Always ask first.\n", "    Always ask first.\n"].each do |side|
        expect(union(side, "- theirs\n").status).to eq(:conflict), "#{side.inspect} unioned on ours"
        expect(union("- mine\n", side).status).to eq(:conflict), "#{side.inspect} unioned on theirs"
      end
    end

    it "doesn't union under an entry with an indented heading, fence or loose paragraph" do
      ["  ## Rules\n", "\t## Rules\n", "    ```\n", "\n    Always ask first.\n"].each do |line|
        text = "#{base}#{line}"
        expect(merge(text, "#{text}- m\n", "#{text}- t\n").status).to eq(:conflict), "#{line.inspect} unioned"
      end
    end

    it "still takes wrapped lines right under an entry, a nested item too, in the section and in a side" do
      text = "#{base}  wrapped\n    - nested\n\n- two\n"
      expect(merge(text, "#{text}- m\n  wrapped m\n", "#{text}- t\n  wrapped t\n")).to be_clean
    end

    it "doesn't union under a section that stopped being a list" do
      ["IMPORTANT: always ask\n", "**Rules**\n", "#Rules\n"].each do |line|
        text = "#{base}#{line}- rule\n"
        expect(merge(text, "#{text}- mine\n", "#{text}- theirs\n").status).to eq(:conflict), "#{line.inspect} unioned"
      end
    end

    it "doesn't take a nested Changelog for the file's" do
      text = "## Steps\n### Changelog\n- one\n"
      expect(merge(text, "#{text}- m\n", "#{text}- t\n").status).to eq(:conflict)
    end

    it "takes no heading from an HTML comment, and doesn't union inside one" do
      text = "<!--\n## Changelog\n-->\n- one\n"
      expect(merge(text, "#{text}- m\n", "#{text}- t\n").status).to eq(:conflict)

      open_comment = "## Changelog\n<!--\n- one\n"
      expect(merge(open_comment, "#{open_comment}- m\n", "#{open_comment}- t\n").status).to eq(:conflict)
    end

    it "is a conflict when both sides drop a base heading or rule" do
      text = "## Changelog\n- a\n\n## Rules\n- always ask\n"
      expect(merge(text, "## Changelog\n- a\n\n- always ask me\n", "## Changelog\n- a\n\n- never ask\n").status).to eq(:conflict)

      ruled = "## Changelog\n- a\n---\n- b\n"
      expect(merge(ruled, "## Changelog\n- a\n- m\n- b\n", "## Changelog\n- a\n- t\n- b\n").status).to eq(:conflict)
    end

    it "is a conflict when a side edited or dropped an entry: that is a decision, not an addition" do
      text = "## Changelog\n- a\n- z\n"
      {
        "the bundle drops an entry you edited" => ["## Changelog\n- a mine\n- z\n", "## Changelog\n- z\n"],
        "you drop an entry the bundle edited" => ["## Changelog\n- z\n", "## Changelog\n- a new\n- z\n"],
        "you edit one, the bundle adds next to it" => ["## Changelog\n- a mine\n- z\n", "## Changelog\n- a\n- new\n- z\n"],
        "both edit one" => ["## Changelog\n- a mine\n- z\n", "## Changelog\n- a theirs\n- z\n"]
      }.each do |what, (ours, theirs)|
        expect(merge(text, ours, theirs).status).to eq(:conflict), what
      end
    end

    it "keeps the shipped memory guide's fenced Changelog a conflict" do
      guide = File.read(File.expand_path("../../../lib/samagotchi/bundles/system/memory_guide.md", __dir__))
      lines = guide.lines
      after = lines.index { |l| l.start_with?("## Changelog") } + 8
      ours = lines.dup.tap { |l| l[after] = "USER #{l[after]}" }
      theirs = lines.dup.tap { |l| l[after] = "BUNDLE #{l[after]}" }

      expect(merge(guide, ours.join, theirs.join).status).to eq(:conflict)
    end

    it "is a conflict when one hunk unions and another doesn't" do
      text = "intro\n\n\n\n## Changelog\n- one\n"
      ours = "mine\n\n\n\n## Changelog\n- one\n- m\n"
      theirs = "theirs\n\n\n\n## Changelog\n- one\n- t\n"
      result = merge(text, ours, theirs)

      expect(result.status).to eq(:conflict)
      expect(result.hunks.map(&:union?)).to eq([false, true])
    end
  end

  describe "when the answer can't be trusted" do
    it "fails on a side with a NUL anywhere, with no git run" do
      long = "#{"x\n" * 10_000}\0\n"
      expect(merge(long, "a\n", "b\n").why).to eq(described_class::NOT_TEXT)
    end

    it "fails on a line of yours equal to the separator inside a hunk" do
      separator = described_class::SEPARATOR
      result = merge("a\n", "mine\n#{separator}\nmine too\n", "theirs\n")

      expect(result.status).to eq(:failed)
      expect(result.why).to eq(described_class::UNREADABLE)
    end

    it "fails on a line of yours equal to a marker, outside a hunk too" do
      [described_class::OPEN, described_class::CLOSE].each do |marker|
        text = "keep\n\n\n\nb\n"
        result = merge(text, "keep\n#{marker}\n\n\n\nmine\n", "keep\n\n\n\ntheirs\n")

        expect(result.status).to eq(:failed), "#{marker} read"
      end
    end

    it "fails on a line of yours equal to a marker with no conflict in the file, not a truncated text" do
      [described_class::OPEN, described_class::CLOSE, described_class::BASE_MARK].each do |marker|
        text = "keep\n\none\ntwo\nthree\nfour\nfive\n\nb\n"
        result = merge(text, "keep\n#{marker}\n\none\ntwo\nthree\nfour\nfive\n\nb\n", "keep\n\none\ntwo\nthree\nfour\nfive\n\nB\n")

        expect(result).to have_attributes(status: :failed, text: nil), "#{marker} read"
      end
    end

    it "counts past git's cap of 127" do
      lines = (1..800).map { |n| "line #{n}\n" }
      edit = ->(mark) { lines.each_with_index.map { |line, i| (i % 6).zero? && i < 780 ? "#{mark}#{line}" : line }.join }
      result = merge(lines.join, edit.call("u"), edit.call("t"))

      expect(result.status).to eq(:conflict)
      expect(result.hunks.size).to be > 127
    end

    it "fails when git exits 0 with nothing, or with lines no input holds" do
      git = fake_git("exit 0")
      with_env("PATH" => File.dirname(git)) { expect(merge("a\n", "b\n", "c\n").why).to eq(described_class::UNREADABLE) }

      File.write(git, "#!/bin/sh\necho garbage\nexit 0\n")
      with_env("PATH" => File.dirname(git)) { expect(merge("a\n", "b\n", "c\n").why).to eq(described_class::UNREADABLE) }
    end

    it "stops a git that takes too long, its children too, and reads as no merge" do
      stub_const("#{described_class}::TIMEOUT", 0.2)
      git = fake_git("/bin/sleep 5")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = with_env("PATH" => File.dirname(git)) { merge("a\n", "b\n", "c\n") }

      expect(result).to have_attributes(status: :failed, why: described_class::TIMED_OUT)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
    end

    it "takes a separator line outside any hunk as text" do
      separator = described_class::SEPARATOR
      result = merge("a\n\nb\n\nc\n", "a\n\n#{separator}\n\nb\n\nc\n", "a\n\nb\n\nC\n")

      expect(result).to be_clean
      expect(result.text).to include(separator)
    end

    it "fails when the hunks don't match git's exit status" do
      stub_const("#{described_class}::APPLE_STUB", "/nowhere")
      git = fake_git("echo text; exit 3")
      with_env("PATH" => File.dirname(git)) do
        expect(merge("a\n", "b\n", "c\n").why).to eq(described_class::UNREADABLE)
      end
    end

    it "fails on git's own error status and on a signal" do
      git = fake_git("exit 255")
      with_env("PATH" => File.dirname(git)) { expect(merge("a\n", "b\n", "c\n").why).to eq(described_class::UNREADABLE) }

      File.write(git, "#!/bin/sh\nkill -9 $$\n")
      with_env("PATH" => File.dirname(git)) { expect(merge("a\n", "b\n", "c\n").why).to eq(described_class::UNREADABLE) }
    end
  end

  describe "which git" do
    it "fails with no git on PATH" do
      FileUtils.mkdir_p(File.join(tmp, "empty"))
      with_env("PATH" => File.join(tmp, "empty")) do
        expect(merge("a\n", "b\n", "c\n")).to have_attributes(status: :failed, why: described_class::NO_GIT)
      end
    end

    it "ignores what the environment says about a repository and a config" do
      repo = File.join(tmp, "repo")
      expect(system({ "GIT_DIR" => nil, "GIT_WORK_TREE" => nil }, "git", "init", "-q", repo)).to be true
      git_dir = File.join(repo, ".git")
      File.write(File.join(git_dir, "config"), "[not valid\n", mode: "a")

      with_env("GIT_DIR" => git_dir, "GIT_WORK_TREE" => repo) do
        result = merge("# H\n\na\n", "# H\n\nmine\n", "# H\n\ntheirs\n")

        expect(result.status).to eq(:conflict)
        expect(result.hunks.first.base).to eq(["a\n"])
      end
    end

    it "ignores config passed down from a git above it" do
      with_env("GIT_CONFIG_PARAMETERS" => "not valid") do
        expect(merge("# H\n\na\n", "# H\n\nmine\n", "# H\n\ntheirs\n").status).to eq(:conflict)
      end
    end

    it "ignores a broken global config" do
      config = File.join(tmp, "broken")
      File.write(config, "[not valid\n")
      with_env("HOME" => tmp, "XDG_CONFIG_HOME" => tmp, "GIT_CONFIG_GLOBAL" => config) do
        expect(merge("a\n\nb\n", "A\n\nb\n", "a\n\nB\n")).to be_clean
      end
    end

    context "with macOS's stand-in for git" do
      let(:ran) { File.join(tmp, "git-ran") }
      let(:git) { fake_git(": > #{ran}; exit 0") }

      def xcode_select(body)
        path = File.join(tmp, "xcode-select")
        File.write(path, "#!/bin/sh\n#{body}\n")
        File.chmod(0o755, path)
        stub_const("#{described_class}::XCODE_SELECT", path)
      end

      before do
        stub_const("#{described_class}::APPLE_STUB", git)
        allow(described_class).to receive(:darwin?).and_return(true)
      end

      it "doesn't run it when no developer tools are behind it" do
        xcode_select("echo error >&2; exit 2")
        with_env("PATH" => File.dirname(git)) do
          expect(merge("a\n", "b\n", "c\n")).to have_attributes(status: :failed, why: described_class::STUB_GIT)
        end
        expect(File.exist?(ran)).to be false
      end

      it "doesn't run it when the selected tools are gone" do
        xcode_select("echo #{tmp}/gone; exit 0")
        with_env("PATH" => File.dirname(git)) { expect(merge("a\n", "b\n", "c\n").why).to eq(described_class::STUB_GIT) }
        expect(File.exist?(ran)).to be false
      end

      it "doesn't run it when it can't tell" do
        stub_const("#{described_class}::XCODE_SELECT", File.join(tmp, "missing"))
        with_env("PATH" => File.dirname(git)) { expect(merge("a\n", "b\n", "c\n").why).to eq(described_class::STUB_GIT) }
        expect(File.exist?(ran)).to be false
      end

      it "runs it when the tools are there" do
        xcode_select("echo #{tmp}; exit 0")
        with_env("PATH" => File.dirname(git)) { merge("a\n", "b\n", "c\n") }
        expect(File.exist?(ran)).to be true
      end

      it "doesn't ask about another git" do
        stub_const("#{described_class}::APPLE_STUB", File.join(tmp, "elsewhere"))
        xcode_select("exit 2")
        with_env("PATH" => File.dirname(git)) { merge("a\n", "b\n", "c\n") }
        expect(File.exist?(ran)).to be true
      end
    end
  end
end
