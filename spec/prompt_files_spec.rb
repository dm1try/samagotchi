# frozen_string_literal: true

require "tmpdir"
require "samagotchi/prompt_files"

RSpec.describe Samagotchi::PromptFiles do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  let(:repo) { File.join(@tmp, "repo") }

  describe ".agents_paths" do
    before { system("git", "init", "-q", repo, exception: true) }

    it "is the work tree top's from a subdirectory" do
      write(File.join(repo, "AGENTS.md"), "root")
      FileUtils.mkdir_p(File.join(repo, "lib"))
      expect(described_class.agents_paths(File.join(repo, "lib"))).to eq([File.join(repo, "AGENTS.md")])
    end

    it "is the top's at the top" do
      write(File.join(repo, "AGENTS.md"), "root")
      expect(described_class.agents_paths(repo)).to eq([File.join(repo, "AGENTS.md")])
    end

    it "is empty without any AGENTS.md" do
      expect(described_class.agents_paths(repo)).to eq([])
    end

    it "is only the cwd's outside a repository" do
      plain = File.join(@tmp, "plain", "sub")
      write(File.join(@tmp, "plain", "AGENTS.md"), "parent")
      FileUtils.mkdir_p(plain)
      expect(described_class.agents_paths(plain)).to eq([])
      write(File.join(plain, "AGENTS.md"), "own")
      expect(described_class.agents_paths(plain)).to eq([File.join(plain, "AGENTS.md")])
    end
  end

  describe ".section" do
    it "is the stripped text under the header" do
      write(File.join(@tmp, "a.md"), "\n  notes \n\n")
      expect(described_class.section(File.join(@tmp, "a.md"), "Head:")).to eq("Head:\nnotes")
    end

    it "is nil for an empty or missing file" do
      write(File.join(@tmp, "empty.md"), " \n")
      expect(described_class.section(File.join(@tmp, "empty.md"), "Head:")).to be_nil
      expect(described_class.section(File.join(@tmp, "gone.md"), "Head:")).to be_nil
    end
  end
end
