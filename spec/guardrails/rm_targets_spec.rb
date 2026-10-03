# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails/rm_targets"

# Whether an rm -rf reaches outside the tmp dirs (rm-rf-wide's rm: outside_tmp).
RSpec.describe Samagotchi::Guardrails::RmTargets do
  let(:root) { File.realpath(Dir.mktmpdir("rm-targets")) }
  let(:tmp) { File.join(root, "tmp").tap { |d| FileUtils.mkdir_p(d) } }
  let(:home) { File.join(root, "home").tap { |d| FileUtils.mkdir_p(d) } }
  let(:repo) { File.join(root, "repo").tap { |d| FileUtils.mkdir_p(d) } }

  after { FileUtils.rm_rf(root) }

  def outside?(command, session_root: repo, cwd: repo)
    described_class.outside_tmp?(command.gsub("@T", tmp), cwd: cwd, tmp_roots: [tmp], session_root: session_root,
                                                          home: home, env: { "TMPDIR" => tmp })
  end

  inside = [
    "rm -rf @T/x", "rm -rf $TMPDIR/x", "rm -rf ${TMPDIR}/x", "rm -rf @T/pp/state3 && mkdir -p @T/pp/state3",
    "rm -fr @T/a @T/b", "rm --recursive --force -- @T/x", "rm -rf @T/x 2>/dev/null", "rm -rf @T/x > /dev/null 2>&1",
    "cd @T && rm -rf x", "rm -f /etc/one-file", "rm -r ~/no-force", "rm -rf @T/x/../y", "ls ~ && rm -rf @T/x",
    "rm-tool -rf /"
  ]

  outside = [
    "rm -rf /", "rm -rf ~", "rm -rf ..", "rm -rf @T", "rm -rf @T/", "rm -rf @T/*", "rm -rf @T/../etc",
    "rm -rf $HOME/x", "rm -rf $X/y", "rm -rf @T/x ~/y", "rm -rf @T/x && rm -rf ~", "rm -rf @T/x; rm -rf ..",
    "sudo rm -rf @T/x", "xargs rm -rf < list", "/bin/rm -rf @T/x", "sh -c 'rm -rf @T/x'", "echo $(rm -rf ~)",
    "rm -rf `echo @T`", "rm -rf x", "cd $X && rm -rf y", "rm -rf"
  ]

  inside.each do |command|
    it "stays inside: #{command}" do
      expect(outside?(command)).to be(false)
    end
  end

  outside.each do |command|
    it "reaches outside: #{command}" do
      expect(outside?(command)).to be(true)
    end
  end

  it "follows a symlink out of the tmp dir" do
    File.symlink("/", File.join(tmp, "root-link"))
    File.symlink(home, File.join(tmp, "home-link"))
    expect(outside?("rm -rf @T/root-link")).to be(true)
    expect(outside?("rm -rf @T/home-link/x")).to be(true)
  end

  it "doesn't exempt the tmp dir the session's root is in" do
    session = File.join(tmp, "sandbox").tap { |d| FileUtils.mkdir_p(d) }
    expect(outside?("rm -rf @T/sibling", session_root: session, cwd: session)).to be(true)
  end
end
