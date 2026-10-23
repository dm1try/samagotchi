# frozen_string_literal: true

require "tmpdir"
require "json"
require "socket"
require "samagotchi/testing/rspec"
require "samagotchi/context_sources"

# Byte-for-byte goldens of every text the claude-peer and codex-peer plugins
# show the model or the user: what register declares (the tool description is
# in the system prompt), each send's result and message, every send error,
# the /claude and /codex replies, the status and skill cards and the skill
# they install. They pin the two bundles' shared Samagotchi::Plugin::Peer base
# (docs/plugins.md) to what the bundles said before it.
#
# Paths, the session id and payload times are written as <TMP>, <ID>, <SHORT>
# and HHMMSS. Regenerate after an intended change with:
#   UPDATE_GOLDENS=1 bundle exec rspec lib/samagotchi/bundles/claude-peer/spec/peer_goldens_spec.rb
RSpec.describe "Peer bundle goldens", :bundle do
  # What register declared, in order, each as written (bundle.declarations):
  # the tool's params as given and its preview called on a part.
  def declared
    bundle.declarations.map do |decl|
      name, description = decl.args
      options = decl.options
      case decl.name
      when :tool
        { tool: name, description: description, params: options[:params], label: options[:label],
          preview: options[:preview].call("kind" => "validate", "title" => "cache step 2") }
      when :command then { command: name, description: description, anytime: options.fetch(:anytime, false) }
      when :annotation then { annotation: name, **options }
      when :peer_source then { peer_source: name, label: options[:label] }
      when :on then { hook: name, priority: options.fetch(:priority, 100) }
      else raise "#{decl.name}: not in the goldens yet"
      end
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
  let(:messages) { [] }
  let(:shipped) { File.expand_path("../../#{peer}-peer", __dir__) }
  # The plugin as chi loads it, for this session.
  let(:bundle) do
    shipped_bundle("#{peer}-peer", host: { session_id: session_id, cwd: tmpdir, state_dir: state_dir, messages: messages })
  end
  let(:plugin_class) { bundle.namespace::Plugin }
  let(:out) { +"" }
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }

  # Under the sandbox, the paths the goldens hold: <TMP>/home, its state.
  # The sandbox puts ENV back.
  before do
    ENV.update("HOME" => home, "XDG_STATE_HOME" => state_home)
    %w[CLAUDE_CONFIG_DIR CODEX_HOME CODEX].each { |key| ENV.delete(key) }
  end

  # Set ENV for the block (nil unsets), then put it back.
  def with_vars(vars)
    saved = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end

  after { FileUtils.rm_rf(tmpdir) }

  def expect_golden(name)
    path = File.expand_path("fixtures/peer_goldens/#{peer}_#{name}.txt", __dir__)
    if ENV["UPDATE_GOLDENS"] == "1"
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, out)
    end
    expect(out).to eq(File.read(path))
  end

  def normalize(text)
    # The checkout's own path: a worktree's differs from main's and CI's.
    text.to_s.gsub(File.expand_path("../../../../..", __dir__), "<REPO>").gsub(File.realpath(tmpdir), "<TMP>").gsub(tmpdir, "<TMP>").gsub(session.id, "<ID>")
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

  # The block run before the session has an id.
  def without_id
    bundle.set(session_id: nil)
    yield
  ensure
    bundle.set(session_id: session_id)
  end

  def tool(**args) = bundle.tool("#{peer}_send", args)
  def command(args) = bundle.command("/#{peer} #{args}")

  # Each reply, then the card it showed (if any).
  def run_command(title, args, no_id: false)
    shown = bundle.cards.size
    reply = no_id ? without_id { command(args) } : command(args)
    section("#{"/#{peer} #{args}".strip} (#{title})", reply.inspect)
    # As the plugin's ctx.card passed it on (Context#card's keywords).
    bundle.cards.drop(shown).each { |card| section("card", card.slice(:source, :title, :body, :actions, :level, :id)) }
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
    section("no session id", without_id { tool(kind: "validate", title: "t", text: "x") })
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
    run_command("no session yet", "", no_id: true)
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
    target = File.join(home, ".#{peer}", "skills", "chi-peer", "SKILL.md")
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, "a skill the user wrote\n")
    run_command("paired, the installed skill differs", "")
    FileUtils.rm_rf(File.dirname(target))
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
      wait_for("a message on the inbox socket", timeout: 10) { received.size.positive? || !thread.alive? }
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
      declared.each { |decl| section(decl.keys.first.to_s, decl) }
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

    def fake_codex(body) = Samagotchi::Testing::FakeExecutable.write(bin, "codex", body)

    def queue_ok = fake_codex("printf '%s\\0' \"$@\" >> '#{args_file}'\necho \"Queued.\"\n")

    def sent(title, **args)
      FileUtils.rm_f(args_file)
      section(title, tool(**args))
      section("queued", File.read(args_file).split("\0").inspect) if File.exist?(args_file)
    end

    before do
      ENV["CODEX"] = File.join(tmpdir, "bin", "codex")
      queue_ok
    end

    it "keeps what register declares" do
      declared.each { |decl| section(decl.keys.first.to_s, decl) }
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
      with_vars("CODEX" => File.join(tmpdir, "no-codex")) do
        section("no CLI there", tool(kind: "validate", title: "t", text: "x"))
      end
      with_vars("CODEX" => nil, "PATH" => File.join(tmpdir, "empty")) do
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
