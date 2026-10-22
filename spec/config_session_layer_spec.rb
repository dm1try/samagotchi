# frozen_string_literal: true

require "samagotchi/config"
require "samagotchi/session_config"

# The keys a session may set for itself (Config::Entry#session?), their
# strict typing (Config.coerce!) and the session layer that goes first.
RSpec.describe Samagotchi::Config do
  def entry(key) = described_class.find_by_key(key)

  describe "session-settable entries" do
    it "are recap.enabled and recap.sentences" do
      expect(described_class.session_entries.map(&:key)).to eq(%w[recap.enabled recap.sentences])
    end

    # D1: hub-wide keys, keys seen only at a process's start, and keys with a
    # session field of their own (one way to set each) are never settable.
    it "leave out hub-wide sections, process-wide lifecycles and keys with their own session field" do
      sections = %w[web server log kitty tmux update history broadcast session]
      lifecycles = %i[process_start web_start next_cli_run desktop_update next_update next_retention_sweep next_broadcast]
      own_field = %w[thinking.level guardrails.parent_answers reasoning_history]
      described_class.session_entries.each do |settable|
        expect(sections).not_to include(settable.section), settable.key
        expect(lifecycles).not_to include(settable.lifecycle), settable.key
        expect(own_field).not_to include(settable.key)
        expect(settable.key).not_to start_with("toolkit.", "llm_context.")
        expect(settable.session).to be(true), settable.key
      end
    end
  end

  describe ".coerce!" do
    it "types a value as its entry does" do
      { "true" => true, "YES" => true, "on" => true, "1" => true, "false" => false, "no" => false, "Off" => false, "0" => false }
        .each { |raw, value| expect(described_class.coerce!(entry("recap.enabled"), raw)).to be(value), raw }
      expect(described_class.coerce!(entry("server.port"), " 81 ")).to eq(81)
      expect(described_class.coerce!(entry("recap.inactivity"), "2.5")).to eq(2.5)
      expect(described_class.coerce!(entry("log.level"), "WARN")).to eq("warn")
      expect(described_class.coerce!(entry("recap.sentences"), "2-3 ")).to eq("2-3 ")
      expect(described_class.coerce!(entry("recap.enabled"), nil)).to be_nil
    end

    it "raises SessionConfig::Error where coerce warns, naming what the key takes" do
      {
        ["recap.enabled", "maybe"] => 'recap.enabled takes true or false, not "maybe"',
        ["server.port", "x"] => 'server.port takes an integer, not "x"',
        ["recap.inactivity", "soon"] => 'recap.inactivity takes a number, not "soon"',
        ["log.level", "loud"] => 'log.level takes debug, info, warn or error, not "loud"'
      }.each do |(key, raw), message|
        expect { described_class.coerce!(entry(key), raw) }.to raise_error(Samagotchi::SessionConfig::Error, message)
      end
    end

    it "is what coerce falls back from: the same values, a warning and the fallback for the rest" do
      expect(described_class.coerce(entry("recap.enabled"), "on")).to be(true)
      expect { expect(described_class.coerce(entry("server.port"), "x")).to eq(8080) }
        .to output(/invalid integer for server\.port/).to_stderr
      expect { expect(described_class.coerce(entry("recap.enabled"), "maybe")).to be(false) }
        .to output(/invalid bool for recap\.enabled/).to_stderr
      expect { expect(described_class.coerce(entry("guardrails.parent_answers"), "x")).to eq("hard") }
        .to output(/invalid value for guardrails\.parent_answers.*using hard/).to_stderr
    end
  end

  describe "the session layer" do
    it "goes first for a session-settable key, over CLI and env, with origin :session" do
      with_env("SAMAGOTCHI_RECAP_ENABLED" => "true") do
        expect(described_class.get_with_origin("recap.enabled")).to eq([true, :env])
        expect(described_class.get_with_origin("recap.enabled", session: { "recap.enabled" => false })).to eq([false, :session])
        expect(described_class.resolve_with_origin("recap.enabled", cli_overrides: { "recap.enabled" => true },
                                                                    session: { "recap.enabled" => false })).to eq([false, :session])
        expect(described_class.get("recap.enabled", session: {})).to be(true)
      end
    end

    it "is ignored for a key no session sets" do
      expect(described_class.get_with_origin("server.port", session: { "server.port" => 1 })).to eq([8080, :default])
    end
  end
end
