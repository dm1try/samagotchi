# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/child_move"
require "samagotchi/session_manager"

# ChildMove: a continue moving the previous link's open delegates to the
# new link (spec/session_continue_spec.rb has the continue's side).
RSpec.describe Samagotchi::ChildMove do
  let(:tmpdir) { Dir.mktmpdir("child-move") }
  let(:from) { make }
  let(:to) { make }

  after { FileUtils.rm_rf(tmpdir) }

  def make(parent_id: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: "/w", parent_id: parent_id,
                                    delegate: !parent_id.nil?).tap { |s| s.save(state_dir: tmpdir) }
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: tmpdir)
  def cursors(id) = Samagotchi::Tools::DelegateCursors.read(id, state_dir: tmpdir)
  def parent_of(id) = Samagotchi::Session.load(id, state_dir: tmpdir).parent_id
  def rings(id) = Samagotchi::SessionInbox.find_ring_files(dir_of(id))

  def cursor!(parent, child, reply)
    Samagotchi::Tools::DelegateCursors.update(parent.id, child.id, state_dir: tmpdir) { |c| c.with(reply_file: reply) }
  end

  describe ".apply" do
    it "is safe to run twice, and keeps a cursor the new link already has" do
      child = make(parent_id: from.id)
      other = make(parent_id: from.id)
      cursor!(from, child, "1.txt")
      cursor!(from, other, "2.txt")
      cursor!(to, child, "9.txt")
      Samagotchi::SessionInbox.write_ring(dir_of(from.id), child_id: child.id, why: "turn_end")
      Samagotchi::SessionInbox.write_ring(dir_of(from.id), child_id: other.id, why: "turn_end")

      2.times { described_class.apply([child.id], from: from.id, to: to.id, state_dir: tmpdir) }

      expect(parent_of(child.id)).to eq(to.id)
      expect(parent_of(other.id)).to eq(from.id)
      expect(cursors(to.id)).to eq(child.id => { "reply_file" => "9.txt" })
      expect(rings(to.id).map { |f| Samagotchi::SessionInbox.read_ring(f)[:child_id] }).to eq([child.id])
      expect(rings(from.id).map { |f| Samagotchi::SessionInbox.read_ring(f)[:child_id] }).to eq([other.id])
      expect(described_class.read_intent(to.id, state_dir: tmpdir)).to be_nil
    end
  end

  describe ".plan" do
    it "refuses an open delegate under an archived one: the archive would take it, the move wouldn't" do
      archived = make(parent_id: from.id)
      open = make(parent_id: archived.id)
      Samagotchi::ArchiveStore.archive(archived.id, state_dir: tmpdir)
      Samagotchi::SessionInbox.write_output(dir_of(open.id), "done")

      plan = described_class.plan(from.id, open: Samagotchi::SessionManager.open_children(from.id, tmpdir), state_dir: tmpdir)

      expect(plan.move).to eq([])
      expect(plan.refuse.map { |c| [c.id, c.why] })
        .to eq([[open.id, "under archived #{archived.id[0, 8]}; unarchive that one or archive this one"]])
    end
  end

  describe ".adopt" do
    it "finishes the move its intent names, and only those children: never one the user unarchived" do
      moving = make(parent_id: from.id)
      lone = make(parent_id: from.id)
      Samagotchi::ArchiveStore.archive(from.id, state_dir: tmpdir)
      described_class.write_intent(to.id, described_class::Intent.new(from: from.id, ids: [moving.id]), state_dir: tmpdir)

      expect(described_class.adopt(to.id, state_dir: tmpdir)).to eq([moving.id])

      expect([parent_of(moving.id), parent_of(lone.id)]).to eq([to.id, from.id])
      expect(described_class.read_intent(to.id, state_dir: tmpdir)).to be_nil
      expect(described_class.adopt(to.id, state_dir: tmpdir)).to eq([])
    end

    it "notes each child once: a worker finishing a move that died after its notes writes none again" do
      noted = make(parent_id: from.id)
      later = make(parent_id: from.id)
      allow(Samagotchi::SessionInbox).to receive(:write_note).and_call_original
      allow(Samagotchi::SessionInbox).to receive(:write_note).with(later.id, any_args).and_raise(IOError, "died")
      expect { described_class.apply([noted.id, later.id], from: from.id, to: to.id, state_dir: tmpdir) }
        .to raise_error(IOError)
      allow(Samagotchi::SessionInbox).to receive(:write_note).and_call_original

      expect(described_class.adopt(to.id, state_dir: tmpdir)).to eq([noted.id, later.id])

      notes = ->(id) { Dir.glob(File.join(dir_of(id), Samagotchi::SessionInbox::NOTES_DIR, "*")).size }
      expect([notes.call(noted.id), notes.call(later.id)]).to eq([1, 1])
      expect(described_class.read_intent(to.id, state_dir: tmpdir)).to be_nil
    end

    it "is run by a starting worker before it loads its session, which clears the starting marker first" do
      moving = make(parent_id: from.id)
      described_class.mark_starting(to.id, state_dir: tmpdir)
      described_class.write_intent(to.id, described_class::Intent.new(from: from.id, ids: [moving.id]), state_dir: tmpdir)
      worker = Samagotchi::Worker.new(session_id: to.id, state_dir: tmpdir, session_dir: dir_of(to.id), idle_exit_minutes: 0)
      allow(Samagotchi::Session).to receive(:load).and_call_original
      allow(Samagotchi::Session).to receive(:load).with(to.id, state_dir: tmpdir) do
        raise "adopted first" unless parent_of(moving.id) == to.id
        raise "marker cleared" if described_class.starting?(to.id, state_dir: tmpdir)

        raise IOError, "stop here"
      end

      expect { worker.send(:start) }.to raise_error(IOError, "stop here")
    end
  end

  describe ".starting?" do
    it "holds while the marker is fresh and its process runs; a stale or dead one holds nothing" do
      expect(described_class.starting?(to.id, state_dir: tmpdir)).to be(false)
      described_class.mark_starting(to.id, state_dir: tmpdir)
      expect(described_class.starting?(to.id, state_dir: tmpdir)).to be(true)

      file = File.join(dir_of(to.id), "starting")
      File.write(file, JSON.generate(pid: Process.pid, at: (Time.now - 120).iso8601(3)))
      expect(described_class.starting?(to.id, state_dir: tmpdir)).to be(false)

      dead = Process.spawn(RbConfig.ruby, "-e", "0")
      Process.wait(dead)
      File.write(file, JSON.generate(pid: dead, at: Time.now.iso8601(3)))
      expect(described_class.starting?(to.id, state_dir: tmpdir)).to be(false)

      described_class.mark_starting(to.id, state_dir: tmpdir)
      described_class.clear_starting(to.id, state_dir: tmpdir)
      expect(described_class.starting?(to.id, state_dir: tmpdir)).to be(false)
    end

    it "keeps wake_for_report and resume_session from spawning the link's worker" do
      allow(Process).to receive(:spawn).and_return(12_345)
      described_class.mark_starting(to.id, state_dir: tmpdir)

      expect(Samagotchi::SessionManager.wake_for_report(to.id, state_dir: tmpdir)).to eq(:starting)
      Samagotchi::SessionManager.resume_session(to.id, state_dir: tmpdir)

      expect(Process).not_to have_received(:spawn)
    end
  end
end
