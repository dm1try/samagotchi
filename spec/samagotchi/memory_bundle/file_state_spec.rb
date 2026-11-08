# frozen_string_literal: true

require "spec_helper"
require_relative "file_state_corpus/support"
require_relative "file_state_corpus/states"

# FileState.of over every corpus case's starting tree, both record shapes:
# the kind each case is hand-assigned (memory_cases.yml), its mark, and the
# source-less kind status and uninstall read (D, B and the checksum only).
RSpec.describe Samagotchi::MemoryBundle::FileState do
  before(:all) { @sandbox = BundleStateCorpus::Sandbox.new }
  after(:all) { @sandbox&.cleanup }

  # The 0.149 shape writes every mark as an older chi's.
  def mark_in(kase, shape)
    return :none unless kase.marked?

    shape == "0.149" ? :legacy : kase.mark.to_sym
  end

  # The checksum first, then the base (Provenance.unchanged?): the corpus's
  # own reading of "never edited".
  def edited?(kase)
    vouched = kase.recorded == "disk" || (kase.recorded == "base" && kase.disk == kase.base) ||
              (kase.recorded == "none" && !kase.base.nil? && kase.disk == kase.base)
    !vouched
  end

  def source_less(kase)
    return :unreadable if kase.unreadable
    return :missing if kase.disk.nil?

    no_base = kase.base.nil?
    if edited?(kase) then no_base ? :edited_no_base : :edited
    else no_base ? :pristine_no_base : :pristine
    end
  end

  it "gives each case its kind and mark, in both record shapes" do
    got = BundleStateCorpus.memory_cases.flat_map do |kase|
      next [] if kase.unreadable && Process.uid.zero?

      BundleStateCorpus::SHAPES.filter_map do |shape|
        found = BundleStateCorpus::States.state(@sandbox, kase, shape)
        want = [kase.kind.to_sym, mark_in(kase, shape)]
        "#{kase.id} (#{shape}): #{found.inspect}, want #{want.inspect}" unless found == want
      end
    end
    expect(got).to eq([])
  end

  it "gives each owned case its source-less kind" do
    got = BundleStateCorpus.memory_cases.select { |kase| kase.installed && kase.owned }.filter_map do |kase|
      next if kase.unreadable && Process.uid.zero?

      found, = BundleStateCorpus::States.state(@sandbox, kase, "0.155", source: false)
      "#{kase.id}: #{found.inspect}, want #{source_less(kase).inspect}" unless found == source_less(kase)
    end
    expect(got).to eq([])
  end

  it "says the source moved only for a mark that names other text" do
    moved = BundleStateCorpus.memory_cases.select(&:marked?).select do |kase|
      BundleStateCorpus::States.state(@sandbox, kase, "0.155", flavor: :system) { |state, _| break state.source_moved? }
    end
    expect(moved.map(&:id)).to eq(%w[source_moved_marked])
  end

  it "asks for the other bundles once, and only when asked" do
    kase = BundleStateCorpus.memory_cases.find { |c| c.id == "dropped_pristine_shared" }
    calls = 0
    BundleStateCorpus::States.at_tree(@sandbox, kase, "0.155", :demo) do |record, provenance|
      state = described_class.of("a.md", record: record, provenance: provenance, target_dir: BundleStateCorpus.memories_dir,
                                         source_dir: nil, claimants: ->(_key) { (calls += 1) && ["other"] })
      expect(calls).to eq(0)
      2.times { expect(state.shared_with).to eq(["other"]) }
    end
    expect(calls).to eq(1)
  end
end
