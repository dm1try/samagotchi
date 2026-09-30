# frozen_string_literal: true

require "tmpdir"
require "rbconfig"
require "samagotchi/atomic_file"

RSpec.describe Samagotchi::AtomicFile do
  around do |example|
    Dir.mktmpdir("atomic-file-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, "state.json") }

  describe ".write" do
    it "writes the content byte for byte and leaves no temporary file" do
      content = "héllo \xFF\n".b
      expect(described_class.write(path, content)).to eq(path)
      expect(File.binread(path)).to eq(content)
      expect(Dir.children(@dir)).to eq(["state.json"])
    end

    it "replaces an existing file" do
      File.write(path, "old")
      described_class.write(path, "new")
      expect(File.read(path)).to eq("new")
    end

    it "gives a new file a fresh file's mode by default, like File.write" do
      File.write(File.join(@dir, "plain"), "x")
      described_class.write(path, "x")
      expect(File.stat(path).mode & 0o777).to eq(File.stat(File.join(@dir, "plain")).mode & 0o777)
    end

    it "sets perm: exactly" do
      File.write(path, "old")
      File.chmod(0o644, path)
      described_class.write(path, "secret", perm: 0o600)
      expect(File.stat(path).mode & 0o777).to eq(0o600)
    end

    it "uses a temporary name unique per call, ending in .tmp, in the same folder" do
      names = []
      allow(File).to receive(:rename).and_wrap_original do |original, from, to|
        names << from
        original.call(from, to)
      end
      2.times { described_class.write(path, "x") }
      expect(names.uniq.size).to eq(2)
      expect(names).to all(start_with("#{path}.#{Process.pid}.").and(end_with(".tmp")))
    end

    it "removes the temporary file and keeps the old content when the rename fails" do
      File.write(path, "old")
      allow(File).to receive(:rename).and_raise(Errno::EACCES)
      expect { described_class.write(path, "new") }.to raise_error(Errno::EACCES)
      expect(File.read(path)).to eq("old")
      expect(Dir.children(@dir)).to eq(["state.json"])
    end

    it "raises when the folder is missing, creating nothing" do
      expect { described_class.write(File.join(@dir, "nope", "f"), "x") }.to raise_error(Errno::ENOENT)
    end
  end

  describe "concurrent writers" do
    # Every read sees one writer's whole content: never missing, never torn.
    def assert_readers_see_whole_files(contents)
      File.write(path, contents.first)
      reads = 0
      bad = []
      stop = false
      reader = Thread.new do
        until stop
          data = File.binread(path)
          reads += 1
          bad << data.bytesize unless contents.include?(data)
        end
      end
      yield
      stop = true
      reader.join
      expect(reads).to be > 0
      expect(bad).to be_empty
      expect(contents).to include(File.binread(path))
      expect(Dir.children(@dir)).to eq(["state.json"])
    end

    it "keeps the file whole with two threads writing the same path" do
      contents = %w[a b].map { |c| c * 200_000 }
      assert_readers_see_whole_files(contents) do
        contents.map { |c| Thread.new { 50.times { described_class.write(path, c) } } }.each(&:join)
      end
    end

    it "keeps the file whole with two processes writing the same path" do
      contents = %w[a b].map { |c| c * 200_000 }
      lib = File.expand_path("../lib", __dir__)
      script = <<~RUBY
        require "samagotchi/atomic_file"
        100.times { Samagotchi::AtomicFile.write(ARGV[0], ARGV[1] * 200_000) }
      RUBY
      assert_readers_see_whole_files(contents) do
        pids = %w[a b].map { |c| Process.spawn(RbConfig.ruby, "-I", lib, "-e", script, path, c, in: File::NULL) }
        statuses = pids.map { |pid| Process.wait2(pid).last }
        expect(statuses).to all(be_success)
      end
    end
  end
end
