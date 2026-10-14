# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/plugin/context"
require "samagotchi/context_sources"
require "samagotchi/plugin/peer"

# Samagotchi::Plugin::Peer, the peer bundles' base, with a fake peer whose
# transport keeps what it was given. The bundles' own texts are pinned by
# spec/samagotchi/bundles/peer_goldens_spec.rb.
RSpec.describe Samagotchi::Plugin::Peer do
  let(:peer_class) do
    Class.new(described_class) do
      const_set(:INBOX, "echo-inbox")
      const_set(:OUTBOX, "echo-outbox")
      const_set(:BUNDLE, "echo-peer")
      const_set(:NAME, "Echo")
      const_set(:APP, "Echo App")
      const_set(:COMMAND, "/echo")
      const_set(:TOOL, "echo_send")
      const_set(:TOOL_DESCRIPTION, "Send to Echo.")
      const_set(:TOOL_PARAMS, {}.freeze)
      const_set(:USAGE, "usage: /echo")
      const_set(:STATUS_CARD, "echo")
      const_set(:SKILL_CARD, "echo-skill")
      const_set(:SCRIPTS_DIRS, [].freeze)

      attr_reader :posted

      private

      def check_hint!(hint) = (raise Samagotchi::Plugin::Peer::SendError, "bad hint #{hint}" unless hint.start_with?("echo:"))

      def post(hint, text) = (@posted ||= []) << [hint, text]
    end
  end
  let(:tmpdir) { File.realpath(Dir.mktmpdir("peer")) }
  let(:state_home) { File.join(tmpdir, "state") }
  let(:state_dir) { File.join(state_home, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                       .tap { |s| s.save(state_dir: state_dir) }
  end
  let(:cards) { [] }
  let(:host) do
    Samagotchi::Plugin::Host.new(session_id: -> { session.id }, cwd: -> { tmpdir }, state_dir: -> { state_dir },
                                 messages: -> { [] }, card: ->(**card) { cards << card and card[:id] })
  end
  let(:ctx) do
    Samagotchi::Plugin::Context.new(bundle: "echo-peer", label: "plugin.rb (bundle echo-peer)", settings: {},
                                    host: host, env: { "XDG_STATE_HOME" => state_home })
  end
  let(:plugin) { peer_class.new({}) }
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }

  after { FileUtils.rm_rf(tmpdir) }

  def pair(hint = "echo:1")
    own.add(Samagotchi::ContextSources::Source.new(name: "echo-inbox", cmd: nil, every_seconds: nil, why: "Echo",
                                                   hint: hint, scope: "session", added_by: "cli",
                                                   created_at: Time.now.utc.iso8601))
  end

  def last_send = JSON.parse(File.read(File.join(ctx.data_dir, "sessions", session.id, "last-send.json")))

  it "posts a short part inline to the inbox's hint, in the subclass's words, and records it" do
    pair

    result = plugin.deliver(ctx, kind: "validate", title: "step  2\n", text: "is it right?")

    expect(result).to eq("sent to Echo: validate · step 2")
    expect(plugin.posted).to eq([["echo:1", "chi #{session.id[0, 8]} · validate · step 2\nis it right?"]])
    expect(last_send).to include("kind" => "validate", "title" => "step 2", "chars" => 12, "payload" => nil)
  end

  it "writes a long part to a payload file and posts its path" do
    pair
    text = "x\n" * 3_000

    result = plugin.deliver(ctx, kind: "context", title: "", text: text)

    path = plugin.posted.last.last[/payload: (\S+) \(3000 lines, 6000 chars\)\z/, 1]
    expect(File.read(path)).to eq(text)
    expect(result).to eq("sent to Echo: context · x (the text in #{path})")
    expect(last_send["payload"]).to eq(path)
  end

  it "asks the subclass to check the hint, and says how to pair without one" do
    expect { plugin.deliver(ctx, kind: "validate", title: "t", text: "x") }
      .to raise_error(described_class::SendError, "no echo-inbox: pair from Echo (install its skill with /echo " \
                                                  "install-skill, then tell Echo \"pair with chi #{session.id[0, 8]}\")")
    pair("elsewhere")
    expect { plugin.deliver(ctx, kind: "validate", title: "t", text: "x") }
      .to raise_error(described_class::SendError, "bad hint elsewhere")
    expect(plugin.posted).to be_nil
  end

  it "titles a typed text past a web quote's label and the quote marker" do
    expect(plugin.send(:text_title, "From your thinking:\n\n> the key is stable\nconfirm")).to eq("the key is stable")
  end

  it "finds the last completed answer, without its thinking, and none after a cancelled turn" do
    answer = [{ role: "user", content: "hi" }, { role: "model", content: "<think>x</think>Done." },
              { role: "system", kind: "context_note", content: "a note" }]
    cancelled = [*answer, { role: "system", kind: "turn_note", content: "canceled" }]

    expect(plugin.send(:completed_answer, answer)).to eq("Done.")
    expect(plugin.send(:completed_answer, cancelled)).to be_nil
  end

  it "names the hook a subclass left out" do
    pair
    peer_class.send(:remove_method, :post)

    expect { plugin.deliver(ctx, kind: "validate", title: "t", text: "x") }.to raise_error(NotImplementedError, /#post/)
    expect { plugin.send(:status, ctx) }.to raise_error(NotImplementedError, /#paired_lines/)
  end
end
