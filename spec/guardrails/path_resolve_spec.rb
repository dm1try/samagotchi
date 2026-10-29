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
      # folds_case? takes an absolute path only (a relative one never
      # reaches "/").
      names = path.start_with?("/") ? %i[expand real lexical_real reals folds_case?] : %i[expand real lexical_real reals]
      names.each do |name|
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

  it "resolves the root for .within?: a path in a symlinked root's target is within it" do
    expect(described_class.within?(File.join(root, "elsewhere", "deep", "a"), File.join(root, "link"))).to be(true)
    expect(described_class.within?(File.join(root, "a"), nil)).to be(false)
    expect(described_class.within?(File.join(root, "a"), "")).to be(false)
  end
end
