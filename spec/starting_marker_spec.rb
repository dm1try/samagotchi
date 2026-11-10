# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/starting_marker"

# StartingMarker: a continue's new link held off from any worker but its
# own (spec/child_move_spec.rb has the spawns it keeps back).
RSpec.describe Samagotchi::StartingMarker do
  let(:tmpdir) { Dir.mktmpdir("starting-marker") }
  let(:to) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w").tap { |s| s.save(state_dir: tmpdir) } }

  after { FileUtils.rm_rf(tmpdir) }

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: tmpdir)

  # Two starters at once (chi web and a `chi send`, a child's ring): one
  # claims the start, the other sees it taken.
  describe ".claim" do
    it "takes a start no one holds, once; a stale or dead one is taken over" do
      expect(described_class.claim(to.id, state_dir: tmpdir)).to be(true)
      expect(described_class.claim(to.id, state_dir: tmpdir)).to be(false)
      expect(described_class.fresh?(to.id, state_dir: tmpdir)).to be(true)

      dead = Process.spawn(RbConfig.ruby, "-e", "0")
      Process.wait(dead)
      described_class.mark(to.id, state_dir: tmpdir, pid: dead)
      expect(described_class.claim(to.id, state_dir: tmpdir)).to be(true)
      expect(JSON.parse(File.read(File.join(dir_of(to.id), "starting")))).to include("pid" => Process.pid)
      expect(Dir.children(dir_of(to.id)).grep(/starting\./)).to be_empty
    end

    it "takes over a fresh start from before +over_before+ (a stop), not one from after it" do
      described_class.mark(to.id, state_dir: tmpdir)
      at = Time.iso8601(JSON.parse(File.read(File.join(dir_of(to.id), "starting")))["at"])

      expect(described_class.claim(to.id, state_dir: tmpdir, over_before: at - 1)).to be(false)
      expect(described_class.claim(to.id, state_dir: tmpdir, over_before: at)).to be(true)
      expect(described_class.claim(to.id, state_dir: tmpdir, over_before: at)).to be(false)
    end

    # A pid the system won't probe: EPERM is a running process (another
    # user's, a reused pid), any other error holds nothing; neither raises.
    it "reads a pid it can't probe without raising" do
      described_class.mark(to.id, state_dir: tmpdir)
      allow(Process).to receive(:kill).and_raise(Errno::EPERM)
      expect(described_class.claim(to.id, state_dir: tmpdir)).to be(false)

      allow(Process).to receive(:kill).and_raise(Errno::EINVAL)
      expect(described_class.fresh?(to.id, state_dir: tmpdir)).to be(false)
      expect(described_class.claim(to.id, state_dir: tmpdir)).to be(true)
    end

    it "lets one of many racing claimers win" do
      results = Array.new(8) { Thread.new { described_class.claim(to.id, state_dir: tmpdir) } }.map(&:value)

      expect(results.count(true)).to eq(1)
    end
  end

  describe ".fresh?" do
    it "holds while the marker is fresh and its process runs; a stale or dead one holds nothing" do
      expect(described_class.fresh?(to.id, state_dir: tmpdir)).to be(false)
      described_class.mark(to.id, state_dir: tmpdir)
      expect(described_class.fresh?(to.id, state_dir: tmpdir)).to be(true)

      file = File.join(dir_of(to.id), "starting")
      File.write(file, JSON.generate(pid: Process.pid, at: (Time.now - 120).iso8601(3)))
      expect(described_class.fresh?(to.id, state_dir: tmpdir)).to be(false)

      dead = Process.spawn(RbConfig.ruby, "-e", "0")
      Process.wait(dead)
      File.write(file, JSON.generate(pid: dead, at: Time.now.iso8601(3)))
      expect(described_class.fresh?(to.id, state_dir: tmpdir)).to be(false)

      described_class.mark(to.id, state_dir: tmpdir)
      described_class.clear(to.id, state_dir: tmpdir)
      expect(described_class.fresh?(to.id, state_dir: tmpdir)).to be(false)
    end
  end
end
