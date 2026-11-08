# frozen_string_literal: true

require "spec_helper"
require_relative "file_state_corpus/support"
require_relative "file_state_corpus/states"

# The table agrees with the corpus: for every case and every column of a
# command that acts, FileActions.for (a :decide cell through Merger::Upgrade's
# Outcome) predicts what the corpus observed the command do: the bytes, the
# trash copy, the next base, the mark and the summary's word.
RSpec.describe Samagotchi::MemoryBundle::FileActions do
  before(:all) { @sandbox = BundleStateCorpus::Sandbox.new }
  after(:all) { @sandbox&.cleanup }

  def compared = %w[do save_first next_base mark word]

  def expectations(name) = (@expectations ||= {})[name] ||= YAML.safe_load_file(File.join(BundleStateCorpus::FIXTURES, "expect", "#{name}.yml"))

  def observed(file, kase, column, shape)
    cell = expectations(file).fetch(kase.id).fetch(column)
    cell = cell.fetch(shape) if cell.key?(shape)
    cell.slice(*compared).merge("mark" => cell["mark"].to_s.delete_suffix(" (legacy)"))
  end

  # The command a column runs, for this case; nil: the column never meets it.
  def command_for(column, kase, state)
    case column
    when "install" then :install
    when "install_force" then state.kind.to_s.start_with?("dropped_") ? :install : :force
    when "upgrade" then kase.installed ? :upgrade : :install
    when "upgrade_force" then :force
    when "remerge" then kase.marked? ? :remerge : nil
    when "restore" then %i[missing new].include?(state.kind) ? :restore : nil
    when "uninstall", "uninstall_force" then kase.installed && kase.owned ? :uninstall : nil
    end
  end

  def action_for(column, kase, state, outcome)
    command = command_for(column, kase, state)
    return nil unless command
    return described_class::BEHIND.with(record: :hold_mark) if command == :remerge && state.source_moved?

    action = described_class.for(command, state)
    action = described_class.decided(outcome, command) if action&.do == :decide
    action = described_class::REMOVE if column == "uninstall_force" && action&.do == :refuse
    action
  end

  def disagreements(file, columns, flavor: :demo)
    BundleStateCorpus.memory_cases.flat_map do |kase|
      next [] if kase.unreadable && Process.uid.zero?

      allow(Samagotchi::MemoryBundle::ShippedHistory).to receive(:shipped?).and_return(kase.shipped_history)
      source = !columns.first.start_with?("uninstall")
      BundleStateCorpus::SHAPES.flat_map do |shape|
        BundleStateCorpus::States.state(@sandbox, kase, shape, flavor: flavor, source: source) do |state, outcome|
          break columns.filter_map { |column| disagreement(file, kase, column, shape, state, outcome) }
        end
      end
    end
  end

  def disagreement(file, kase, column, shape, state, outcome)
    action = action_for(column, kase, state, outcome)
    return nil unless action

    want = BundleStateCorpus::States.predict(kase, action, column, merged: outcome&.merge&.text)
    got = observed(file, kase, column, shape)
    # Remerge's words also say whether the record's were updated.
    got["word"] = got["word"].to_s.split(", ").last if column == "remerge"
    want["word"] = "behind" if column == "remerge" && action.word == :behind
    return nil if want == got

    "#{kase.id} #{column} (#{shape}) #{state.kind}/#{state.mark}:\n  table #{want}\n  corpus #{got}"
  end

  it "predicts every install, install --force, upgrade and upgrade --force cell" do
    expect(disagreements("install", %w[install install_force])).to eq([])
    expect(disagreements("upgrade", %w[upgrade upgrade_force])).to eq([])
  end

  it "predicts every remerge and restore cell of a file it acts on" do
    expect(disagreements("remerge_restore", %w[remerge restore], flavor: :system)).to eq([])
  end

  it "predicts every uninstall cell, --force moving what a plain one refuses" do
    expect(disagreements("uninstall_status", %w[uninstall uninstall_force])).to eq([])
  end

  it "has a row for every kind each command meets" do
    with_source = %i[new user_same user_file missing level pristine edited diverged pristine_no_base edited_no_base
                     dropped_pristine dropped_edited dropped_missing unreadable]
    %i[install force upgrade].each do |command|
      expect(with_source - described_class::TABLES.fetch(command).keys.map(&:first)).to eq([]), command.to_s
    end
    expect(%i[pristine edited pristine_no_base edited_no_base missing unreadable] -
           described_class::UNINSTALL.keys.map(&:first)).to eq([])
  end
end
