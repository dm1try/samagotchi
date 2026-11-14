# frozen_string_literal: true

require "spec_helper"
require "support/outdated_grants"
require "tmpdir"
require "support/test_kernel"

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/participants"

# The system prompt's participants line: there while the session has
# active participants, first in the volatile tail (the stable part, and so
# a new session's cache, never changes), built once when the first joins
# and once when the last leaves; every turn between sends the same prompt.
RSpec.describe "the system prompt's participants line" do
  include OutdatedGrants

  let(:state_dir) { Dir.mktmpdir("participants-line") }
  let(:line) { Samagotchi::SystemPrompt::PARTICIPANTS_LINE }

  after { FileUtils.rm_rf(state_dir) }

  describe Samagotchi::SystemPrompt do
    let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd) }
    let(:on) { [false] }
    let(:builder) do
      described_class.new(profile: -> { Samagotchi::ModelProfile.qwen36 }, tools: -> { Samagotchi::Tools::Registry.new },
                          session: -> { session }, thinking: -> { :off },
                          model: -> { Samagotchi::SystemPrompt::ModelIdentity.new(ref: "local:m", host: "local") },
                          participants: -> { on.first })
    end

    before { allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("") }

    it "puts the line first in the volatile tail: after the stable part, before the per-session lines" do
      without = builder.build(chat: true)
      stable = builder.stable_length(without)
      on[0] = :pair
      builder.reset!
      with = builder.build(chat: true)

      expect(without).not_to include(line)
      expect(builder.stable_length(with)).to eq(stable)
      expect(with[0, stable]).to eq(without[0, stable])
      expect(with[stable..]).to start_with("#{line}\n")
      expect(with.index(line)).to be < with.index("Current working directory:")
      expect(with.index(line)).to be < with.index("Current session id:")
    end

    it "has one line: what a participant's message is, an older chi's review header named too" do
      on[0] = :pair
      expect(builder.build(chat: true)).to include("#{line}\n")
      expect(line).to start_with("Participants: teammates the owner invited work in this session too.")
      expect(line).to include("[Review contribution from …]")
    end
  end

  describe Samagotchi::Engine, "a turn's start" do
    around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

    let(:client) { test_client }
    let(:kernel) { test_kernel(client: client) }
    let(:engine) do
      described_class.new(client: client, kernel: kernel, profile: "gemma4").tap { |e| e.session_state_dir = state_dir }
    end
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd).tap do |s|
        s.save(state_dir: state_dir)
        FileUtils.mkdir_p(Samagotchi::Session.session_dir(s.id, state_dir: state_dir))
      end
    end
    let(:grants) { Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir)) }
    let(:prompts) { [] }

    before do
      allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
      allow(kernel).to receive(:run) do |messages, **|
        prompts << messages.first[:content]
        Samagotchi::LLM::ModelResult.new(text: "ok", conversation: messages.drop(1) + [{ role: "model", content: "ok" }],
                                         exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
      end
    end

    def turn = engine.run_turn(session, "go", origin: { client_id: "web:o" })

    it "adds the line when the first participant joins and drops it when the last leaves, one rebuild each" do
      builder = engine.instance_variable_get(:@prompt_builder)
      allow(builder).to receive(:reset!).and_call_original

      turn
      alex = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir).grant
      turn
      bo = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Bo", state_dir: state_dir).grant
      turn
      Samagotchi::Participants.revoke(grants, session_id: session.id, id: alex.id, state_dir: state_dir)
      turn
      Samagotchi::Participants.revoke(grants, session_id: session.id, id: bo.id, state_dir: state_dir)
      turn

      expect(prompts.map { |prompt| prompt.include?(line) }).to eq([false, true, true, true, false])
      expect(prompts[1..3].uniq.size).to eq(1)
      expect(prompts[4]).to eq(prompts[0])
      expect(builder).to have_received(:reset!).twice
    end

    it "gives an older chi's read-only participants (no grant mode) no line: they are not in the session" do
      grant = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex", state_dir: state_dir).grant
      make_outdated!(grants, grant, state_dir: state_dir)
      turn
      expect(prompts.last).not_to include(Samagotchi::SystemPrompt::PARTICIPANTS_LINE)
      expect(prompts.last).not_to include(line)
    end

    describe "a Verify fresh child (it reads its parent's participants)" do
      let(:anchor) { { turn_id: SecureRandom.uuid, quote: "the cache key is per user" } }

      def child_of(author, mode)
        origin = Samagotchi::VerifyFreshOrigin.new(author: author, mode: mode, of: SecureRandom.uuid,
                                                   anchor: Samagotchi::VerifyAnchor.from(anchor))
        Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: Dir.pwd,
                                        parent_id: session.id, delegate: true).tap do |child|
          child.verify_fresh = origin
          child.save(state_dir: state_dir)
        end
      end

      before do
        @alex = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Alex",
                                                        state_dir: state_dir).grant
      end

      it "gives the owner's child no line, whoever is in the parent" do
        engine.run_turn(child_of(nil, nil), "go", origin: { client_id: "web:o" })
        expect(prompts.last).not_to include("Participants:")
      end

      it "gives a participant's child the line while their grant is active, none when it was saved read-only" do
        engine.run_turn(child_of("p:#{@alex.id}", "pair"), "go", origin: { client_id: "web:o" })
        expect(prompts.last).to include("#{line}\n")
        engine.run_turn(child_of("p:#{@alex.id}", "review"), "go", origin: { client_id: "web:o" })
        expect(prompts.last).not_to include("Participants:")
      end
    end

    it "leaves an owner session's prompt alone: no line, no rebuild" do
      builder = engine.instance_variable_get(:@prompt_builder)
      allow(builder).to receive(:reset!).and_call_original

      2.times { turn }

      expect(prompts.uniq.size).to eq(1)
      expect(prompts.first).not_to include("Participants:")
      expect(builder).not_to have_received(:reset!)
    end
  end
end
