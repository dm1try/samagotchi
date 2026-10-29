# frozen_string_literal: true

require "spec_helper"
require "samagotchi/reasoning_history_command"
require "samagotchi/session"

# /reasoning-history: shows the level the next turn runs under, sets or
# unsets the session's own.
RSpec.describe Samagotchi::ReasoningHistoryCommand do
  # The Engine's side of it: the session's own level over a model's.
  let(:engine_class) do
    Class.new do
      attr_accessor :session, :model_level, :chat, :cost_for, :replied

      def history? = !!replied
      def cache_restart_tokens = nil
      def cache_restart_anthropic? = false

      def reasoning_history_cache_cost(from, to) = cost_for&.call(from, to)

      def reasoning_history_override = session&.reasoning_history

      def reasoning_history_override=(level)
        session.reasoning_history = level
      end

      def reasoning_history_explained(native: false, own: reasoning_history_override)
        return nil unless native || chat

        Samagotchi::SettingExplained.new(level: own || model_level, source: own ? "session" : "models: qwen", own: own)
      end

      def chat_model? = chat
    end
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }
  let(:engine) { engine_class.new.tap { |e| e.session = session; e.model_level = :drop; e.chat = true } }
  let(:saved) { [] }
  let(:command) { described_class.new(engine: engine, save: ->(s) { saved << s }) }

  it "shows the level and where it came from, and that the session has none of its own" do
    expect(command.run("")).to eq(["reasoning history: drop (models: qwen)\n  this session's own: none (follows " \
                                   "SAMAGOTCHI_REASONING_HISTORY, the model, its host, then turn)", false, nil])
    session.reasoning_history = :all
    expect(command.run(" ")).to eq(["reasoning history: all (session)", false, nil])
    expect(saved).to be_empty
  end

  it "sets the session's own level, saves it, and says when it applies" do
    output, changed, ask = command.run(" ALL ")
    expect(ask).to be_nil

    expect(changed).to be(true)
    expect(session.reasoning_history).to eq(:all)
    expect(saved).to eq([session])
    expect(output).to eq("reasoning history: all (session)\nFrom the next turn's start (a running turn keeps its own).")
  end

  it "names the cost of a change that rewrites the earlier replies" do
    engine.cost_for = ->(from, to) { [from, to] == %i[drop all] ? :history : nil }
    expect(command.run("all").first).to end_with("Earlier replies gain or lose their reasoning: the server reads the " \
                                                 "conversation again from the first earlier thought.")
    expect(command.run("turn").first).to end_with("keeps its own).")
  end

  describe "the confirm step before a change that rewrites the earlier replies" do
    before do
      engine.replied = true
      engine.cost_for = ->(from, to) { [from, to].include?(:all) && from != to ? :history : nil }
    end

    it "asks first, changing nothing, and names the line that applies it" do
      output, changed, ask = command.run("all")

      expect([changed, session.reasoning_history, saved]).to eq([false, nil, []])
      expect(ask.line).to eq("/reasoning-history all --yes")
      expect(output).to end_with("Switching to all restarts the prompt cache: Earlier replies gain or lose their reasoning: the server " \
                                 "reads the conversation again from the first earlier thought.\n" \
                                 "Nothing changed yet: send `/reasoning-history all --yes` to apply.")
    end

    it "applies it with --yes, or when told not to ask" do
      expect(command.run("all --yes")[1]).to be(true)
      expect(session.reasoning_history).to eq(:all)
      expect(command.run("drop", confirm: false)[1]).to be(true)
      expect(session.reasoning_history).to eq(:drop)
    end

    it "doesn't ask between drop and turn, before the first reply, or when the level stays" do
      expect(command.run("turn")).to match([anything, true, nil])
      engine.replied = false
      expect(command.run("all")[1]).to be(true)
      engine.replied = true
      expect(command.run("all")).to match([end_with("(no change to what the next turn runs under)"), true, nil])
    end
  end

  it "keeps an explicit turn as the session's own, and unsets it with default" do
    command.run("turn")
    expect(session.reasoning_history).to eq(:turn)

    engine.model_level = :turn
    output, changed = command.run("default")
    expect(changed).to be(true)
    expect(session.reasoning_history).to be_nil
    expect(output).to end_with("then turn)\n(no change to what the next turn runs under)")
  end

  it "says a native host ignores it, and still sets the session's own for a chat model" do
    engine.chat = false
    expect(command.run("").first).to end_with("(ignored on this host: the native loop keeps the running turn's reasoning)")
    output, changed = command.run("drop")
    expect([changed, session.reasoning_history]).to eq([true, :drop])
    expect(output).to start_with("reasoning history: drop (session)\n  (ignored on this host")
  end

  it "refuses a word that isn't a level, with the usage, and changes nothing" do
    expect { command.run("off") }
      .to raise_error(ArgumentError, "unknown reasoning history level off\nusage: /reasoning-history [drop|turn|all|default]")
    expect(saved).to be_empty
  end

  it "needs a session to set one" do
    engine.session = nil
    expect { command.run("all") }.to raise_error(ArgumentError, "no session yet")
  end
end
