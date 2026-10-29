# frozen_string_literal: true

require "spec_helper"
require "samagotchi/thinking_command"
require "samagotchi/session"

# /thinking: shows the level the next turn runs at, sets or unsets the
# session's own, and says what a change costs.
RSpec.describe Samagotchi::ThinkingCommand do
  # The Engine's side of it: the session's own level over a model's.
  let(:engine_class) do
    Class.new do
      attr_accessor :session, :model_level, :cache_cost, :replied

      def thinking_override = session&.thinking

      def thinking_override=(level)
        session.thinking = level
      end

      def thinking_explained(own: thinking_override)
        Samagotchi::SettingExplained.new(level: own || model_level, source: own ? "session" : "models: qwen", own: own)
      end

      def thinking_cache_cost = cache_cost

      def history? = !!replied
      def cache_restart_tokens = nil
      def cache_restart_anthropic? = false
    end
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }
  let(:engine) { engine_class.new.tap { |e| e.session = session; e.model_level = :medium; e.cache_cost = :tail } }
  let(:saved) { [] }
  let(:command) { described_class.new(engine: engine, save: ->(s) { saved << s }) }

  it "shows the level and where it came from, and that the session has none of its own" do
    expect(command.run("")).to eq(["thinking: medium (models: qwen)\n  this session's own: none (follows chi web --thinking / " \
                                   "SAMAGOTCHI_THINKING_LEVEL, the model, its host, then thinking.level)", false, nil])
    session.thinking = :low
    expect(command.run(" ")).to eq(["thinking: low (session)", false, nil])
    expect(saved).to be_empty
  end

  it "sets the session's own level, saves it, and says when it applies and what it costs" do
    output, changed, ask = command.run(" LOW ")
    expect(ask).to be_nil

    expect(changed).to be(true)
    expect(session.thinking).to eq(:low)
    expect(saved).to eq([session])
    expect(output).to eq("thinking: low (session)\nFrom the next turn's start (a running turn keeps its own).\n" \
                         "Only the prompt's tail changes: the cache keeps the rest.")
  end

  it "names the whole-prompt cost on Gemma and the provider's on a chat host" do
    engine.cache_cost = :full
    expect(command.run("off").first).to include("the whole prompt is read again (Gemma's <|think|> starts it)")
    engine.cache_cost = :provider
    expect(command.run("high").first).to include("a hosted API (OpenRouter, Claude, OpenAI) reads the whole conversation again")
  end

  it "unsets it with default, and says so when the level the next turn runs at stays" do
    session.thinking = :medium
    output, changed = command.run("default")

    expect(changed).to be(true)
    expect(session.thinking).to be_nil
    expect(output).to end_with("then thinking.level)\n(no change to what the next turn runs under)")
  end

  describe "the confirm step before a costly change" do
    before do
      engine.replied = true
      engine.cache_cost = :provider
    end

    it "asks first, changing nothing, and names the line that applies it" do
      output, changed, ask = command.run("low")

      expect([changed, session.thinking, saved]).to eq([false, nil, []])
      expect(ask).to eq(Samagotchi::CacheConfirm::Confirm.new(line: "/thinking low --yes",
                                                              text: "Nothing changed yet: send `/thinking low --yes` to apply."))
      expect(output).to eq("thinking: medium (models: qwen)\n  this session's own: none (follows chi web --thinking / " \
                           "SAMAGOTCHI_THINKING_LEVEL, the model, its host, then thinking.level)\n" \
                           "Switching to low restarts the prompt cache: #{described_class::COST_NOTES[:provider]}\n" \
                           "Nothing changed yet: send `/thinking low --yes` to apply.")
    end

    it "applies it with --yes or -y, anywhere, or when told not to ask" do
      expect(command.run("--yes low")[0..2]).to match([start_with("thinking: low (session)"), true, nil])
      expect(command.run("high -y")[1]).to be(true)
      expect(session.thinking).to eq(:high)
      expect(command.run("off", confirm: false)[1]).to be(true)
      expect(session.thinking).to eq(:off)
    end

    it "doesn't ask before the first reply, for a tail-only cost, or when the level the next turn runs at stays" do
      engine.replied = false
      expect(command.run("low")[1]).to be(true)
      engine.replied = true
      engine.cache_cost = :tail
      expect(command.run("high")[1]).to be(true)
      engine.cache_cost = :full
      expect(command.run("high")).to match([end_with("(no change to what the next turn runs under)"), true, nil])
      engine.model_level = :high
      expect(command.run("default")).to match([end_with("(no change to what the next turn runs under)"), true, nil])
    end
  end

  it "refuses a word that isn't a level, with the usage, and changes nothing" do
    expect { command.run("turbo --yes") }
      .to raise_error(ArgumentError, "unknown thinking level turbo\nusage: /thinking [off|low|medium|high|default]")
    expect(saved).to be_empty
  end
end
