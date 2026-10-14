# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "socket"
require "samagotchi/plugin/context"
require "samagotchi/context_sources"
require_relative "../../support/fake_executables"

# Byte-for-byte goldens of every text the claude-peer and codex-peer plugins
# show the model or the user: what register declares (the tool description is
# in the system prompt), each send's result and message, every send error,
# the /claude and /codex replies, the status and skill cards and the skill
# they install. They pin the two bundles' shared Samagotchi::Plugin::Peer base
# (docs/plugins.md) to what the bundles said before it.
#
# Paths, the session id and payload times are written as <TMP>, <ID>, <SHORT>
# and HHMMSS. Regenerate after an intended change with:
#   UPDATE_GOLDENS=1 bundle exec rspec spec/samagotchi/bundles/peer_goldens_spec.rb
RSpec.describe "Peer bundle goldens" do
  # register's declarations, kept in order.
  let(:fake_chi_class) do
    Class.new do
      attr_reader :declared, :tools, :commands

      def initialize
        @declared = []
        @tools = {}
        @commands = {}
      end

      def tool(name, description, params:, label:, preview:, &block)
        @tools[name] = block
        @declared << { tool: name, description: description, params: params, label: label,
                       preview: preview.call("kind" => "validate", "title" => "cache step 2") }
      end

      def command(name, description, anytime: false, &block)
        @commands[name] = block
        @declared << { command: name, description: description, anytime: anytime }
      end

      def annotation(label, **opts) = @declared << { annotation: label, **opts }

      def peer_source(name, label:) = @declared << { peer_source: name, label: label }

      def on(event, priority: 100, &) = @declared << { hook: event, priority: priority }
    end
  end

  # A short dir: a socket path has a ~104-byte limit.
  let(:tmpdir) { Dir.mktmpdir("pg", "/tmp") }
  let(:home) { File.join(tmpdir, "home").tap { |d| FileUtils.mkdir_p(d) } }
  let(:state_home) { File.join(home, "state") }
  let(:state_dir) { File.join(state_home, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                       .tap { |s| s.save(state_dir: state_dir) }
  end
  let(:session_id) { session.id }
  let(:cards) { [] }
  let(:messages) { [] }
  let(:host) do
    Samagotchi::Plugin::Host.new(session_id: -> { session_id }, cwd: -> { tmpdir }, state_dir: -> { state_dir },
                                 messages: -> { messages }, card: ->(**card) { cards << card and card[:id] })
  end
  let(:ctx) do
    Samagotchi::Plugin::Context.new(bundle: "#{peer}-peer", label: "plugin.rb (bundle #{peer}-peer)", settings: {},
                                    host: host, env: { "XDG_STATE_HOME" => state_home })
  end
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/#{peer}-peer", __dir__) }
  let(:plugin_class) do
    path = File.join(shipped, "plugin.rb")
    Module.new.tap { |n| n.module_eval(File.read(path), path, 1) }.const_get(:Plugin)
  end
  let(:plugin) { plugin_class.new({}) }
  let(:chi) { fake_chi_class.new.tap { |chi| plugin.register(chi) } }
  let(:out) { +"" }
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }

  around do |example|
    with_env("HOME" => home, "CLAUDE_CONFIG_DIR" => nil, "CODEX_HOME" => nil, "CODEX" => nil) { example.run }
  end

  after { FileUtils.rm_rf(tmpdir) }

  def expect_golden(name)
    path = File.expand_path("../../fixtures/peer/goldens/#{peer}_#{name}.txt", __dir__)
    if ENV["UPDATE_GOLDENS"] == "1"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, out)
    end
    expect(out).to eq(File.read(path))
  end

  def normalize(text)
    # The checkout's own path: a worktree's differs from main's and CI's.
    text.to_s.gsub(File.expand_path("../../..", __dir__), "<REPO>").gsub(File.realpath(tmpdir), "<TMP>").gsub(tmpdir, "<TMP>").gsub(session.id, "<ID>")
        .gsub(session.id[0, 8], "<SHORT>").gsub(%r{/\d{6}-}, "/HHMMSS-")
  end

  def section(title, value)
    text = value.is_a?(String) ? value : JSON.pretty_generate(value)
    out << "=== #{title}\n#{normalize(text)}\n"
  end

  def add_source(name, hint)
    own.add(Samagotchi::ContextSources::Source.new(name: name, cmd: nil, every_seconds: nil, why: "peer", hint: hint,
                                                   scope: "session", added_by: "cli", created_at: Time.now.utc.iso8601))
  end

  def pair(hint = good_hint) = add_source("#{peer}-inbox", hint)

  def outbox(summary)
    add_source("#{peer}-outbox", "latest answer") unless own.source("#{peer}-outbox")
    return unless summary

    own.record_text("#{peer}-outbox", Samagotchi::ContextSources::Fetched.new(text: "answer", summary: summary,
                                                                              wake: true, hint: nil))
  end

  # A context before the session has an id.
  def no_id_ctx
    Samagotchi::Plugin::Context.new(
      bundle: "#{peer}-peer", label: "plugin.rb (bundle #{peer}-peer)", settings: {},
      env: { "XDG_STATE_HOME" => state_home },
      host: Samagotchi::Plugin::Host.new(session_id: -> {}, cwd: -> { tmpdir }, state_dir: -> { state_dir },
                                         messages: -> { [] }, card: ->(**card) { cards << card and card[:id] })
    )
  end

  def tool(context = ctx, **args) = chi.tools.fetch("#{peer}_send").call(args.transform_keys(&:to_s).freeze, context)
  def command(args, context = ctx) = chi.commands.fetch("/#{peer}").call(args, context)

  # Each reply, then the card it showed (if any).
  def run_command(title, args, context = ctx)
    cards.clear
    section("#{"/#{peer} #{args}".strip} (#{title})", command(args, context).inspect)
    cards.each { |card| section("card", card) }
  end

  def last_send
    path = File.join(state_home, "samagotchi", "plugins", "#{peer}-peer", "sessions", session.id, "last-send.json")
    File.exist?(path) ? JSON.parse(File.read(path)).merge("at" => "<AT>") : nil
  end

  def long_text = "#{"line of the plan\n" * 300}end"

  def errors_common
    section("unknown kind", tool(kind: "review", title: "t", text: "x"))
    section("empty text", tool(kind: "validate", title: "t", text: "  \n"))
    section("over the cap", tool(kind: "validate", title: "t", text: "x" * 200_001))
    section("not paired", tool(kind: "validate", title: "t", text: "x"))
    section("no session id", tool(no_id_ctx, kind: "validate", title: "t", text: "x"))
  end

  def commands_common
    run_command("unknown verb", "bogus")
    run_command("no text", "validate")
    run_command("last with text", "last now")
    run_command("not paired", "validate check this")
    run_command("no answer yet", "last")
    pair
    run_command("a quote", "validate From your thinking:\n> the cache key is stable\nconfirm")
    section("last send", last_send)
    run_command("context", "context  some background")
    messages.replace([{ role: "user", content: "hi" },
                      { role: "model", content: "<think>hmm</think>The fix is in lib/a.rb.\nIt keeps the key." }])
    run_command("the last answer", "last")
    section("last send", last_send)
  end

  def cards_common
    run_command("no session yet", "", no_id_ctx)
    run_command("not paired", "")
    pair
    outbox(nil)
    run_command("paired, no answer yet", "")
  end

  def cards_paired_with_history
    outbox("validate step 2: VERDICT OK")
    tool(kind: "context", title: "the plan", text: long_text)
    run_command("paired, a payload send, an answer", "")
    tool(kind: "validate", title: "step 2", text: "short")
    run_command("paired, an inline send", "")
  end

  def skill_cards
    run_command("not installed", "install-skill")
    run_command("install", "install-skill --yes")
    target = File.join(home, ".#{peer}", "skills", "chi-peer", "SKILL.md")
    section("installed skill", File.read(target))
    run_command("up to date", "install-skill")
    File.write(target, File.read(target).sub(/^## .*$/, "## A heading the user changed"))
    run_command("differs", "install-skill")
    run_command("bad flag", "install-skill --no")
    FileUtils.rm_rf(File.dirname(target))
    FileUtils.chmod(0o500, File.dirname(target, 2))
    run_command("can't write", "install-skill --yes")
    FileUtils.chmod(0o700, File.dirname(target, 2))
    plugin_class.send(:remove_const, :SCRIPTS_DIRS)
    plugin_class.const_set(:SCRIPTS_DIRS, [File.join(tmpdir, "nowhere")].freeze)
    run_command("no skill file", "install-skill")
  end

  context "with claude-peer" do
    let(:peer) { "claude" }
    let(:socket) { File.join(tmpdir, "inbox.sock") }
    let(:good_hint) { socket }

    # A stand-in for Claude's inbox, keeping each connection's text.
    def listen
      server = UNIXServer.new(socket)
      received = Queue.new
      thread = Thread.new do
        loop do
          conn = server.accept
          received << conn.read.force_encoding(Encoding::UTF_8)
          conn.close
        end
      rescue IOError, SystemCallError
        nil
      end
      yield
      sleep 0.05 until received.size.positive? || !thread.alive?
      server.close
      thread.join(2)
      File.unlink(socket)
      Array.new(received.size) { received.pop }
    end

    def sent(title, **args)
      result = nil
      lines = listen { result = tool(**args) }
      section(title, result)
      lines.each { |line| section("posted", line) }
    end

    it "keeps what register declares" do
      chi.declared.each { |decl| section(decl.keys.first.to_s, decl) }
      section("USAGE", plugin_class::USAGE)
      expect_golden("register")
    end

    it "keeps each send's result and message, and every send error" do
      errors_common
      pair("relative/socket")
      section("not a socket path", tool(kind: "validate", title: "t", text: "x"))
      own.remove("claude-inbox")
      pair
      section("gone", tool(kind: "validate", title: "t", text: "x"))
      sent("validate", kind: "validate", title: "Step 2: the cache key", text: "Is the key stable?\nsee lib/a.rb")
      sent("context", kind: "context", title: "background", text: "some background")
      sent("question", kind: "question", title: "why  this\nname?", text: "why?")
      sent("no title", kind: "validate", title: " ", text: "check this\nand that")
      sent("payload", kind: "context", title: "The whole plan, r3!", text: long_text)
      section("last send", last_send)
      expect_golden("sends")
    end

    it "keeps the /claude replies" do
      listen { commands_common }
      expect_golden("commands")
    end

    it "keeps the status card in each state" do
      cards_common
      run_command("paired, socket missing", "")
      listen { cards_paired_with_history }
      expect_golden("status")
    end

    it "keeps the skill card in each state, and the skill" do
      skill_cards
      expect_golden("skill")
    end
  end

  context "with codex-peer" do
    let(:peer) { "codex" }
    let(:good_hint) { "019a1b2c-3d4e-7f80-9abc-def012345678" }
    let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
    let(:args_file) { File.join(tmpdir, "codex-args") }

    def fake_codex(body) = FakeExecutables.fake_executable(bin, "codex", body)

    def queue_ok = fake_codex("printf '%s\\0' \"$@\" >> '#{args_file}'\necho \"Queued.\"\n")

    def sent(title, **args)
      FileUtils.rm_f(args_file)
      section(title, tool(**args))
      section("queued", File.read(args_file).split("\0").inspect) if File.exist?(args_file)
    end

    around { |example| with_env("CODEX" => File.join(tmpdir, "bin", "codex")) { example.run } }

    before { queue_ok }

    it "keeps what register declares" do
      chi.declared.each { |decl| section(decl.keys.first.to_s, decl) }
      section("USAGE", plugin_class::USAGE)
      expect_golden("register")
    end

    it "keeps each send's result and message, and every send error" do
      errors_common
      pair("not-a-thread")
      section("not a thread id", tool(kind: "validate", title: "t", text: "x"))
      own.remove("codex-inbox")
      pair
      fake_codex("echo 'Error: thread is ephemeral' >&2\nexit 1")
      section("ephemeral", tool(kind: "validate", title: "t", text: "x"))
      fake_codex("echo 'Error: no rollout found for thread id x (code -32603)' >&2\nexit 1")
      section("gone", tool(kind: "validate", title: "t", text: "x"))
      fake_codex("echo 'boom: the daemon is down' >&2\nexit 3")
      section("failed", tool(kind: "validate", title: "t", text: "x"))
      fake_codex("exit 4")
      section("failed, no text", tool(kind: "validate", title: "t", text: "x"))
      with_env("CODEX" => File.join(tmpdir, "no-codex")) do
        section("no CLI there", tool(kind: "validate", title: "t", text: "x"))
      end
      with_env("CODEX" => nil, "PATH" => File.join(tmpdir, "empty")) do
        section("no codex on the PATH", tool(kind: "validate", title: "t", text: "x"))
      end
      plugin_class.send(:remove_const, :QUEUE_SECONDS)
      plugin_class.const_set(:QUEUE_SECONDS, 0.3)
      fake_codex("sleep 5")
      section("hangs", tool(kind: "validate", title: "t", text: "x"))
      queue_ok
      sent("validate", kind: "validate", title: "Step 2: the cache key", text: "Is the key stable?\nsee lib/a.rb")
      sent("context", kind: "context", title: "background", text: "some background")
      sent("question", kind: "question", title: "why  this\nname?", text: "why?")
      sent("no title", kind: "validate", title: " ", text: "check this\nand that")
      sent("payload", kind: "context", title: "The whole plan, r3!", text: long_text)
      section("last send", last_send)
      expect_golden("sends")
    end

    it "keeps the /codex replies" do
      commands_common
      section("queued", File.read(args_file).split("\0").inspect)
      expect_golden("commands")
    end

    it "keeps the status card in each state" do
      cards_common
      cards_paired_with_history
      expect_golden("status")
    end

    it "keeps the skill card in each state, and the skill" do
      skill_cards
      expect_golden("skill")
    end
  end
end
