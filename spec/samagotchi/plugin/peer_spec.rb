# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "digest"
require "samagotchi/ref"
require "samagotchi/plugin/context"
require "samagotchi/context_sources"
require "samagotchi/plugin/peer"

# Samagotchi::Plugin::Peer, the peer bundles' base, with a fake peer whose
# transport keeps what it was given. The bundles' own texts are pinned by
# lib/samagotchi/bundles/claude-peer/spec/peer_goldens_spec.rb.
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

  it "logs successful sends and transport failures without the text" do
    pair
    plugin.deliver(ctx, kind: "validate", title: "t", text: "private")
    allow(plugin).to receive(:post).and_raise(described_class::SendError, "offline")
    expect { plugin.deliver(ctx, kind: "question", title: "q", text: "secret", by: "user") }
      .to raise_error(described_class::SendError, "offline")
    lines = Samagotchi::PeerExchanges.read(session.id, state_dir: state_dir)
    expect(lines).to match([include("t" => "sent", "peer" => "echo", "by" => "model", "chars" => 7),
                            include("t" => "send_failed", "peer" => "echo", "error" => "offline")])
    expect(JSON.generate(lines)).not_to include("private", "secret")
  end

  it "does not log a payload write failure" do
    pair
    allow(plugin).to receive(:write_payload).and_raise(described_class::SendError, "disk")
    expect { plugin.deliver(ctx, kind: "context", title: "t", text: "x" * 4001) }.to raise_error(described_class::SendError)
    expect(Samagotchi::PeerExchanges.read(session.id, state_dir: state_dir)).to be_empty
  end

  it "gives two equal command sends ids of their own" do
    pair
    2.times { plugin.send(:run_command, "validate check this", ctx) }
    ids = Samagotchi::PeerExchanges.read(session.id, state_dir: state_dir).map { |line| line["id"] }
    expect(ids.uniq.length).to eq(2)
    expect(ids).not_to include(described_class.send_id("validate", "check this", "check this"))
    expect(plugin.posted.map { |_, text| text.lines[1] }).to eq(ids.map { |id| "ref: #{id}\n" })
  end

  it "records a command send as a user send and keeps sending if the log is unavailable" do
    pair
    plugin.send(:run_command, "validate check this", ctx)
    expect(Samagotchi::PeerExchanges.read(session.id, state_dir: state_dir).last).to include("by" => "user")
    allow(Samagotchi::PeerExchanges).to receive(:append).and_raise(Errno::EACCES)
    expect(ctx.log).to receive(:warn).with("peer_exchange_not_saved", error: anything)
    expect(plugin.deliver(ctx, kind: "validate", title: "t", text: "ok")).to eq("sent to Echo: validate · t")
  end

  it "looks for the last send without leaving a session folder" do
    expect(plugin.send(:last_send, ctx)).to be_nil
    expect(File).not_to exist(File.join(ctx.data_dir, "sessions", session.id))
  end

  it "posts a short part inline to the inbox's hint, in the subclass's words, and records it" do
    pair
    id = described_class.send_id("validate", "step  2\n", "is it right?")

    result = plugin.deliver(ctx, kind: "validate", title: "step  2\n", text: "is it right?")

    # The result (what the model reads) is as it was before the ref line.
    expect(result).to eq("sent to Echo: validate · step 2")
    expect(plugin.posted).to eq([["echo:1", "chi #{session.id[0, 8]} · validate · step 2\nref: #{id}\nis it right?"]])
    expect(last_send).to include("id" => id, "kind" => "validate", "title" => "step 2", "chars" => 12, "payload" => nil)
  end

  describe ".send_id" do
    it "is s- and 6 hex of SHA-256 over kind, title and text as given" do
      expect(described_class.send_id("validate", "step  2\n", "is it right?"))
        .to eq("s-#{Digest::SHA256.hexdigest("validate\0step  2\n\0is it right?")[0, 6]}")
      expect(described_class.send_id("validate", "t", "x")).to match(/\As-[0-9a-f]{6}\z/)
    end

    it "is the same for equal args and differs by kind, title or text" do
      id = described_class.send_id("validate", "t", "x")

      expect(described_class.send_id("validate", "t", "x")).to eq(id)
      expect([described_class.send_id("question", "t", "x"), described_class.send_id("validate", "t2", "x"),
              described_class.send_id("validate", "t", "x2")]).to all(satisfy { |other| other != id })
    end

    it "is today's id for a nil salt and its own for each salt" do
      id = described_class.send_id("validate", "t", "x")

      expect(described_class.send_id("validate", "t", "x", nil)).to eq(id)
      salted = [described_class.send_id("validate", "t", "x", "t1"), described_class.send_id("validate", "t", "x", "t2")]
      expect(salted).to all(match(/\As-[0-9a-f]{6}\z/))
      expect(salted.uniq.length).to eq(2)
      expect(salted).not_to include(id)
      expect(described_class.send_id("validate", "t", "x", "t1")).to eq(salted.first)
    end

    it "takes a parse_output re" do
      fetched = Samagotchi::ContextSources.parse_output(
        JSON.generate(text: "ok", re: described_class.send_id("validate", "t", "x"))
      )
      expect(fetched.re).to eq(described_class.send_id("validate", "t", "x"))
    end
  end

  describe "the tool's refs" do
    # A chi that keeps the tool's keywords and ignores the rest of #register.
    let(:chi) do
      Class.new do
        def tools = (@tools ||= {})
        def tool(name, _description, **keywords, &block) = tools[name] = keywords.merge(block: block)
        def method_missing(*, **) = nil
        def respond_to_missing?(*) = true
      end.new
    end

    before { plugin.register(chi) }

    it "caps a tool ref's untrusted kind label" do
      ref = chi.tools["echo_send"][:refs].call("kind" => "x" * 200).first
      expect(ref[:label]).to eq("Echo · #{"x" * 40}")
    end

    it "is one inert peer ref (no actions) naming the send id of the call's args, labelled by peer and kind" do
      args = { "kind" => "validate", "title" => "step 2", "text" => "is it right?" }
      refs = chi.tools["echo_send"][:refs].call(args)

      expect(refs).to eq([{ kind: "peer", target: { id: described_class.send_id("validate", "step 2", "is it right?") },
                            label: "Echo · validate" }])
      expect(Samagotchi::Ref.from(refs.first).to_h).to eq(refs.first.merge(actions: []))
    end

    # The block runs on ToolRunner's thread with the run's id as ctx.tool_id
    # (ToolIds.with_current): here as ToolRunner#dispatch sets it.
    def run_tool(args, tool_id)
      ref = chi.tools["echo_send"][:refs].call(args, tool_id).first.dig(:target, :id)
      Samagotchi::ToolIds.with_current(tool_id) { chi.tools["echo_send"][:block].call(args, ctx) }
      [ref, plugin.posted.last.last.lines[1]]
    end

    it "gives two equal calls of their own runs ids of their own, each the ref: line its send carried" do
      pair
      args = { "kind" => "validate", "title" => "step 2", "text" => "is it right?" }

      first_ref, first_line = run_tool(args, "t3")
      second_ref, second_line = run_tool(args, "t5")

      expect(first_ref).not_to eq(second_ref)
      expect(first_line).to eq("ref: #{first_ref}\n")
      expect(second_line).to eq("ref: #{second_ref}\n")
      expect([first_ref, second_ref]).to eq([described_class.send_id("validate", "step 2", "is it right?", "t3"),
                                             described_class.send_id("validate", "step 2", "is it right?", "t5")])
      expect(Samagotchi::PeerExchanges.read(session.id, state_dir: state_dir).map { |line| line["id"] })
        .to eq([first_ref, second_ref])
    end

    it "keeps today's content id, on the row and the ref: line, for a run with no tool id" do
      pair
      args = { "kind" => "validate", "title" => "step 2", "text" => "is it right?" }

      expect(run_tool(args, nil)).to eq([described_class.send_id("validate", "step 2", "is it right?"),
                                         "ref: #{described_class.send_id("validate", "step 2", "is it right?")}\n"])
    end

    it "names the id the posted message carries, also for a title deliver cuts" do
      pair
      args = { "kind" => "question", "title" => "  a  long\ntitle ", "text" => "why?" }
      id = chi.tools["echo_send"][:refs].call(args).first.dig(:target, :id)

      result = chi.tools["echo_send"][:block].call(args, ctx)

      expect(plugin.posted.last.last.lines[1]).to eq("ref: #{id}\n")
      expect(result).to eq("sent to Echo: question · a long title. Echo's answer comes as a note with its " \
                           "text (echo-outbox); don't wait or poll.")
    end
  end

  it "writes a long part to a payload file and posts its path" do
    pair
    text = "x\n" * 3_000

    result = plugin.deliver(ctx, kind: "context", title: "", text: text)

    lines = plugin.posted.last.last.lines
    expect(lines[1]).to eq("ref: #{described_class.send_id("context", "", text)}\n")
    path = lines[2][/\Apayload: (\S+) \(3000 lines, 6000 chars\)\z/, 1]
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
    expect(Samagotchi::PeerExchanges.read(session.id, state_dir: state_dir)).to be_empty
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

  describe "#pair_again, a continue's link asking the peer to pair again (its quiet init task)" do
    let(:previous) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                         .tap { |s| s.save(state_dir: state_dir) }
    end
    let(:previous_loc) { Samagotchi::ContextSources.session_location(previous.id, state_dir: state_dir) }
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir,
                                      continues: previous.id).tap { |s| s.save(state_dir: state_dir) }
    end
    let(:moved) do
      "chi #{previous.id[0, 8]} · moved · continued as #{session.id}\nThis chi session was continued as " \
        "#{session.id}. Pair with #{session.id} the way you paired with #{previous.id[0, 8]}, then answer there " \
        "(chi context push echo-outbox #{session.id})."
    end

    def leave(name, hint)
      previous_loc.add(Samagotchi::ContextSources::Source.new(name: name, cmd: nil, every_seconds: nil, why: "Echo",
                                                              hint: "echo:first", scope: "session", added_by: "cli",
                                                              created_at: Time.now.utc.iso8601))
      previous_loc.record_text(name, Samagotchi::ContextSources::Fetched.new(text: "x", summary: nil, wake: false,
                                                                             hint: hint))
    end

    def continue! = Samagotchi::ContextSources.move(from: previous.id, to: session.id, mode: :continue,
                                                    state_dir: state_dir)

    it "posts the moved message to the inbox left behind (its last pushed hint), once across a worker restart" do
      leave("echo-inbox", "echo:again")
      leave("echo-outbox", nil)
      continue!

      expect(plugin.pair_again(ctx)).to eq("asked Echo to pair again with #{session.id[0, 8]}")
      expect(plugin.posted).to eq([["echo:again", moved]])

      restarted = peer_class.new({})
      expect(restarted.pair_again(ctx)).to eq("asked already")
      expect(restarted.posted).to be_nil
    end

    it "posts nothing on a plain start, or when only the outbox stayed" do
      plain = Samagotchi::Plugin::Context.new(bundle: "echo-peer", label: "l", settings: {}, env: { "XDG_STATE_HOME" => state_home },
                                              host: Samagotchi::Plugin::Host.new(session_id: -> { previous.id },
                                                                                 cwd: -> { tmpdir },
                                                                                 state_dir: -> { state_dir }))
      expect(plugin.pair_again(plain)).to eq("not a continue")

      leave("echo-outbox", nil)
      continue!
      expect(plugin.pair_again(ctx)).to eq("no echo-inbox left behind")
      expect(plugin.posted).to be_nil
    end

    it "logs a post that fails and drops it: no raise, no retry" do
      leave("echo-inbox", "elsewhere")
      continue!
      expect(ctx.log).to receive(:warn).with("moved_not_posted", error: "bad hint elsewhere")

      expect(plugin.pair_again(ctx)).to eq("couldn't ask Echo to pair again: bad hint elsewhere")
      expect(plugin.pair_again(ctx)).to eq("asked already")
      expect(plugin.posted).to be_nil
    end
  end

  it "names the hook a subclass left out" do
    pair
    peer_class.send(:remove_method, :post)

    expect { plugin.deliver(ctx, kind: "validate", title: "t", text: "x") }.to raise_error(NotImplementedError, /#post/)
    expect { plugin.send(:status, ctx) }.to raise_error(NotImplementedError, /#paired_lines/)
  end
end
