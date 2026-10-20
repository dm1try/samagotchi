# frozen_string_literal: true

require "fileutils"
require "open3"
require "stringio"
require "tmpdir"
require_relative "../../script/affected_specs/cli"

# script/affected-specs on a temp git repo: the default range (merge-base
# with main, uncommitted and untracked files), A..B, --why, --cap.
RSpec.describe AffectedSpecs::CLI do
  let(:repo) { File.realpath(Dir.mktmpdir("affected-specs-")) }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after { FileUtils.rm_rf(repo) }

  def git(*args)
    output, status = Open3.capture2e("git", "-C", repo, "-c", "user.name=x", "-c", "user.email=x@x", *args)
    raise output unless status.success?

    output
  end

  def write(path, text = "")
    FileUtils.mkdir_p(File.join(repo, File.dirname(path)))
    File.write(File.join(repo, path), text)
  end

  def commit(message)
    git("add", "-A")
    git("commit", "-q", "-m", message)
    git("rev-parse", "HEAD").strip
  end

  # A fresh stdout and stderr per run.
  def run_cli(*args)
    stdout = StringIO.new
    stderr = StringIO.new
    [described_class.new(args, out: stdout, err: stderr, dir: repo).run, stdout.string, stderr.string]
  end

  before do
    git("init", "-q", "-b", "main")
    write("lib/samagotchi/widget.rb", "module Samagotchi\n  class Widget\n  end\nend\n")
    write("lib/samagotchi/gadget.rb", "module Samagotchi\n  class Gadget\n  end\nend\n")
    write("spec/widget_spec.rb", "Samagotchi::Widget")
    write("spec/gadget_spec.rb", "Samagotchi::Gadget")
    write("spec/uses_widget_spec.rb", "Widget.new")
    write("spec/web/public/panel.test.js")
    @base = commit("init")
    git("checkout", "-q", "-b", "feat")
  end

  it "prints nothing and exits 0 when nothing changed" do
    expect(run_cli).to eq([0, "", ""])
  end

  it "takes the branch's commits, uncommitted and untracked files by default" do
    write("lib/samagotchi/widget.rb", "module Samagotchi\n  class Widget\n    def x = 1\n  end\nend\n")
    commit("widget")
    write("spec/gadget_spec.rb", "Samagotchi::Gadget # edited")
    write("spec/new_spec.rb")

    expect(run_cli).to eq([0, "spec/gadget_spec.rb\nspec/new_spec.rb\nspec/widget_spec.rb\nspec/uses_widget_spec.rb\n", ""])
  end

  it "takes A..B and prints reasons, node tests and the web hint with --why" do
    write("lib/samagotchi/web/public/panel.js")
    write("lib/samagotchi/gadget.rb", "module Samagotchi\n  class Gadget\n    def y = 2\n  end\nend\n")
    head = commit("web")
    write("lib/samagotchi/widget.rb", "# uncommitted, not in the range")

    status, stdout, stderr = run_cli("#{@base}..#{head}", "--why")

    expect(status).to eq(0)
    expect(stdout).to eq("spec/gadget_spec.rb  # named after lib/samagotchi/gadget.rb\n")
    expect(stderr).to eq(<<~TEXT)
      npm: spec/web/public/panel.test.js  # named after lib/samagotchi/web/public/panel.js
      affected-specs: web frontend changed: also run npm run lint and npm run e2e before handing over
    TEXT
  end

  it "caps the list and says how many more there are" do
    write("spec/widget_spec.rb", "edited")
    write("spec/gadget_spec.rb", "edited")

    expect(run_cli("--cap", "1")).to eq([0, "spec/gadget_spec.rb\n", "affected-specs: 1 more (--all lists them)\n"])
  end

  it "refuses a bad revision" do
    status, stdout, stderr = run_cli("nope..HEAD")

    expect([status, stdout, stderr]).to eq([2, "", "affected-specs: bad range nope..HEAD\n"])
  end

  it "falls back to origin/main, then to the uncommitted changes alone, saying so" do
    write("spec/widget_spec.rb", "edited")
    commit("widget spec")
    write("spec/gadget_spec.rb", "edited")
    git("branch", "-m", "main", "trunk")

    expect(run_cli).to eq([0, "spec/gadget_spec.rb\n", "affected-specs: no main or origin/main; only uncommitted changes\n"])

    git("update-ref", "refs/remotes/origin/main", @base)
    expect(run_cli).to eq([0, "spec/gadget_spec.rb\nspec/widget_spec.rb\n", ""])
  end

  it "compares a single REV with the working tree" do
    write("spec/widget_spec.rb", "edited")
    middle = commit("widget spec")
    write("spec/gadget_spec.rb", "edited")

    expect(run_cli(middle)).to eq([0, "spec/gadget_spec.rb\n", ""])
    expect(run_cli(@base)).to eq([0, "spec/gadget_spec.rb\nspec/widget_spec.rb\n", ""])
  end

  it "takes A...B from their merge-base" do
    write("spec/widget_spec.rb", "edited")
    head = commit("feat")
    git("checkout", "-q", "main")
    write("spec/gadget_spec.rb", "edited on main")
    commit("main moves on")
    git("checkout", "-q", "feat")

    expect(run_cli("main...#{head}")).to eq([0, "spec/widget_spec.rb\n", ""])
  end

  it "skips a pick this checkout doesn't have" do
    write("spec/later_spec.rb")
    later = commit("later")
    git("checkout", "-q", @base)

    expect(run_cli("#{@base}..#{later}")).to eq([0, "", "affected-specs: not in this checkout, skipped: spec/later_spec.rb\n"])
  end

  it "runs nothing with --run when nothing is picked" do
    cli = described_class.new(["--run"], out: out, err: err, dir: repo)
    allow(cli).to receive(:system)

    expect(cli.run).to eq(0)
    expect(cli).not_to have_received(:system)
  end

  it "refuses a negative --cap" do
    status, stdout, stderr = run_cli("--cap", "-1")

    expect([status, stdout]).to eq([2, ""])
    expect(stderr).to start_with("affected-specs: invalid argument: --cap -1\nusage:")
  end

  it "runs as script/affected-specs without Bundler, from a subfolder" do
    write("spec/widget_spec.rb", "edited")
    script = File.expand_path("../../script/affected-specs", __dir__)
    env = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil }

    stdout, stderr, status = Open3.capture3(env, script, chdir: File.join(repo, "lib"))

    expect([stdout, stderr, status.exitstatus]).to eq(["spec/widget_spec.rb\n", "", 0])
  end
end
