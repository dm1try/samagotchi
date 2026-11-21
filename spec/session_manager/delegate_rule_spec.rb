# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_manager"

# D7: what a user's delete does with a session's delegates.
RSpec.describe Samagotchi::SessionManager::DelegateRule do
  let(:manager) { Samagotchi::SessionManager }
  let(:tmpdir) { Dir.mktmpdir("delegate-rule") }
  let(:folder) { Dir.mktmpdir("delegate-rule-folder") }
  let(:locks) { [] }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
    FileUtils.rm_rf(folder)
  end

  def make(parent: nil, status: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: folder,
                                    parent_id: parent&.id, delegate: !parent.nil?).tap do |s|
      s.first_preview = "p"
      s.messages = [{ role: "user", content: "p" }, { role: "assistant", content: "ok" }]
      s.status = status if status
      s.save(state_dir: tmpdir)
    end
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: tmpdir)
  def own(id) = locks << Samagotchi::OwnerLock.acquire(dir_of(id), kind: "worker")

  it "is the one rule, frozen" do
    expect(manager::DELEGATES).to be_a(described_class).and be_frozen
  end

  it "leaves a running delegate with its whole subtree, deletes the rest deepest first" do
    link = make
    running = make(parent: link)
    own(running.id)
    stopped_under_running = make(parent: running)
    stopped = make(parent: link)
    grandchild = make(parent: stopped)

    plan = manager::DELEGATES.plan(link.id, state_dir: tmpdir)

    expect(plan.leave).to contain_exactly(running.id, stopped_under_running.id)
    expect(plan.delete).to eq([grandchild.id, stopped.id])
  end

  it "deletes a crashed run (saved running, no worker) and an archived delegate" do
    link = make
    crashed = make(parent: link, status: "running")
    archived = make(parent: link)
    Samagotchi::ArchiveStore.archive(archived.id, state_dir: tmpdir)

    plan = manager::DELEGATES.plan(link.id, state_dir: tmpdir)

    expect(plan.delete).to contain_exactly(crashed.id, archived.id)
    expect(plan.leave).to eq([])
  end

  it "leaves out the children named in except, with their subtrees" do
    link = make
    moved = make(parent: link)
    make(parent: moved)
    stopped = make(parent: link)

    plan = manager::DELEGATES.plan(link.id, state_dir: tmpdir, except: [moved.id])

    expect(plan).to eq(described_class::Plan.new(delete: [stopped.id], leave: []))
  end

  it "reads the session listing once per plan, however deep the tree" do
    link = make
    child = make(parent: link)
    grandchild = make(parent: child)
    make(parent: grandchild)
    running = make(parent: link)
    own(running.id)
    make(parent: make(parent: running))
    allow(manager).to receive(:session_rows).and_call_original

    manager::DELEGATES.plan(link.id, state_dir: tmpdir)

    expect(manager).to have_received(:session_rows).once
  end
end
