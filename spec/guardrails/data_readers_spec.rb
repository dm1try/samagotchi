# frozen_string_literal: true

require "samagotchi/guardrails/data_readers"
require "samagotchi/guardrails/shell_lex"

# Which commands read their stdin as data and never run it
# (Guardrails::DataReaders): the lexer's data_sink? and ShellLex.code_text
# both ask it.
RSpec.describe Samagotchi::Guardrails::DataReaders do
  heredoc = Samagotchi::Guardrails::DataReaders::HEREDOC

  describe ".command_word" do
    {
      %w[git push] => "git",
      ["FOO=1", "cat"] => "cat",
      [">", "/tmp/x", "cat"] => "cat",
      [">/tmp/x", "cat"] => "cat",
      ["2>", "err", "tee", "f"] => "tee",
      [] => nil
    }.each do |words, expected|
      it "#{words.inspect} -> #{expected.inspect}" do
        expect(described_class.command_word(words)).to eq(expected)
      end
    end
  end

  describe ".writes_file?" do
    writing = [["cat", "<<EOF", heredoc, ">", "notes.md"], ["cat", ">notes.md"], ["cat", ">>", "log"],
               ["cat", "1>out"], ["cat", ">"], ["tee", "notes.md"], ["tee", "-a", "f"]]
    printing = [["cat", "<<EOF", heredoc], ["cat", ">&2"], ["cat", "2>&1"], ["cat", ">", "/dev/null"],
                ["cat", "2>err.log"], ["tee", "-a"], ["tee", "/dev/null"]]

    writing.each do |words|
      it "writes a file: #{words.inspect}" do
        expect(described_class.writes_file?(words)).to be(true)
      end
    end
    printing.each do |words|
      it "writes no file: #{words.inspect}" do
        expect(described_class.writes_file?(words)).to be(false)
      end
    end

    # bash reads ">& file" and ">&file" as "&>file": only a number or - after
    # the & names an fd.
    describe "a >& redirection" do
      fd_files = [["cat", "<<E", heredoc, ">&", "r.sh"], ["cat", ">&r.sh"], ["cat", "1>&", "r.sh"],
                  ["cat", "1>&r.sh"], ["cat", ">", "2"], ["cat", ">&-x"]]
      fd_dups = [["cat", ">&2"], ["cat", ">&-"], ["cat", "1>&2"], ["cat", "1>&-"], ["cat", ">&", "2"],
                 ["cat", ">&", "-"], ["cat", "1>&", "2"], ["cat", ">&", "/dev/null"]]

      fd_files.each do |words|
        it "writes the file it names: #{words.inspect}" do
          expect(described_class.writes_file?(words)).to be(true)
        end
      end
      fd_dups.each do |words|
        it "writes no file for a dup to an fd: #{words.inspect}" do
          expect(described_class.writes_file?(words)).to be(false)
        end
      end
    end
  end

  describe ".output_file?" do
    [%w[exec 3>run.sh], %w[exec 2>> log], %w[exec >run.sh], %w[exec >& run.sh], %w[exec 3>],
     %w[exec {fd}>run.sh], %w[exec {fd}>> log], %w[exec 3<>run.sh]].each do |words|
      it "writes a file: #{words.inspect}" do
        expect(described_class.output_file?(words)).to be(true)
      end
    end

    [%w[exec 2>/dev/null], %w[exec 3>&1], %w[exec >&2], %w[exec <in], %w[exec {fd}>&2]].each do |words|
      it "writes no file: #{words.inspect}" do
        expect(described_class.output_file?(words)).to be(false)
      end
    end
  end

  describe ".data_reader?" do
    reading = [%w[git commit -F -], %w[git commit -F-], %w[git commit --file=-], %w[git commit -a --file -],
               %w[git -C /tmp/x commit -F -], %w[git -c user.name=x commit -F -], %w[git tag -a v1 -F -],
               %w[gh pr create --title x --body-file -], %w[gh issue comment 12 -F -],
               %w[gh pr edit 3 --body-file=-], %w[gh release create v1 --notes-file -],
               %w[FOO=1 cat], ["cat", ">", "f"]]
    other = [["git", "commit", "-F", "<<A", "-\n"], %w[git commit -F msg.txt], %w[git commit],
             %w[git commit -F /dev/stdin], %w[git log -F -], %w[git notes add -F -], %w[gh api repos/o/r -F -],
             %w[gh pr view -F -], %w[env cat], %w[command cat], %w[bash], %w[sh -s], %w[ruby], %w[ssh host],
             %w[xargs sh -c x], []]

    reading.each do |words|
      it "reads stdin as data: #{words.inspect}" do
        expect(described_class.data_reader?(words)).to be(true)
      end
    end
    other.each do |words|
      it "is no data reader: #{words.inspect}" do
        expect(described_class.data_reader?(words)).to be(false)
      end
    end
  end

  describe ".message_arg?" do
    subst = Samagotchi::Guardrails::ShellLex::SUBST

    message = [[%w[git commit -m], 3], [%w[git commit --message], 3], [%w[git -C x commit -m], 5],
               [%w[git tag -a v1 -m], 5], [%w[gh pr create --body], 4], [%w[gh release create -n], 4]]
    other = [[%w[bash -c], 2], [%w[eval], 1], [%w[git commit -F], 3], [%w[echo -m], 2], [%w[git log -m], 3]]

    message.each do |words, index|
      it "is a message: #{(words + [subst]).inspect} at #{index}" do
        expect(described_class.message_arg?(words + [subst], index)).to be(true)
      end
    end
    other.each do |words, index|
      it "is no message: #{(words + [subst]).inspect} at #{index}" do
        expect(described_class.message_arg?(words + [subst], index)).to be(false)
      end
    end
  end
end
