# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require "samagotchi/git_env"

# A suite run from `git rebase --exec` or a hook once wrote core.bare=true, a
# fake identity and a branch into the real .git. The mechanism's one test: each
# entry point in a child ruby, whose inherited GIT_DIR is a temp sentinel repo.
RSpec.describe Samagotchi::GitEnv do
  around do |example|
    Dir.mktmpdir("spec-git-env") do |dir|
      @tmp = File.realpath(dir)
      example.run
    end
  end

  let(:sentinel) do
    File.join(@tmp, "sentinel").tap do |dir|
      system("git", "init", "-q", dir, exception: true)
      system("git", "-C", dir, "-c", "user.name=x", "-c", "user.email=x@x", "commit", "-q", "--allow-empty", "-m", "x", exception: true)
    end
  end

  # Every file of the sentinel's .git, with its bytes.
  def sentinel_files
    git_dir = File.join(sentinel, ".git")
    Dir.glob("**/*", File::FNM_DOTMATCH, base: git_dir)
       .select { |path| File.file?(File.join(git_dir, path)) }
       .to_h { |path| [path, File.binread(File.join(git_dir, path))] }
  end

  # What a spec's git does to its temp repo, after loading +entry+; prints the
  # git dir a bare `git` finds from a folder in no repo, plain and unbundled.
  def child_script(entry)
    <<~RUBY
      require #{entry.inspect}
      repo = #{File.join(@tmp, "repo").inspect}
      system("git", "init", "-q", repo, exception: true)
      system("git", "-C", repo, "config", "user.name", "fake", exception: true)
      where = -> { IO.popen(%w[git rev-parse --absolute-git-dir], err: File::NULL, &:read).strip }
      puts "plain: \#{where.call}"
      puts "unbundled: \#{Bundler.with_unbundled_env(&where)}"
    RUBY
  end

  ["spec_helper", "samagotchi/testing/rspec", "samagotchi/testing/minitest"].each do |entry|
    it "keeps a child that loads #{entry} off an inherited GIT_DIR" do
      before = sentinel_files
      outside = File.join(@tmp, "outside").tap { |dir| FileUtils.mkdir_p(dir) }
      lib = File.expand_path("../lib", __dir__)
      out, status = Open3.capture2e({ "GIT_DIR" => File.join(sentinel, ".git"), "GIT_WORK_TREE" => sentinel, "GIT_INDEX_FILE" => "x" },
                                    RbConfig.ruby, "-I", lib, "-I", __dir__, "-e", child_script(entry), chdir: outside)

      expect(status).to be_success, out
      expect(out).to include("plain: \n", "unbundled: \n")
      expect(sentinel_files).to eq(before)
      expect(File.read(File.join(@tmp, "repo", ".git", "config"))).to include("name = fake")
    end
  end

  it "lists all git calls local but the suite's own GIT_CONFIG_COUNT" do
    local = IO.popen(%w[git rev-parse --local-env-vars], &:read).split
    expect(local - described_class::VARS).to eq(["GIT_CONFIG_COUNT"])
    expect(described_class::VARS - local).to eq([])
  end

  it "clears them in a sandbox, puts them back after it, and leaves the suite's GIT_CONFIG_COUNT" do
    require "samagotchi/testing/sandbox"
    with_env("GIT_DIR" => "/nowhere/.git") do
      Samagotchi::Testing::Sandbox.with do
        expect(ENV).not_to have_key("GIT_DIR")
        expect(ENV["GIT_CONFIG_COUNT"]).to eq("2")
      end
      expect(ENV["GIT_DIR"]).to eq("/nowhere/.git")
    end
  end
end
