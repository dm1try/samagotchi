# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/chi_shim"

RSpec.describe Samagotchi::ChiShim do
  let(:tmp) { Dir.mktmpdir("chi-shim") }
  let(:dir) { File.join(tmp, "bin") }
  let(:home) do
    Samagotchi::ChiHome::Record.new(ruby: "/home ruby/bin/ruby", gem_home: "/g h", gem_path: "/g h:/other's",
                                    mise: nil, set_at: "t", set_by_version: "1")
  end

  after { FileUtils.remove_entry(tmp) }

  it "lives in the state dir's bin" do
    expect(described_class.dir(env: { "XDG_STATE_HOME" => "/s" })).to eq("/s/samagotchi/bin")
  end

  it "execs the home's boot with the arguments it was given" do
    expect(described_class.ensure!(home, dir: dir)).to be(true)
    file = File.join(dir, "chi")
    expect(File.stat(file).mode & 0o777).to eq(0o755)
    expect(File.read(file)).to start_with("#!/bin/sh\n")
    argv = Shellwords.split(File.read(file).lines.last.delete_prefix("exec ").sub(/ "\$@"\n\z/, ""))
    expect(argv).to eq(home.boot_argv(run: Samagotchi::ChiHome::CHI_BOOT) + ["--"])
  end

  it "runs: the boot sees the arguments after --" do
    ruby = RbConfig.ruby
    record = home.with(ruby: ruby, gem_home: Gem.dir, gem_path: Gem.path.join(File::PATH_SEPARATOR))
    stub_const("Samagotchi::ChiHome::CHI_BOOT", "puts ARGV.inspect")
    described_class.ensure!(record, dir: dir)
    output = IO.popen([File.join(dir, "chi"), "send", "a b", "$HOME"], &:read)
    expect(output.strip).to eq(["send", "a b", "$HOME"].inspect)
  end

  it "runs the home's chi without the project's RUBYOPT, RUBYLIB, BUNDLE_* and LD_*" do
    record = home.with(ruby: RbConfig.ruby, gem_home: Gem.dir, gem_path: Gem.path.join(File::PATH_SEPARATOR))
    stub_const("Samagotchi::ChiHome::CHI_BOOT", "p ENV.keys.grep(/\\A(RUBYOPT|RUBYLIB|RUBYGEMS_GEMDEPS|GEMRC|BUNDLE|LD_PRELOAD|LD_LIBRARY_PATH)/).sort")
    described_class.ensure!(record, dir: dir)
    env = { "RUBYOPT" => "-rbundler/setup", "RUBYLIB" => "/p/lib", "BUNDLE_GEMFILE" => "/p/Gemfile",
            "BUNDLE_BIN_PATH" => "/b", "BUNDLER_VERSION" => "2.6.0", "RUBYGEMS_GEMDEPS" => "-", "GEMRC" => "/p/gemrc",
            "LD_PRELOAD" => "/p/x.so", "LD_LIBRARY_PATH" => "/p/lib", "KEEP" => "1" }
    output = IO.popen(env, [File.join(dir, "chi")], &:read)
    expect(output.strip).to eq("[]")
  end

  it "is rewritten when the home changed, left alone when current" do
    described_class.ensure!(home, dir: dir)
    file = File.join(dir, "chi")
    mtime = File.mtime(file)
    File.utime(mtime - 60, mtime - 60, file)
    described_class.ensure!(home, dir: dir)
    expect(File.mtime(file)).to eq(mtime - 60)
    described_class.ensure!(home.with(ruby: "/new/bin/ruby"), dir: dir)
    expect(File.read(file)).to include("/new/bin/ruby")
    expect(Dir.children(dir)).to eq(["chi"])
  end

  it "says false and warns when it can't be written" do
    allow(Samagotchi::Log).to receive(:warn)
    File.write(File.join(tmp, "file"), "")
    expect(described_class.ensure!(home, dir: File.join(tmp, "file", "bin"))).to be(false)
    expect(Samagotchi::Log).to have_received(:warn).with(:worker, "chi_shim_failed", hash_including(path: anything))
  end
end
