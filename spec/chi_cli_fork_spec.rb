# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"

# fork_chi's fork (spec/support/chi_cli.rb) starts as a new chi would: no
# session owner lock of the suite's held open, no warn-once flag set.
RSpec.describe "ChiCli.fork_chi" do
  it "closes the fork's copy of the suite's owner locks and clears the warn-once flags, keeping the parent's lock" do
    Dir.mktmpdir do |dir|
      ChiCli.preload
      lock = Samagotchi::OwnerLock.acquire(File.join(dir, "session"), kind: "worker")
      report = File.join(dir, "report.json")
      Samagotchi::PromptWarmup.instance_variable_set(:@warned, true)
      Samagotchi::LLM::PromptCache.instance_variable_set(:@warned_ttl, true)
      Samagotchi::ModelNotes.instance_variable_get(:@warned) << "seen"
      Samagotchi::ConfigFile.instance_variable_set(:@warned, Set["seen"])
      # What the fork had once its state was reset, before chi ran.
      allow(ChiCli).to receive(:reset_inherited_state).and_wrap_original do |original|
        original.call
        File.write(report, JSON.generate(
          "lock_open" => !lock.instance_variable_get(:@file).closed?,
          "flags" => [Samagotchi::PromptWarmup.instance_variable_get(:@warned),
                      Samagotchi::LLM::PromptCache.instance_variable_get(:@warned_ttl),
                      Samagotchi::ModelNotes.instance_variable_get(:@warned).to_a,
                      Samagotchi::ConfigFile.instance_variable_get(:@warned)]
        ))
      end

      _out, _err, status = fork_chi("--version", env: isolated_chi_env(dir))

      expect(status.exitstatus).to eq(0)
      expect(JSON.parse(File.read(report))).to eq("lock_open" => false, "flags" => [nil, nil, [], nil])
      expect(Samagotchi::OwnerLock.owner(File.join(dir, "session"))&.kind).to eq("worker")
    ensure
      lock&.release
      Samagotchi::PromptWarmup.instance_variable_set(:@warned, nil)
      Samagotchi::LLM::PromptCache.instance_variable_set(:@warned_ttl, nil)
      Samagotchi::ModelNotes.reset_warnings!
    end
  end
end
