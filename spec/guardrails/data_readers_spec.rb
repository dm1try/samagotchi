# frozen_string_literal: true

require "samagotchi/guardrails/data_readers"

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
end
