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

    context "with a session not saved yet (its first turn hasn't run)" do
      let(:session_id) { "aaaabbbb-1111-2222-3333-444455556666" }

      it "finds no Claude paired, in the tool and the card" do
        expect(send_part(kind: "validate", title: "t", text: "x")).to start_with("Error: no claude-inbox: pair from Claude")

        fake_chi.commands.fetch("/claude").last.call("", ctx)
        expect(cards.last[:title]).to eq("claude-peer: not paired")
      end
    end
  end

  describe "/claude" do
    def run(args = "") = fake_chi.commands.fetch("/claude").last.call(args, ctx)
    def hook(event, payload) = fake_chi.hooks.fetch(event).last.call(payload)

    def sent_content(args)
      server, thread, received = listen
      result = run(args)
      thread.join(5)
      server.close
      File.unlink(socket)
      [result, received.empty? ? nil : JSON.parse(received.pop).dig("message", "content")]
    end

    def review(text, summary)
      own.add(Samagotchi::ContextSources::Source.new(name: "claude-review", cmd: nil, every_seconds: nil, why: "answers",
                                                     hint: "latest Claude reply", scope: "session", added_by: "cli",
                                                     created_at: Time.now.utc.iso8601))
      own.record_text("claude-review", Samagotchi::ContextSources::Fetched.new(text: text, summary: summary, wake: true,
                                                                               hint: nil))
    end

    it "is an anytime command, and the plugin watches turns start and end" do
      expect(fake_chi.commands.fetch("/claude").first).to be(true)
      expect(fake_chi.hooks.keys).to contain_exactly(:before_turn, :after_turn)
    end

    it "adds a Confirm with Claude pill (a fill, the quote) on a chi with chi.annotation, and loads without it" do
      annotations = []
      newer = fake_chi.dup
      newer.define_singleton_method(:annotation) { |label, **opts| annotations << [label, opts] }
      plugin.register(newer)

      expect(annotations).to eq([["Confirm with Claude", { command: "/claude validate" }]])
      expect(fake_chi).not_to respond_to(:annotation)
      expect(fake_chi.commands).to have_key("/claude")
    end

    describe "alone: the status card" do
      it "says how to pair when no Claude is paired; no text of its own" do
        expect(run).to be_nil

        card = cards.last
        expect(card).to include(id: "claude", title: "claude-peer: not paired")
        expect(card[:body]).to include("**not paired.**", "\"pair with chi #{short}\"", "checked on Claude Code 2.1.296")
        expect(card[:actions]).to eq([{ label: "Refresh", command: "/claude" },
                                      { label: "Install skill", command: "/claude install-skill" }])
      end

      it "shows the socket and that it is there, the last send and Claude's last answer" do
        pair
        received_lines(kind: "validate", title: "step 2", text: "check it")
        review("VERDICT: OK", "validate step 2: VERDICT OK")
        server = UNIXServer.new(socket)

        run

        card = cards.last
        expect(card[:title]).to eq("claude-peer: paired")
        expect(card[:body]).to include("socket: `#{socket}` (there)", "last send: just now · validate · step 2 (8 chars, inline)",
                                       "last answer (claude-review): validate step 2: VERDICT OK · just now")
      ensure
        server&.close
      end

      it "says the socket is missing when Claude's session is gone" do
        pair

        run

        expect(cards.last[:body]).to include("(**missing**: that Claude session ended or restarted, pair again)")
      end
    end

    it "validate and context send the text as it is, titled by its first line" do
      pair

      result, content = sent_content("validate Step 3 keeps the old key\n\n- lib/a.rb:12\n- lib/b.rb:40")
      expect(result).to eq("sent to Claude: validate · Step 3 keeps the old key; Claude's answer comes as the claude-review context")
      expect(content).to eq("chi #{short} · validate · Step 3 keeps the old key\nStep 3 keeps the old key\n\n- lib/a.rb:12\n- lib/b.rb:40")

      _, content = sent_content("context we chose Redis")
      expect(content).to eq("chi #{short} · context · we chose Redis\nwe chose Redis")
    end

    it "titles a pill's quote by its first quoted line, not the From …: label" do
      pair

      result, content = sent_content("validate\nFrom your thinking:\n>   the key stays\n> two\n\nis it?")
      expect(result).to start_with("sent to Claude: validate · the key stays;")
      expect(content).to eq("chi #{short} · validate · the key stays\nFrom your thinking:\n>   the key stays\n> two\n\nis it?")

      _, content = sent_content("validate\n> an answer line\n\nok?")
      expect(content.lines.first).to eq("chi #{short} · validate · an answer line\n")

      _, content = sent_content("validate From now on we use Redis:\n- lib/a.rb")
      expect(content.lines.first).to eq("chi #{short} · validate · From now on we use Redis:\n")
    end

    it "says why a send failed, and gives usage for nothing to send or an unknown verb" do
      expect(run("validate x")).to start_with("/claude: no claude-inbox: pair from Claude")
      expect(run("validate")).to start_with("usage: /claude")
      expect(run("frob")).to start_with("usage: /claude")
      expect(run("last now")).to start_with("usage: /claude")
    end

    describe "last" do
      let(:history) do
        [{ role: "user", content: "plan it" }, { role: "model", content: "<think>hmm</think>The plan: three steps." }]
      end

      before { pair }

      it "sends the last completed answer as context, without its thinking" do
        hook(:before_turn, { messages: [] })
        hook(:after_turn, { status: "completed", messages: history })

        result, content = sent_content("last")

        expect(result).to eq("sent to Claude: context · chi's last answer: The plan: three steps.")
        expect(content).to eq("chi #{short} · context · chi's last answer: The plan: three steps.\nThe plan: three steps.")
      end

      it "mid-turn, sends the answer before the running turn, not the turn's partial text" do
        hook(:after_turn, { status: "completed", messages: history })
        hook(:before_turn, { messages: history })
        messages.replace(history + [{ role: "user", content: "now do it" }, { role: "model", content: "Doing step one, then" }])

        _, content = sent_content("last")

        expect(content).to end_with("\nThe plan: three steps.")
      end

      it "after a restart (no turn seen), reads the conversation" do
        messages.replace(history + [{ role: "system", kind: "context", content: "[CONTEXT NOTE …]" }])

        _, content = sent_content("last")

        expect(content).to end_with("\nThe plan: three steps.")
      end

      it "keeps the last completed answer when a later turn was cancelled" do
        hook(:after_turn, { status: "completed", messages: history })
        hook(:before_turn, { messages: history })
        hook(:after_turn, { status: "canceled", messages: history + [{ role: "user", content: "more" },
                                                                     { role: "model", content: "Half" },
                                                                     { role: "system", kind: "turn_note", content: "[SYSTEM: …]" }] })

        _, content = sent_content("last")

        expect(content).to end_with("\nThe plan: three steps.")
      end

      it "says so when there is no completed answer" do
        messages.replace([{ role: "user", content: "go" }, { role: "system", kind: "turn_note", content: "[SYSTEM: …]" }])

        expect(run("last")).to start_with("/claude last: no completed answer to send yet")
      end
    end

    describe "install-skill" do
      let(:claude_dir) { File.join(tmpdir, "claude") }
      let(:target) { File.join(claude_dir, "skills", "chi-peer", "SKILL.md") }

      around { |example| with_env("CLAUDE_CONFIG_DIR" => claude_dir) { example.run } }

      it "shows a card with the target, an Install action and the Read rule to offer, writing nothing" do
        expect(run("install-skill")).to be_nil

        card = cards.last
        expect(card).to include(id: "claude-skill", title: "Claude's chi-peer skill",
                                actions: [{ label: "Install", command: "/claude install-skill --yes" }])
        expect(card[:body]).to include("target: `#{target}`", "Not installed yet.", "Read(#{data_dir}/**)",
                                       "chi doesn't change Claude's settings")
        expect(File.exist?(target)).to be(false)
      end

      it "--yes installs it with this bundle's pair script and payload folder written in; then it is up to date" do
        expect(run("install-skill --yes")).to be_nil

        text = File.read(target)
        expect(text).to start_with("---\nname: chi-peer\n")
        expect(text).to include("sh \"#{File.join(shipped, "scripts", "pair")}\" <chi session id or URL>",
                                "Read(#{data_dir}/**)")
        expect(text).not_to include("__CHI_PEER")
        expect(cards.last[:body]).to include("Installed `#{target}`")

        run("install-skill")
        expect(cards.last).to include(actions: [])
        expect(cards.last[:body]).to include("Installed and up to date.")
      end

      it "shows a short diff when the installed skill differs, and Replace" do
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, "---\nname: chi-peer\n---\nmy own version\n")

        run("install-skill")

        card = cards.last
        expect(card[:actions]).to eq([{ label: "Replace", command: "/claude install-skill --yes" }])
        expect(card[:body]).to include("Installed, and different from this bundle's", "```diff\n--- installed\n+++ this bundle's",
                                       "-my own version", "more lines")
      end
    end
  end
end
