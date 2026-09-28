# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/plugin/context"
require "samagotchi/session_manager"

# ctx.sessions (docs/plugins.md, Sessions): fork, send and read.
RSpec.describe Samagotchi::Plugin::Sessions do
  let(:tmpdir) { Dir.mktmpdir }
  let(:parent) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir).tap do |s|
      s.messages = [{ role: "user", content: "hello" }, { role: "model", content: "hi" }]
      s.save(state_dir: tmpdir)
    end
  end
  let(:session_id) { parent.id }
  let(:host) do
    Samagotchi::Plugin::Host.new(session_id: -> { session_id }, cwd: -> { tmpdir }, model_name: -> { "gemma4" },
                                 state_dir: -> { tmpdir })
  end
  let(:ctx) { Samagotchi::Plugin::Context.new(bundle: "b", label: "l", settings: {}, host: host) }
  let(:sessions) { ctx.sessions }

  after { FileUtils.rm_rf(tmpdir) }

  before { allow(Process).to receive(:spawn).and_return(12_345) }

  describe "#fork" do
    it "starts an idle child of this session from the messages (frozen ones too)" do
      seed = [{ role: "user", content: "hello" }.freeze, { role: "model", content: "hi" }.freeze,
              { role: "user", content: "q" }, { role: "model", content: "a" }].freeze

      id = sessions.fork(messages: seed, title: "q")

      child = Samagotchi::Session.load(id, state_dir: tmpdir)
      expect(child).to have_attributes(parent_id: parent.id, first_preview: "q", status: "idle",
                                       model_name: "gemma4", working_directory: tmpdir)
      expect(child.messages.map { |m| m[:content] }).to eq(%w[hello hi q a])
      expect(Samagotchi::SessionManager.children_of(parent.id, state_dir: tmpdir).map { |s| s[:id] }).to eq([id])
    end

    it "runs a prompt as the child's first turn, within session.max_children" do
      allow(Samagotchi::Tools::Delegate).to receive(:max_children).and_return(1)
      allow(Samagotchi::Tools::Delegate).to receive(:running_children).and_return([])
      id = sessions.fork(messages: [], prompt: "go on")
      expect(Samagotchi::Session.load(id, state_dir: tmpdir)).to have_attributes(status: "running", last_prompt: "go on")

      allow(Samagotchi::Tools::Delegate).to receive(:running_children).and_return([{ short_id: id[0, 8] }])
      expect { sessions.fork(messages: [], prompt: "more") }
        .to raise_error(described_class::Error, /1 child sessions of this session are running \(the most is 1/)
      # An idle fork doesn't count.
      expect(sessions.fork(messages: [])).to match(/\A[\w-]{36}\z/)
    end

    context "from a scratch session" do
      let(:host) do
        Samagotchi::Plugin::Host.new(session_id: -> { session_id }, cwd: -> { tmpdir }, model_name: -> { "gemma4" },
                                     state_dir: -> { tmpdir }, scratch: -> { true })
      end

      it "raises: the child would outlive it" do
        expect { sessions.fork(messages: []) }.to raise_error(described_class::Error, /scratch session starts no other sessions/)
        expect(Samagotchi::SessionManager.children_of(parent.id, state_dir: tmpdir)).to be_empty
      end
    end

    context "without a session yet" do
      let(:session_id) { nil }

      it "raises" do
        expect { sessions.fork(messages: []) }.to raise_error(described_class::Error, /no id yet/)
      end
    end
  end

  describe "#send" do
    it "delivers a turn to the session, by id or prefix" do
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return({ status: :accepted, ack: {} })

      expect(sessions.send(parent.id[0, 8], "do this")).to eq(parent.id)
      expect(Samagotchi::SessionManager).to have_received(:deliver_turn)
        .with(parent.id, prompt: "do this", client_id: "plugin", state_dir: tmpdir)
    end

    it "raises when the session didn't take it, or there is none" do
      allow(Samagotchi::SessionManager).to receive(:deliver_turn).and_return({ status: :timeout, ack: nil })

      expect { sessions.send(parent.id, "x") }.to raise_error(described_class::Error, /did not answer in time/)
      expect { sessions.send("nope", "x") }.to raise_error(described_class::Error, /no session nope/)
    end
  end

  describe "#read" do
    it "reads a saved session without a worker" do
      expect(sessions.read(parent.id)).to eq(
        id: parent.id, title: "hello", status: "idle", parent_id: nil, running: false,
        messages: [{ role: "user", content: "hello" }, { role: "model", content: "hi" }]
      )
    end

    it "reads a live worker's snapshot, with its running turn so far" do
      client = instance_double(Samagotchi::BridgeClient)
      allow(Samagotchi::BridgeClient).to receive(:discover).and_return(client)
      allow(client).to receive(:get_json).with("snapshot").and_return(
        "messages" => [{ "role" => "system", "content" => "prompt" }, { "role" => "user", "content" => "hello" }],
        "current_turn" => { "prompt" => "now", "parts" => [{ "kind" => "text", "iteration" => 1, "text" => "Wor" }] }
      )

      expect(sessions.read(parent.id)).to include(
        running: true,
        messages: [{ role: "user", content: "hello" }, { role: "user", content: "now" }, { role: "model", content: "Wor" }]
      )
    end
  end
end
