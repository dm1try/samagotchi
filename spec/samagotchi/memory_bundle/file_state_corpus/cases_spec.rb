# frozen_string_literal: true

require "spec_helper"
require_relative "support"
require_relative "assets"

module BundleStateCorpus
  # What cases_spec.rb checks the corpus against.
  module Checks
    # The file-machinery fixes a state model closes (the research's class B):
    # each is at least one case, its start lifted from the example that fixed it.
    B_FIXES = [705, 703, 704, 633, 634, 587, 424, 347, 290, 36, 37, 39, 40, 34, 43, 44, 45, 48, 49, 50, 51, 52, 55, 16, 20].freeze
    DIVERGENT = %w[U4 dry-trash restore-unchecked].freeze
    # Divergent tags a later commit changed the cells of (the plan's P1.9 …).
    CHANGED = %w[D4 U4 U7 dry-noop edited-rule].freeze
    ASSET_DIVERGENT = %w[dry-checksum dry-dropped dry-trash hook-stray-left hook-sha-dropped hook-status new-updated rule-installed
                         uninstall-unnamed].freeze
    # What a cell's do says when the file's bytes changed or went.
    WRITES = %w[wrote_incoming wrote_merge restored moved deleted].freeze
    ASSET_WRITES = %w[wrote_incoming wrote_other removed].freeze
    # A cell either invariant may break, with why: [case id, column] => note.
    # Each entry is a finding the user has seen; a new one goes to them first.
    INVARIANT_ALLOWLIST = {}.freeze
  end
end

