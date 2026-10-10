# frozen_string_literal: true

require "fileutils"
require "open3"
require "tmpdir"
require_relative "../support/fake_executables"

# script/worktree NAME [-b BRANCH]: a worktree next to the main checkout,
# off main, with `npm ci --prefer-offline` run in it (a fake npm here).
RSpec.describe "script/worktree" do
  let(:script) { File.expand_path("../../script/worktree", __dir__) }
  let(:tmp) { File.realpath(Dir.mktmpdir("worktree-script-")) }
  let(:main_checkout) { File.join(tmp, "samagotchi") }
  let(:bin) { File.join(tmp, "bin") }
  let(:npm_log) { File.join(tmp, "npm.log") }

  after { FileUtils.rm_rf(tmp) }

  def git(*args, dir: main_checkout)
    out, status = Open3.capture2e("git", "-C", dir, "-c", "user.name=x", "-c", "user.email=x@x", *args)
    raise out unless status.success?

    out
  end

  before do
    FileUtils.mkdir_p(File.join(main_checkout, "script"))
    git("init", "-q", "-b", "main")
    FakeExecutables.copy_executable(script, File.join(main_checkout, "script", "worktree"))
    git("add", ".")
    git("commit", "-q", "-m", "init")
    FileUtils.mkdir_p(bin)
    FakeExecutables.fake_executable(bin, "npm", "echo \"$PWD $*\" >> #{npm_log}")
  end

  def run_script(*args, from: main_checkout)
    env = { "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }
    Open3.capture3(env, File.join(from, "script", "worktree"), *args, stdin_data: "")
  end

  it "adds ../samagotchi-NAME off main on branch NAME, runs npm ci there, prints the path" do
    out, err, status = run_script("fix-thing")

    dir = File.join(tmp, "samagotchi-fix-thing")
    expect(status).to be_success, err
    expect(out).to eq("#{dir}\n")
    expect(git("branch", "--show-current", dir: dir).strip).to eq("fix-thing")
    expect(git("rev-parse", "HEAD", dir: dir)).to eq(git("rev-parse", "main"))
    expect(File.read(npm_log)).to eq("#{dir} ci --prefer-offline\n")
  end

  it "takes the branch from -b and works from another worktree too" do
    _, err, status = run_script("one", "-b", "feat/one")
    expect(status).to be_success, err

    out, err, status = run_script("two", "-b", "fix/two", from: File.join(tmp, "samagotchi-one"))
    expect(status).to be_success, err
    expect(out).to eq("#{File.join(tmp, "samagotchi-two")}\n")
    expect(git("branch", "--show-current", dir: File.join(tmp, "samagotchi-two")).strip).to eq("fix/two")
  end

  it "refuses an existing folder or branch, and a missing NAME" do
    FileUtils.mkdir_p(File.join(tmp, "samagotchi-taken"))
    _, err, status = run_script("taken")
    expect(status.exitstatus).to eq(1)
    expect(err).to include("samagotchi-taken already exists")

    git("branch", "feat/x")
    _, err, status = run_script("x", "-b", "feat/x")
    expect(status.exitstatus).to eq(1)
    expect(err).to include("branch feat/x already exists")
    expect(File).not_to exist(File.join(tmp, "samagotchi-x"))

    _, err, status = run_script
    expect(status.exitstatus).to eq(2)
    expect(err).to include("usage: script/worktree NAME [-b BRANCH]")
    expect(File).not_to exist(npm_log)
  end
end
