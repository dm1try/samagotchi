# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

require "samagotchi/web/start_dir"

# chi web's start folder (web.start_dir, --start-dir): an absolute folder.
RSpec.describe Samagotchi::Web::StartDir do
  around do |example|
    Dir.mktmpdir("start-dir") do |tmp|
      @tmp = File.realpath(tmp)
      example.run
    end
  end

  it "is the cwd when none is given" do
    expect(described_class.resolve(nil, cwd: @tmp)).to eq(@tmp)
    expect(described_class.resolve("  ", cwd: @tmp)).to eq(@tmp)
  end

  it "expands ~ and a relative folder against the cwd" do
    FileUtils.mkdir_p(File.join(@tmp, "proj"))
    expect(described_class.resolve("proj", cwd: @tmp)).to eq(File.join(@tmp, "proj"))
    expect(described_class.resolve("~", cwd: @tmp)).to eq(Dir.home)
  end

  it "refuses a folder that doesn't exist, and a file" do
    File.write(File.join(@tmp, "f"), "")
    expect { described_class.resolve(File.join(@tmp, "gone")) }
      .to raise_error(described_class::Invalid, "--start-dir #{@tmp}/gone: no such folder")
    expect { described_class.resolve("f", cwd: @tmp) }.to raise_error(described_class::Invalid, "--start-dir f: not a folder")
  end
end
