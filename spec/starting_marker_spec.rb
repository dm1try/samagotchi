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
