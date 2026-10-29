# frozen_string_literal: true

require "spec_helper"
require "samagotchi/thinking_command"
require "samagotchi/reasoning_history_command"
require "samagotchi/session"

# What /thinking and /reasoning-history share (LevelSettingCommand), run
# against both; each command's own replies are in its spec.
RSpec.describe Samagotchi::LevelSettingCommand do
  # The Engine's side of both settings: the session's own level over the
  # model's, a cost the spec sets.
  let(:engine_class) do
    Class.new do
      attr_accessor :session, :cost, :replied, :api

      def history? = !!replied
      def chat_model? = true
      def thinking_cache_cost = cost
      def reasoning_history_cache_cost(_from, _to) = cost
      def thinking_override = session&.thinking
      def reasoning_history_override = session&.reasoning_history

      def thinking_override=(level)
        session.thinking = level
      end

      def reasoning_history_override=(level)
        session.reasoning_history = level
      end

      def thinking_explained(own: thinking_override) = explained(own, :medium)
      def reasoning_history_explained(native: false, own: reasoning_history_override) = native && explained(own, :turn)
      def cache_restart_tokens = nil
      def cache_restart_anthropic? = false

      def explained(own, model_level)
        Samagotchi::SettingExplained.new(level: own || model_level, source: own ? "session" : "models: m", own: own)
      end
    end
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }
  let(:engine) { engine_class.new.tap { |e| e.session = session } }
  let(:saved) { [] }
  let(:command) { command_class.new(engine: engine, save: ->(s) { saved << s }) }

  shared_examples "a level setting command" do |label:, level:, unset:, own:, cost:|
    it "lists the level without changing anything" do
      reply, changed, confirm = command.run("")

      expect([changed, confirm, saved]).to eq([false, nil, []])
      expect(reply).to start_with("#{label}: ").and include("this session's own: none")
    end

    it "sets the session's own level, saves, and says it holds from the next turn" do
      reply, changed, = command.run(level)

      expect([own.call(session), changed, saved]).to eq([level.to_sym, true, [session]])
      expect(reply).to start_with("#{label}: #{level} (session)")
      expect(reply).to include("From the next turn's start")
    end

    it "unsets it with #{unset}" do
      command.run(level)
      command.run(unset)

      expect(own.call(session)).to be_nil
    end

    it "refuses a word that isn't a level, and a level with no session" do
      expect { command.run("bogus") }.to raise_error(ArgumentError, /\Aunknown #{label} level bogus\nusage: /)
      engine.session = nil
      expect { command.run(level) }.to raise_error(ArgumentError, "no session yet")
    end

    it "asks before a change that restarts the prompt cache, and --yes applies it" do
      engine.cost = cost
      engine.replied = true

      reply, changed, confirm = command.run(level)
      expect([changed, own.call(session)]).to eq([false, nil])
      expect(reply).to include("restarts the prompt cache")
      expect(confirm).not_to be_nil

      _reply, changed, = command.run("#{level} --yes")
      expect([changed, own.call(session)]).to eq([true, level.to_sym])
    end
  end

  describe Samagotchi::ThinkingCommand do
    let(:command_class) { described_class }

    it_behaves_like "a level setting command", label: "thinking", level: "high", unset: "default",
                                                own: lambda(&:thinking), cost: :full
  end

  describe Samagotchi::ReasoningHistoryCommand do
    let(:command_class) { described_class }

    it_behaves_like "a level setting command", label: "reasoning history", level: "all", unset: "default",
                                                own: lambda(&:reasoning_history), cost: :history
  end
end
