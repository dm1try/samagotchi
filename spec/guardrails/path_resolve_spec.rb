# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "samagotchi/guardrails/path_resolve"
require "samagotchi/guardrails/protected_paths"

# The shared path primitives. Their answers through every surface are
# pinned in path_consistency_spec.rb and protected_paths_spec.rb; this
# covers the module's own contract.
RSpec.describe Samagotchi::Guardrails::PathResolve do
  let(:root) { File.realpath(Dir.mktmpdir("path-resolve")) }
  let(:folds) { File.exist?(root.swapcase) }

  before do
    FileUtils.mkdir_p([File.join(root, "elsewhere", "deep"), File.join(root, "dir")])
    File.symlink(File.join(root, "elsewhere", "deep"), File.join(root, "link"))
    File.symlink(File.join(root, "elsewhere", "made.txt"), File.join(root, "dangling"))
  end

  after { FileUtils.rm_rf(root) }

  it "answers as ProtectedPaths' old names do (they delegate here)" do
    paths = %W[#{root}/link/../x #{root}/dangling #{root}/dir/new.rb ~/x/../y #{root}/DIR/a]
    paths.each do |path|
      %i[expand real lexical_real reals folds_case?].each do |name|
        expect(Samagotchi::Guardrails::ProtectedPaths.public_send(name, path)).to eq(described_class.public_send(name, path)), "#{name} #{path}"
      end
      expect(Samagotchi::Guardrails::ProtectedPaths.within?(path, root)).to eq(described_class.within?(path, root)), path
    end
  end

  it "takes `..` the kernel's way and follows a dangling symlink, keeping both answers in .reals" do
    expect(described_class.expand("#{root}/link/../x")).to eq(File.join(root, "elsewhere", "x"))
    expect(described_class.real("#{root}/dangling")).to eq(File.join(root, "elsewhere", "made.txt"))
    expect(described_class.reals("#{root}/dangling")).to eq([File.join(root, "dangling"), File.join(root, "elsewhere", "made.txt")])
  end

  it "says a path is under a dir by its text, cased alike only on a disk that folds case" do
    expect(described_class.under?(File.join(root, "dir", "a"), File.join(root, "dir"))).to be(true)
    expect(described_class.under?(File.join(root, "dir"), File.join(root, "dir"))).to be(true)
    expect(described_class.under?(File.join(root, "dirx"), File.join(root, "dir"))).to be(false)
    expect(described_class.under?(File.join(root, "DIR", "a"), File.join(root, "dir"))).to eq(folds)
  end

  it "answers folds_case? false for a relative or blank path (no disk to ask)" do
    expect(described_class.folds_case?("nope")).to be(false)
    expect(described_class.folds_case?("")).to be(false)
    expect(described_class.folds_case?("~/x/../y")).to be(false)
  end

  it "compares by text alone with fold: false, and strictly_under? leaves the dir itself out" do
    dir = File.join(root, "dir")
    expect(described_class.under?(File.join(root, "DIR", "a"), dir, fold: false)).to be(false)
    expect(described_class.under?(dir, dir, fold: false)).to be(true)
    expect(described_class.strictly_under?(dir, dir)).to be(false)
    expect(described_class.strictly_under?(File.join(dir, "a"), dir, fold: false)).to be(true)
    expect(described_class.strictly_under?(File.join(root, "DIR", "a"), dir)).to eq(folds)
    expect(described_class.strictly_under?(File.join(root, "DIR", "a"), dir, fold: false)).to be(false)
    expect(described_class.strictly_under?(File.join(root, "DIR"), dir)).to be(false)
  end

  it "lists the tmp dirs that exist, resolved, and with a session only those it isn't in, in exact case" do
    roots = described_class.tmp_roots
    expect(roots).to include(File.realpath(Dir.tmpdir), File.realpath("/tmp"))
    tmp = File.realpath("/tmp")
    expect(described_class.tmp_roots(session: File.join(tmp, "sess"))).not_to include(tmp)
    expect(described_class.tmp_roots(session: File.join(tmp.swapcase, "sess"))).to include(tmp)
    expect(described_class.tmp_roots(session: "/elsewhere/x", roots: %w[/a /b])).to eq(%w[/a /b])
    expect(described_class.tmp_roots(session: "/a/x", roots: %w[/a /b])).to eq(%w[/b])
  end

  it "expands a shell word's leading ~, $HOME, ${HOME}, an XDG dir (its default when unset) and $TMPDIR" do
    env = { "XDG_STATE_HOME" => "/st", "TMPDIR" => "/t" }
    expect(described_class.expand_word("~/a", home: "/h", env: env)).to eq("/h/a")
    expect(described_class.expand_word("${HOME}/a", home: "/h", env: env)).to eq("/h/a")
    expect(described_class.expand_word("$XDG_STATE_HOME/a", home: "/h", env: env)).to eq("/st/a")
    expect(described_class.expand_word("$XDG_CONFIG_HOME/a", home: "/h", env: env)).to eq("/h/.config/a")
    expect(described_class.expand_word("$TMPDIR/a", home: "/h", env: env)).to eq("/t/a")
    expect(described_class.expand_word("$OTHER/a", home: "/h", env: env)).to be_nil
    expect(described_class.expand_word("~user/a", home: "/h", env: env)).to be_nil
    expect(Samagotchi::Guardrails::ShellPaths.expand_word("~/a", home: "/h", env: env)).to eq("/h/a")
  end

  it "resolves the root for .within?: a path in a symlinked root's target is within it" do
    expect(described_class.within?(File.join(root, "elsewhere", "deep", "a"), File.join(root, "link"))).to be(true)
    expect(described_class.within?(File.join(root, "a"), nil)).to be(false)
    expect(described_class.within?(File.join(root, "a"), "")).to be(false)
  end
end
