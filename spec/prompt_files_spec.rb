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

    it "is every AGENTS.md from the top down to the cwd, outermost first" do
      write(File.join(repo, "AGENTS.md"), "root")
      write(File.join(repo, "a", "b", "AGENTS.md"), "b")
      FileUtils.mkdir_p(File.join(repo, "a", "b", "c"))
      expect(described_class.agents_paths(File.join(repo, "a", "b", "c")))
        .to eq([File.join(repo, "AGENTS.md"), File.join(repo, "a", "b", "AGENTS.md")])
    end

    it "is a subdirectory's alone when the top has none" do
      write(File.join(repo, "sub", "AGENTS.md"), "sub")
      expect(described_class.agents_paths(File.join(repo, "sub"))).to eq([File.join(repo, "sub", "AGENTS.md")])
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

  describe ".agents_sections" do
    before { system("git", "init", "-q", repo, exception: true) }

    it "gives the first file the plain header and each further one its directory" do
      write(File.join(repo, "AGENTS.md"), "root")
      write(File.join(repo, "pkg", "AGENTS.md"), "pkg")
      sections = described_class.agents_sections(File.join(repo, "pkg"))
      expect(sections.map(&:path)).to eq([File.join(repo, "AGENTS.md"), File.join(repo, "pkg", "AGENTS.md")])
      expect(sections.map(&:text)).to eq(["Project specific description:\nroot",
                                          "Project specific description for pkg/:\npkg"])
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

RSpec.describe Samagotchi::PromptFiles, ".display_path" do
  it "is relative to the work tree top inside it, else with ~ for the home directory" do
    expect(described_class.display_path("/r/docs/a.md", top: "/r")).to eq("docs/a.md")
    expect(described_class.display_path("#{Dir.home}/notes/b.md", top: "/r")).to eq("~/notes/b.md")
    expect(described_class.display_path("/etc/c.md", top: nil)).to eq("/etc/c.md")
  end
end

RSpec.describe Samagotchi::PromptFiles, ".check_cli_file" do
  around do |example|
    Dir.mktmpdir do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  it "expands the path against the cwd" do
    File.write(File.join(@tmp, "a.md"), "x")
    expect(described_class.check_cli_file("a.md", cwd: @tmp)).to eq([File.join(@tmp, "a.md"), nil])
  end

  it "is an error, not an exception, for a ~user that doesn't exist" do
    expect(described_class.check_cli_file("~nosuchuser_zz/x.md", cwd: @tmp)).to eq(["~nosuchuser_zz/x.md", "no such user"])
  end

  it "is an error for a missing file, a directory and an unreadable file" do
    expect(described_class.check_cli_file("gone.md", cwd: @tmp).last).to include("no such file")
    expect(described_class.check_cli_file(@tmp, cwd: @tmp).last).to include("not a file")
    path = File.join(@tmp, "locked.md")
    File.write(path, "x")
    File.chmod(0o000, path)
    expect(described_class.check_cli_file(path, cwd: @tmp).last).to include("can't be read") unless Process.uid.zero?
  end
end
