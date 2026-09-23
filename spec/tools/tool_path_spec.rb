# frozen_string_literal: true

require "samagotchi/tools/tool_path"
require "samagotchi/tools/write"
require "samagotchi/tools/read"
require "samagotchi/tools/edit"
require "tmpdir"

RSpec.describe Samagotchi::Tools::ToolPath do
  # Point HOME at a throwaway dir so `~` never resolves to the real home.
  around do |example|
    Dir.mktmpdir do |home|
      original_home = ENV["HOME"]
      ENV["HOME"] = home
      @home = home
      Dir.mktmpdir do |cwd|
        Dir.chdir(cwd) do
          @cwd = cwd
          example.run
        end
      end
    ensure
      ENV["HOME"] = original_home
    end
  end

  describe ".normalize" do
    it "expands a leading ~/" do
      expect(described_class.normalize("~/notes/a.md")).to eq(File.join(@home, "notes/a.md"))
    end

    it "expands a bare ~" do
      expect(described_class.normalize("~")).to eq(@home)
    end

    it "strips whitespace before expanding" do
      expect(described_class.normalize("  ~/a.md \n")).to eq(File.join(@home, "a.md"))
    end

    it "leaves relative paths relative" do
      expect(described_class.normalize("lib/foo.rb")).to eq("lib/foo.rb")
    end

    it "leaves a ~ that is not leading untouched" do
      expect(described_class.normalize("dir/~/x")).to eq("dir/~/x")
    end
  end

  describe "file tools" do
    it "Write creates the file under HOME, not a literal ./~ dir" do
      result = Samagotchi::Tools::Write.call("hi", path: "~/.config/app/x.md")

      expect(File.read(File.join(@home, ".config/app/x.md"))).to eq("hi")
      expect(Dir.exist?(File.join(@cwd, "~"))).to be false
      expect(result).to include(File.join(@home, ".config/app/x.md"))
    end

    it "Read reads a ~ path" do
      File.write(File.join(@home, "r.txt"), "content")

      expect(Samagotchi::Tools::Read.call("~/r.txt")).to eq("content")
    end

    it "Read reads a ~ path in range mode" do
      File.write(File.join(@home, "r.txt"), "one\ntwo\n")

      expect(Samagotchi::Tools::Read.call("~/r.txt", start_line: 2)).to eq("two\n")
    end

    it "Edit edits a ~ path" do
      path = File.join(@home, "e.txt")
      File.write(path, "old value")

      result = Samagotchi::Tools::Edit.call("<old>old</old><new>new</new>", path: "~/e.txt")

      expect(result).to start_with("Edited")
      expect(File.read(path)).to eq("new value")
    end
  end
end
