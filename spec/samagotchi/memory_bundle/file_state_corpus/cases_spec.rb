# frozen_string_literal: true

require "spec_helper"
require_relative "support"

# The corpus itself: its cases are well formed, every fix they cite is a
# real example, and the generated expectations hold two invariants that every
# later regeneration must keep too.
RSpec.describe "Bundle state corpus: the cases" do
  # The file-machinery fixes a state model closes (the research's class B):
  # each is at least one case, its start lifted from the example that fixed it.
  B_FIXES = [705, 703, 704, 633, 634, 587, 424, 347, 290, 36, 37, 39, 40, 34, 43, 44, 45, 48, 49, 50, 51, 52, 55, 16, 20].freeze
  # The ones about hooks, rules, the plugin and scripts (asset_cases.yml).
  ASSET_FIXES = [704, 587, 424, 44, 45].freeze
  DIVERGENT = %w[D4 U4 dry-noop dry-trash edited-rule restore-unchecked].freeze
  # The commands whose cell may change the file's bytes.
  WRITES = %w[wrote_incoming wrote_merge restored moved deleted].freeze
  # A cell either invariant may break, with why: [case id, column] => note.
  # Expected empty; a new entry goes to the user as a finding first.
  INVARIANT_ALLOWLIST = {}.freeze

  let(:cases) { BundleStateCorpus.memory_cases }
  let(:by_id) { cases.to_h { |kase| [kase.id, kase] } }

  def expectations(name) = YAML.safe_load_file(File.join(BundleStateCorpus::FIXTURES, "expect", "#{name}.yml"))

  # Every cell of the memory files: [case, column, shape, cell].
  def memory_cells
    BundleStateCorpus::MEMORY_GROUPS.keys.flat_map do |name|
      expectations(name).flat_map do |id, columns|
        columns.flat_map do |column, cell|
          by_shape = cell.key?(BundleStateCorpus::SHAPES.first) ? cell : BundleStateCorpus::SHAPES.to_h { |shape| [shape, cell] }
          by_shape.map { |shape, value| [by_id.fetch(id), column, shape, value] }
        end
      end
    end
  end

  def fix_refs(all_cases) = all_cases.flat_map(&:fix).map { |ref| ref.match(/\A(\d+) (\S+_spec\.rb): (.+)\z/) || ref }

  it "has unique ids and known kinds, and a case of every kind" do
    expect(cases.map(&:id).tally.select { |_, n| n > 1 }.keys).to eq([])
    expect(cases.map(&:kind) - BundleStateCorpus::KINDS).to eq([])
    expect(BundleStateCorpus::KINDS - cases.map(&:kind)).to eq([])
  end

  it "gives each case a shape it can be built in" do
    bad = cases.reject do |kase|
      %w[base disk other none].include?(kase.recorded) && %w[none current legacy].include?(kase.mark) &&
        %w[incoming older].include?(kase.marked_incoming) && %w[right wrong none].include?(kase.sha) &&
        !(kase.recorded == "base" && kase.base.nil?) && !(kase.recorded == "disk" && kase.disk.nil?) &&
        (kase.owned || (kase.base.nil? && !kase.marked?)) && (kase.installed || !kase.owned)
    end
    expect(bad.map(&:id)).to eq([])
  end

  it "cites only real examples, and every fix it closes" do
    refs = fix_refs(cases)
    expect(refs.grep(String)).to eq([])
    missing = refs.reject { |ref| File.file?(ref[2]) && File.read(ref[2]).include?(ref[3]) }
    expect(missing.map(&:to_s)).to eq([])
    expect((B_FIXES - ASSET_FIXES) - refs.map { |ref| ref[1].to_i }).to eq([])
  end

  it "notes every tagged case, with a known tag" do
    tagged = cases.select { |kase| kase.fixed || kase.divergent }
    expect(tagged.reject(&:note).map(&:id)).to eq([])
    expect(tagged.flat_map { |kase| Array(kase.divergent) } - DIVERGENT).to eq([])
    expect(tagged.filter_map(&:fixed) - %w[D1 D2 D3]).to eq([])
  end

  it "has every case in every column of each memory file" do
    BundleStateCorpus::MEMORY_GROUPS.each do |name, columns|
      expect = expectations(name)
      expect(expect.keys).to eq(cases.map(&:id)), name
      expect(expect.values.map(&:keys).uniq).to eq([columns]), name
    end
  end

  # Invariant 1 (review check 1): bytes that are neither the base nor the
  # bundle's text are never changed or removed unless the trash has them.
  it "never changes or removes the user's own bytes without a copy in the trash" do
    lost = memory_cells.filter_map do |kase, column, shape, cell|
      next unless WRITES.include?(cell["do"].to_s.split(",").first) && !cell["save_first"]
      next unless kase.disk && kase.disk != kase.base && kase.disk != kase.incoming
      next if INVARIANT_ALLOWLIST.key?([kase.id, column])

      "#{kase.id} #{column} (#{shape}): #{cell["do"]} with no save"
    end
    expect(lost).to eq([])
  end

  # Invariant 2 (review check 4): the two record shapes differ only where
  # the case has a mark, the one thing 0.149 wrote differently.
  it "gives both record shapes one answer unless the case has a mark" do
    split = BundleStateCorpus::MEMORY_GROUPS.keys.flat_map do |name|
      expectations(name).flat_map do |id, columns|
        columns.filter_map do |column, cell|
          next unless cell.key?(BundleStateCorpus::SHAPES.first)
          next if by_id.fetch(id).marked? || INVARIANT_ALLOWLIST.key?([id, column])

          "#{id} #{column}"
        end
      end
    end
    expect(split).to eq([])
  end

  it "keeps the allowlist's entries noted" do
    expect(INVARIANT_ALLOWLIST.values.reject { |note| note.to_s.strip.empty? }).to eq(INVARIANT_ALLOWLIST.values)
  end
end
