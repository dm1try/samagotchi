# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "../../script/affected_specs/git_tree"

# GitTree on a temp git repo: the lines a code change touches, and one grep
# for several words.
RSpec.describe AffectedSpecs::GitTree do
  let(:repo) { File.realpath(Dir.mktmpdir("git-tree-")) }

  after { FileUtils.rm_rf(repo) }

  def git(*args)
    output, status = Open3.capture2e("git", "-C", repo, "-c", "user.name=x", "-c", "user.email=x@x", *args)
    raise output unless status.success?

    output
  end

  def write(path, text)
    FileUtils.mkdir_p(File.join(repo, File.dirname(path)))
    File.write(File.join(repo, path), text)
  end

  def commit
    git("add", "-A")
    git("commit", "-q", "-m", "x")
    git("rev-parse", "HEAD").strip
  end

  before do
    git("init", "-q", "-b", "main")
    write("lib/a.rb", (1..10).map { |i| "line #{i}\n" }.join)
    write("script/tool", "one\ntwo\nthree\n")
    write("spec/a_spec.rb", "alpha beta alpha\nalphabet\n")
    write("spec/b_spec.rb", "beta\n")
    @base = commit
  end

  describe "#changed_lines" do
    it "gives a one-line hunk (no count), a hunk's range and a pure deletion's line before it" do
      lines = File.read(File.join(repo, "lib/a.rb")).lines
      lines[2] = "changed 3\n"
      lines[5, 2] = ["new 6\n", "new 7\n"]
      lines.delete_at(8) # line 9 deleted: after new line 8
      File.write(File.join(repo, "lib/a.rb"), lines.join)
      write("script/tool", "one\nthree\n")

      tree = described_class.new(repo, base: @base)
      expect(tree.changed_lines("lib/a.rb")).to eq([3, 6, 7, 8])
      expect(tree.changed_lines("script/tool")).to eq([1])
    end

    it "gives every line of an untracked code file, and the range's lines at a commit" do
      write("lib/new.rb", "a\nb\n")
      expect(described_class.new(repo, base: @base).changed_lines("lib/new.rb")).to eq([1, 2])

      head = commit
      expect(described_class.new(repo, head, base: @base).changed_lines("lib/new.rb")).to eq([1, 2])
    end

    it "gives nothing with no base, or for an unchanged file" do
      write("lib/a.rb", "x\n")
      expect(described_class.new(repo).changed_lines("lib/a.rb")).to eq([])
      expect(described_class.new(repo, base: @base).changed_lines("script/tool")).to eq([])
    end
  end

  describe "#mentions_each" do
    it "counts each word's whole-word mentions per file in one grep, in the working tree and at a commit" do
      want = { "alpha" => { "spec/a_spec.rb" => 2 }, "beta" => { "spec/a_spec.rb" => 1, "spec/b_spec.rb" => 1 } }
      paths = %w[spec/a_spec.rb spec/b_spec.rb]

      expect(described_class.new(repo, base: @base).mentions_each(%w[alpha beta gamma], paths)).to eq(want)
      expect(described_class.new(repo, @base, base: "#{@base}^").mentions_each(%w[alpha beta], paths)).to eq(want)
      expect(described_class.new(repo).mentions_each([], paths)).to eq({})
    end

    it "falls back to -F -w patterns when git has no Perl regexes" do
      tree = described_class.new(repo)
      allow(tree).to receive(:grep_o).and_call_original
      allow(tree).to receive(:grep_o).with(array_including("-P"), anything).and_return(nil)

      expect(tree.mentions_each(%w[alpha beta], %w[spec/a_spec.rb]))
        .to eq({ "alpha" => { "spec/a_spec.rb" => 2 }, "beta" => { "spec/a_spec.rb" => 1 } })
    end

    it "matches a name ending in ? or ! as a whole word" do
      write("spec/c_spec.rb", "x.empty? x.empty?y save! saved\n")

      expect(described_class.new(repo).mentions_each(%w[empty? save!], %w[spec/c_spec.rb]))
        .to eq({ "empty?" => { "spec/c_spec.rb" => 1 }, "save!" => { "spec/c_spec.rb" => 1 } })
    end
  end
end