# The corpus itself: its cases are well formed, every fix they cite is a
# real example, and the generated expectations hold two invariants that every
# later regeneration must keep too.
RSpec.describe "Bundle state corpus: the cases" do
  let(:cases) { BundleStateCorpus.memory_cases }
  let(:by_id) { cases.to_h { |kase| [kase.id, kase] } }
  let(:asset_cases) { BundleStateCorpus.asset_cases }
  let(:asset_by_id) { asset_cases.to_h { |kase| [kase.id, kase] } }

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

  # Every cell of expect/assets.yml: [case, column, shape, cell].
  def asset_cells
    expectations("assets").flat_map do |id, columns|
      columns.flat_map do |column, cell|
        by_shape = cell.key?(BundleStateCorpus::SHAPES.first) ? cell : BundleStateCorpus::SHAPES.to_h { |shape| [shape, cell] }
        by_shape.map { |shape, value| [asset_by_id.fetch(id), column, shape, value] }
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
    expect(BundleStateCorpus::Checks::B_FIXES - (refs + fix_refs(asset_cases)).map { |ref| ref[1].to_i }).to eq([])
  end

  it "has unique asset ids, and every asset in every state" do
    expect(asset_cases.map(&:id).tally.select { |_, n| n > 1 }.keys).to eq([])
    expect(asset_cases.map(&:asset).uniq - BundleStateCorpus::ASSETS).to eq([])
    grid = BundleStateCorpus::ASSETS.product(BundleStateCorpus::ASSET_STATES)
    expect(grid - asset_cases.map { |kase| [kase.asset, kase.state] }).to eq([])
    asset_refs = fix_refs(asset_cases)
    expect(asset_refs.grep(String)).to eq([])
    expect(asset_refs.reject { |ref| File.file?(ref[2]) && File.read(ref[2]).include?(ref[3]) }.map(&:to_s)).to eq([])
    tagged = asset_cases.select { |kase| kase.fixed || kase.divergent }
    expect(tagged.reject(&:note).map(&:id)).to eq([])
    expect(tagged.flat_map { |kase| Array(kase.divergent) } - BundleStateCorpus::Checks::ASSET_DIVERGENT).to eq([])
  end

  it "has every asset case in every asset column" do
    expect = expectations("assets")
    expect(expect.keys).to eq(asset_cases.map(&:id))
    expect(expect.values.map(&:keys).uniq).to eq([BundleStateCorpus::ASSET_COLUMNS])
  end

  it "notes every tagged case, with a known tag" do
    tagged = cases.select { |kase| kase.fixed || kase.divergent || kase.changed }
    expect(tagged.reject(&:note).map(&:id)).to eq([])
    expect(tagged.flat_map { |kase| Array(kase.divergent) } - BundleStateCorpus::Checks::DIVERGENT).to eq([])
    expect(tagged.flat_map { |kase| Array(kase.changed) } - BundleStateCorpus::Checks::CHANGED).to eq([])
    expect(tagged.filter_map(&:fixed) - %w[D1 D2 D3]).to eq([])
  end

  it "has every case in every column of each memory file" do
    BundleStateCorpus::MEMORY_GROUPS.each do |name, columns|
      expect = expectations(name)
      expect(expect.keys).to eq(cases.map(&:id)), name
      expect(expect.values.map(&:keys).uniq).to eq([columns]), name
    end
  end

  # Invariant 1 (review check 1): the user's bytes (MemoryCase#users_bytes?:
  # neither the bundle's text nor vouched for by the record, checksum first)
  # are never changed or removed unless the trash has them.
  it "never changes or removes the user's own bytes without a copy in the trash" do
    lost = memory_cells.filter_map do |kase, column, shape, cell|
      next unless BundleStateCorpus::Checks::WRITES.include?(cell["do"].to_s.split(",").first) && !cell["save_first"]
      next unless kase.users_bytes?
      next if BundleStateCorpus::Checks::INVARIANT_ALLOWLIST.key?([kase.id, column])

      "#{kase.id} #{column} (#{shape}): #{cell["do"]} with no save"
    end
    lost += asset_cells.filter_map do |kase, column, shape, cell|
      next unless BundleStateCorpus::Checks::ASSET_WRITES.include?(cell["do"].to_s.split(/[ ,]/).first) && cell.key?("save_first") && !cell["save_first"]
      next if kase.dev? || kase.installed.nil? || kase.installed == kase.recorded || kase.installed == kase.incoming
      next if BundleStateCorpus::Checks::INVARIANT_ALLOWLIST.key?([kase.id, column])

      "#{kase.id} #{column} (#{shape}): #{cell["do"]} with no save"
    end
    expect(lost).to eq([])
  end

  # The plan's replaced and the upgrade's trash copies are one rule asked
  # twice (ShippedUpdate#trash_bound and AssetInstaller, hooks' selection
  # written in both: the batch review's LOW 3): every asset case agrees.
  it "names in chi update's plan exactly the files the upgrade copies to the trash" do
    by_case = asset_cells.group_by { |kase, _, shape, _| [kase.id, shape] }
    disagree = by_case.filter_map do |(id, shape), cells|
      cell = cells.to_h { |_, column, _, value| [column, value] }
      replaces = cell.fetch("plan")["word"].to_s.split(", ").include?("replaces")
      "#{id} (#{shape}): plan replaces=#{replaces}, upgrade save_first=#{cell.fetch("upgrade")["save_first"]}" unless replaces == cell.fetch("upgrade")["save_first"]
    end
    expect(disagree).to eq([])
  end

  # Invariant 2 (review check 4): the two record shapes differ only where
  # the case has a mark, the one thing 0.149 wrote differently.
  it "gives both record shapes one answer unless the case has a mark" do
    split = BundleStateCorpus::MEMORY_GROUPS.keys.flat_map do |name|
      expectations(name).flat_map do |id, columns|
        columns.filter_map do |column, cell|
          next unless cell.key?(BundleStateCorpus::SHAPES.first)
          next if by_id.fetch(id).marked? || BundleStateCorpus::Checks::INVARIANT_ALLOWLIST.key?([id, column])

          "#{id} #{column}"
        end
      end
    end
    # An asset case has no mark: its shapes never differ.
    split += expectations("assets").flat_map do |id, columns|
      columns.filter_map { |column, cell| "#{id} #{column}" if cell.key?(BundleStateCorpus::SHAPES.first) && !BundleStateCorpus::Checks::INVARIANT_ALLOWLIST.key?([id, column]) }
    end
    expect(split).to eq([])
  end

  it "keeps the allowlist's entries noted" do
    expect(BundleStateCorpus::Checks::INVARIANT_ALLOWLIST.values.reject { |note| note.to_s.strip.empty? }).to eq(BundleStateCorpus::Checks::INVARIANT_ALLOWLIST.values)
  end
end
