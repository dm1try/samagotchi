# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "socket"
require "samagotchi/plugin/context"
require "samagotchi/context_sources"

# The claude-peer bundle's plugin (lib/samagotchi/bundles/claude-peer):
# claude_send writes one JSON line to the paired Claude Code session's
# inbox socket (the claude-inbox context's hint). Here the socket is a
# UNIXServer in a tmpdir, never a real Claude.
RSpec.describe "The claude-peer plugin" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/claude-peer", __dir__) }
  # A short dir: a socket path has a ~104-byte limit.
  let(:tmpdir) { Dir.mktmpdir("cp", "/tmp") }
  let(:state_home) { File.join(tmpdir, "state") }
  let(:state_dir) { File.join(state_home, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                       .tap { |s| s.save(state_dir: state_dir) }
  end
  let(:session_id) { session.id }
  let(:short) { session.id[0, 8] }
  let(:cards) { [] }
  let(:messages) { [] }
  let(:host) do
    Samagotchi::Plugin::Host.new(session_id: -> { session_id }, cwd: -> { tmpdir }, state_dir: -> { state_dir },
                                 messages: -> { messages }, card: ->(**card) { cards << card and card[:id] })
  end
  let(:ctx) do
    Samagotchi::Plugin::Context.new(bundle: "claude-peer", label: "plugin.rb (bundle claude-peer)", settings: {},
                                    host: host, env: { "XDG_STATE_HOME" => state_home })
  end
  let(:namespace) { Module.new.tap { |n| n.module_eval(File.read(File.join(shipped, "plugin.rb")), File.join(shipped, "plugin.rb"), 1) } }
  let(:plugin) { namespace.const_get(:Plugin).new({}) }
  # What register declares: the tools and commands, by name.
  let(:fake_chi) do
    Class.new do
      attr_reader :tools, :commands, :hooks

      def initialize
        @tools = {}
        @commands = {}
        @hooks = {}
      end

      def tool(name, description, params:, label:, preview:, &block)
        @tools[name] = { description: description, params: params, label: label, preview: preview, block: block }
      end

      def command(name, _description, anytime: false, &block)
        @commands[name] = [anytime, block]
      end

      def on(event, priority: 100, &block)
        @hooks[event] = [priority, block]
      end
    end.new.tap { |chi| plugin.register(chi) }
  end
  let(:socket) { File.join(tmpdir, "inbox.sock") }
  let(:data_dir) { File.join(state_home, "samagotchi", "plugins", "claude-peer") }

  after { FileUtils.rm_rf(tmpdir) }

  def own = Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir)

  def pair(hint = socket)
    own.add(Samagotchi::ContextSources::Source.new(name: "claude-inbox", cmd: nil, every_seconds: nil, why: "Claude",
                                                   hint: hint, scope: "session", added_by: "cli",
                                                   created_at: Time.now.utc.iso8601))
  end

  # A stand-in for Claude's inbox: takes one connection, keeps what came.
  def listen
    server = UNIXServer.new(socket)
    received = Queue.new
    thread = Thread.new do
      conn = server.accept
      received << conn.read
      conn.close
    end
    [server, thread, received]
  end

  def send_part(**args)
    fake_chi.tools.fetch("claude_send")[:block].call(args.transform_keys(&:to_s).freeze, ctx)
  end

  # Sends with a listening inbox; the lines that came.
  def received_lines(**args)
    server, thread, received = listen
    result = send_part(**args)
    thread.join(5)
    server.close
    File.unlink(socket)
    [result, received.empty? ? nil : received.pop.lines]
  end

  it "declares claude_send whether or not Claude is paired, with a fixed label and the title as its preview" do
    tool = fake_chi.tools.fetch("claude_send")

    expect(tool[:label]).to eq("sent to Claude")
    expect(tool[:params].keys).to eq(%i[kind title text])
    expect(tool[:params][:kind][:enum]).to eq(%w[validate context question])
    expect(tool[:preview].call("kind" => "validate", "title" => "cache step 2")).to eq("validate: cache step 2")
    expect(tool[:description]).to include("Only when the user asks", "claude-review")
  end

  it "writes one JSON line to the inbox: the header, then a short text inline" do
    pair

    result, lines = received_lines(kind: "validate", title: "Step 2: the cache key", text: "Is the key stable?\nsee lib/a.rb")

    expect(result).to start_with("sent to Claude: validate · Step 2: the cache key. Claude's answer comes as an update")
    expect(lines.size).to eq(1)
    expect(lines.first).to end_with("\n")
    expect(JSON.parse(lines.first)).to eq(
      "type" => "user",
      "message" => { "role" => "user", "content" => "chi #{short} · validate · Step 2: the cache key\nIs the key stable?\nsee lib/a.rb" }
    )
  end

  it "puts a long text in a payload file under sessions/<id>/ and sends its path" do
    pair
    text = "#{"line of the plan\n" * 300}end"

    result, lines = received_lines(kind: "context", title: "The whole plan, r3!", text: text)

    content = JSON.parse(lines.first).dig("message", "content")
    header, payload = content.lines.map(&:chomp)
    expect(header).to eq("chi #{short} · context · The whole plan, r3!")
    path = payload[/\Apayload: (\S+) \(301 lines, #{text.length} chars\)\z/, 1]
    expect(path).to match(%r{\A#{Regexp.escape(File.join(data_dir, "sessions", session.id))}/\d{6}-the-whole-plan-r3\.md\z})
    expect(File.read(path)).to eq(text)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
    expect(result).to include("(the text in #{path})", "Claude takes it in")
  end

  it "keeps two payloads sent in the same second apart" do
    pair
    text = "x" * 5000
    2.times { received_lines(kind: "context", title: "same", text: text) }

    expect(Dir.children(File.join(data_dir, "sessions", session.id)).grep(/\.md\z/).size).to eq(2)
  end

  it "records the last send for the /claude card" do
    pair
    received_lines(kind: "question", title: "why  this\nname?", text: "why?")

    last = JSON.parse(File.read(File.join(data_dir, "sessions", session.id, "last-send.json")))
    expect(last).to include("kind" => "question", "title" => "why this name?", "chars" => 4, "payload" => nil)
  end

  it "titles a part by its text's first line when the title is empty" do
    pair

    _, lines = received_lines(kind: "validate", title: " ", text: "check this\nand that")

    expect(JSON.parse(lines.first).dig("message", "content")).to start_with("chi #{short} · validate · check this\n")
  end

  describe "errors" do
    it "says how to pair when no claude-inbox is attached" do
      expect(send_part(kind: "validate", title: "t", text: "x"))
        .to eq("Error: no claude-inbox: pair from Claude (install its skill with /claude install-skill, then tell " \
               "Claude \"pair with chi #{short}\")")
    end

    it "says the Claude session is gone when its socket is" do
      pair

      expect(send_part(kind: "validate", title: "t", text: "x"))
        .to eq("Error: that Claude session is gone (no inbox at #{socket}): pair again from Claude")
    end

    it "says the Claude session is gone when nothing listens on its socket" do
      pair
      UNIXServer.new(socket).close # the file stays, nobody listens

      expect(send_part(kind: "validate", title: "t", text: "x")).to start_with("Error: that Claude session is gone")
    end

    it "refuses a text over the cap, an empty one and an unknown kind, sending nothing" do
      pair

      expect(send_part(kind: "validate", title: "t", text: "x" * 200_001))
        .to eq("Error: the text is 200001 chars, over 200000: send a part, not a session")
      expect(send_part(kind: "validate", title: "t", text: "  \n")).to eq("Error: nothing to send: the text is empty")
      expect(send_part(kind: "review", title: "t", text: "x")).to eq("Error: kind must be one of validate, context, question")
    end

    context "with no session yet" do
      let(:session_id) { nil }

      it "says so" do
        expect(send_part(kind: "validate", title: "t", text: "x"))
          .to eq("Error: this session has no id yet: send after its first turn")
      end
    end
  end
end
