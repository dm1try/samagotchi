# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_manager"
require "samagotchi/session_continue"
require "samagotchi/session_stores"

RSpec.describe Samagotchi::SessionStores do
  it "registers every literal sidecar filename constant used to build a session-directory path" do
    # A store is in scope when a literal FILE constant is joined to a session
    # directory, or passed to JsonlStore, which joins it there.
    # These similarly named constants have paths outside the session sidecar:
    # the context-source catalog, machine-wide approvals/index, plugin payloads,
    # and the prompt-file name.
    outside_sidecar = %w[subscriptions.json approvals.json .index.lock chi-peer-SKILL.md AGENTS.md]
    files = Dir.glob(File.join(__dir__, "../lib/samagotchi/**/*.rb")).flat_map do |path|
      source = File.read(path)
      constants = source.scan(/^\s*((?:[A-Z][A-Z0-9_]*_)?FILE)\s*=\s*"([^"]+)"/)
      constants.filter_map do |name, file|
        joined_to_session = source.match?(/File\.join\(\s*(?:session_dir|dir|Session\.session_dir)\b[^,\n]*,\s*#{Regexp.escape(name)}\b/)
        stored_as_jsonl = source.match?(/JsonlStore\.new\(\s*#{Regexp.escape(name)}\s*\)/)
        file if joined_to_session || stored_as_jsonl
      end
    end.uniq - outside_sidecar

    expect(files - described_class::STORES.map(&:file)).to be_empty
  end

  it "uses the registry's removal categories without adding file-by-file cleanup" do
    expect(Samagotchi::SessionManager::SESSION_STATE_STORES).to eq(described_class.removal_stores)
    expect(Samagotchi::SessionManager::SESSION_STATE_STORES)
      .to contain_exactly(:session_files, :plugin_session_state, :context_sources, :participants, :system_one_runs,
                          :context_candidates_log)
  end

  it "marks a cross-version store for the corpus or explains why it cannot be recorded" do
    expect(described_class.corpus_stores.reject { |store| store.corpus_dir || store.corpus_exception? }).to be_empty
    expect(described_class.corpus_stores.select(&:corpus_exception?).map(&:file)).to contain_exactly("starting")
  end
end
