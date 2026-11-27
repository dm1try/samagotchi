# frozen_string_literal: true

require "securerandom"
require "tmpdir"
require "spec_helper"
require_relative "../support/pruned_anchor"
require_relative "../support/transition_holder"
require "samagotchi/session_chain/successor"
require "samagotchi/session_transition"

# "Is this link continued, and by whom": the one answer (N2).
RSpec.describe Samagotchi::SessionChain::Successor do
  include PrunedAnchor
  include TransitionHolder

  let(:root) { Dir.mktmpdir("chain-successor") }
  let(:state_dir) { File.join(root, "sessions").tap { |dir| FileUtils.mkdir_p(dir) } }

  after { FileUtils.rm_rf(root) }

  def link(continues: nil, archived: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.tmpdir,
                                    continues: continues).tap do |s|
      s.save(state_dir: state_dir)
      Samagotchi::ArchiveStore.archive(s.id, state_dir: state_dir) if archived
    end
  end

  def in_flight(id, successor, &) = holding_transition(id, state_dir: state_dir, successor: successor, &)

  it "names a saved successor via :next, archived or not" do
    first = link(archived: true)
    second = link(continues: first.id)

    expect(described_class.of(first.id, state_dir: state_dir)).to eq(described_class.new(id: second.id, via: :next))
    expect(described_class.of(second.id, state_dir: state_dir)).to be_nil
  end

  it "names a pruned anchor's schedule head via :anchor, unless asked without it" do
    chain = pruned_anchor_chain(state_dir)

    expect(described_class.of(chain.anchor, state_dir: state_dir)).to eq(described_class.new(id: chain.head, via: :anchor))
    expect(described_class.of(chain.anchor, state_dir: state_dir, anchor: false)).to be_nil
  end

  it "names a continue in flight only when asked, and only while its lock is held" do
    first = link
    successor = SecureRandom.uuid

    in_flight(first.id, successor) do
      expect(described_class.of(first.id, state_dir: state_dir)).to be_nil
      expect(described_class.of(first.id, state_dir: state_dir, in_flight: true))
        .to eq(described_class.new(id: successor, via: :in_flight))
      expect(described_class.in_flight(first.id, state_dir: state_dir)).to be_in_flight
    end
    # The intent is stale now (no continue holds the lock): nobody.
    expect(described_class.of(first.id, state_dir: state_dir, in_flight: true)).to be_nil
    expect(described_class.in_flight(first.id, state_dir: state_dir)).to be_nil
  end

  it "prefers the saved successor over an intent still on disk" do
    first = link(archived: true)
    second = link(continues: first.id)

    in_flight(first.id, second.id) do
      expect(described_class.of(first.id, state_dir: state_dir, in_flight: true).via).to eq(:next)
    end
  end

  it "is nil for an id that is no session id" do
    expect(described_class.of("../x", state_dir: state_dir, in_flight: true)).to be_nil
    expect(described_class.in_flight("../x", state_dir: state_dir)).to be_nil
  end
end
