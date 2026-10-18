# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

# `chi bundle new`, as an installed chi runs it (ruby -I lib bin/chi, in a
# folder outside the repo): what it writes checks clean and its test passes.
RSpec.describe "chi bundle new" do
  let(:root) { File.expand_path("../../..", __dir__) }
  let(:tmp) { File.realpath(Dir.mktmpdir("bundle-new-")) }

  after { FileUtils.rm_rf(tmp) }

  def chi(*args, chdir: tmp)
    env = { "HOME" => tmp, "XDG_CONFIG_HOME" => "#{tmp}/.config", "XDG_STATE_HOME" => "#{tmp}/.state",
            "XDG_DATA_HOME" => "#{tmp}/.data", "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil }
    Open3.capture3(env, RbConfig.ruby, "-I", "#{root}/lib", "#{root}/bin/chi", "bundle", *args, chdir: chdir)
  end

  it "writes a bundle that checks with no errors or warnings, and whose test passes as written" do
    out, err, status = chi("new", "todo-list")
    expect([err, status.exitstatus]).to eq(["", 0])
    expect(out).to start_with("Created todo-list/: manifest.yml, plugin.rb, test/todo_list_test.rb, README.md\n")
    dir = File.join(tmp, "todo-list")
    manifest = File.read(File.join(dir, "manifest.yml"))
    expect(manifest).to match(/^plugin:\n  file: plugin.rb\n  sha256: sha256:\h{64}\n/)
    expect(manifest).to include("requires_chi: \">= #{Samagotchi::VERSION}\"")

    out, _err, status = chi("check", chdir: dir)
    expect(out.lines.grep(/\A(error|warn) /)).to eq([])
    expect(out).to include("info registered plugin.rb: command /todo-list\n")
    expect(status.exitstatus).to eq(0)

    test_out, test_status = Open3.capture2e({ "BUNDLE_GEMFILE" => nil, "RUBYOPT" => nil, "HOME" => tmp },
                                            RbConfig.ruby, "-I", "#{root}/lib", "test/todo_list_test.rb", chdir: dir)
    expect(test_out).to include("2 runs, 3 assertions, 0 failures, 0 errors")
    expect(test_status.exitstatus).to eq(0)
  end

  it "writes into --dir, and refuses a folder that exists and a name that isn't a command name" do
    expect(chi("new", "x", "--dir", "sub").last.exitstatus).to eq(0)
    expect(File).to exist(File.join(tmp, "sub", "x", "plugin.rb"))

    _out, err, status = chi("new", "x", "--dir", "sub")
    expect([err, status.exitstatus]).to eq(["chi bundle new: #{tmp}/sub/x exists already\n", 1])

    _out, err, status = chi("new", "My_Bundle")
    expect(err).to start_with("chi bundle new: \"My_Bundle\" isn't a bundle name")
    expect(status.exitstatus).to eq(1)
    expect(chi("new").last.exitstatus).to eq(2)
  end
end
