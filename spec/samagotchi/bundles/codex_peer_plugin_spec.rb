# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/plugin/context"
require "samagotchi/context_sources"
require_relative "../../support/fake_executables"

# The codex-peer bundle's plugin (lib/samagotchi/bundles/codex-peer):
# codex_send runs `codex queue --thread <uuid> --message <text>` for the
# paired Codex session (the codex-inbox context's hint). Here `codex` is a
# fake (CODEX=), which records its arguments; never the real Codex CLI.
RSpec.describe "The codex-peer plugin" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/codex-peer", __dir__) }
  let(:tmpdir) { File.realpath(Dir.mktmpdir("codex-peer")) }
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
    Samagotchi::Plugin::Context.new(bundle: "codex-peer", label: "plugin.rb (bundle codex-peer)", settings: {},
                                    host: host, env: { "XDG_STATE_HOME" => state_home })
  end
  let(:namespace) { Module.new.tap { |n| n.module_eval(File.read(File.join(shipped, "plugin.rb")), File.join(shipped, "plugin.rb"), 1) } }
  let(:plugin_class) { namespace.const_get(:Plugin) }
  let(:plugin) { plugin_class.new({}) }
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
  let(:thread_id) { "019a1b2c-3d4e-7f80-9abc-def012345678" }
  let(:data_dir) { File.join(state_home, "samagotchi", "plugins", "codex-peer") }
  let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:args_file) { File.join(tmpdir, "codex-args") }
  # A `codex` that keeps its arguments (NUL-separated) and says it queued.
  let(:codex_body) do
    "printf '%s\\0' \"$@\" > '#{args_file}'\necho \"Queued message 42 for thread $3.\"\n"
  end
  let(:codex) { FakeExecutables.fake_executable(bin, "codex", codex_body) }

  around { |example| with_env("CODEX" => codex) { example.run } }
  after { FileUtils.rm_rf(tmpdir) }

  def own = Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir)

  def pair(hint = thread_id)
    own.add(Samagotchi::ContextSources::Source.new(name: "codex-inbox", cmd: nil, every_seconds: nil, why: "Codex",
                                                   hint: hint, scope: "session", added_by: "cli",
                                                   created_at: Time.now.utc.iso8601))
  end

  def send_part(**args)
    fake_chi.tools.fetch("codex_send")[:block].call(args.transform_keys(&:to_s).freeze, ctx)
  end

  # The arguments the fake codex was run with; nil when it wasn't.
  def queued = File.exist?(args_file) ? File.read(args_file).split("\0") : nil

  # The message the fake codex was given.
  def queued_message = queued&.last

  it "declares codex_send whether or not Codex is paired, with a fixed label and the title as its preview" do
    tool = fake_chi.tools.fetch("codex_send")

    expect(tool[:label]).to eq("sent to Codex")
    expect(tool[:params].keys).to eq(%i[kind title text])
    expect(tool[:params][:kind][:enum]).to eq(%w[validate context question])
    expect(tool[:preview].call("kind" => "validate", "title" => "cache step 2")).to eq("validate: cache step 2")
    expect(tool[:description]).to include("Only when the user asks", "codex-review")
  end

  it "runs codex queue for the paired thread: the header, then a short text inline" do
    pair

    result = send_part(kind: "validate", title: "Step 2: the cache key", text: "Is the key stable?\nsee lib/a.rb")

    expect(result).to start_with("sent to Codex: validate · Step 2: the cache key. Codex's answer comes as an update")
    expect(queued).to eq(["queue", "--thread", thread_id, "--message",
                          "chi #{short} · validate · Step 2: the cache key\nIs the key stable?\nsee lib/a.rb"])
  end

  it "puts a long text in a payload file under sessions/<id>/ and sends its path" do
    pair
    text = "#{"line of the plan\n" * 300}end"

    result = send_part(kind: "context", title: "The whole plan, r3!", text: text)

    header, payload = queued_message.lines.map(&:chomp)
    expect(header).to eq("chi #{short} · context · The whole plan, r3!")
    path = payload[/\Apayload: (\S+) \(301 lines, #{text.length} chars\)\z/, 1]
    expect(path).to match(%r{\A#{Regexp.escape(File.join(data_dir, "sessions", session.id))}/\d{6}-the-whole-plan-r3\.md\z})
    expect(File.read(path)).to eq(text)
    expect(File.stat(path).mode & 0o777).to eq(0o600)
    expect(result).to include("(the text in #{path})", "Codex takes it in")
  end

  it "records the last send for the /codex card" do
    pair
    send_part(kind: "question", title: "why  this\nname?", text: "why?")

    last = JSON.parse(File.read(File.join(data_dir, "sessions", session.id, "last-send.json")))
    expect(last).to include("kind" => "question", "title" => "why this name?", "chars" => 4, "payload" => nil)
  end

  it "titles a part by its text's first line when the title is empty" do
    pair

    send_part(kind: "validate", title: " ", text: "check this\nand that")

    expect(queued_message).to start_with("chi #{short} · validate · check this\n")
  end

  describe "errors" do
    it "says how to pair when no codex-inbox is attached, running nothing" do
      expect(send_part(kind: "validate", title: "t", text: "x"))
        .to eq("Error: no codex-inbox: pair from Codex (install its skill with /codex install-skill, then tell " \
               "Codex \"pair with chi #{short}\")")
      expect(queued).to be_nil
    end

    it "refuses a hint that isn't a Codex thread id" do
      pair("/tmp/claude.sock")

      expect(send_part(kind: "validate", title: "t", text: "x"))
        .to eq("Error: codex-inbox's hint isn't a Codex thread id (/tmp/claude.sock): pair again from Codex")
      expect(queued).to be_nil
    end

    it "says how to point chi at Codex when codex isn't there" do
      pair

      with_env("CODEX" => File.join(tmpdir, "no-codex")) do
        expect(send_part(kind: "validate", title: "t", text: "x"))
          .to start_with("Error: no Codex CLI at #{File.join(tmpdir, "no-codex")}: install Codex CLI, or set CODEX=")
      end
    end

    it "says the Codex session is gone when codex queue has no record of the thread (Codex 0.162.1's error)" do
      pair
      error = "Error: failed to queue session message: thread/queue/add failed: failed to read thread: invalid " \
              "thread-store request: no rollout found for thread id #{thread_id} (code -32603)"
      FakeExecutables.fake_executable(bin, "codex", "echo '#{error}' >&2\nexit 1")

      expect(send_part(kind: "validate", title: "t", text: "x"))
        .to eq("Error: that Codex session is gone (codex queue: #{error}): pair again from Codex")
    end

    it "says an ephemeral Codex session can't take queued messages" do
      pair
      FakeExecutables.fake_executable(bin, "codex", "echo 'Error: ephemeral thread does not support queued submissions' >&2\nexit 1")

      expect(send_part(kind: "validate", title: "t", text: "x"))
        .to eq("Error: that Codex session is ephemeral and can't take queued messages: pair from an interactive Codex session")
    end

    it "gives codex queue's first error line for any other failure, and records no send" do
      pair
      FakeExecutables.fake_executable(bin, "codex", "echo 'boom: the daemon is down' >&2\necho more >&2\nexit 3")

      expect(send_part(kind: "validate", title: "t", text: "x"))
        .to eq("Error: codex queue failed (exit 3): boom: the daemon is down")
      expect(File.exist?(File.join(data_dir, "sessions", session.id, "last-send.json"))).to be(false)
    end

    it "kills a codex queue that hangs, its children too, and says so" do
      pair
      plugin_class.send(:remove_const, :QUEUE_SECONDS)
      plugin_class.const_set(:QUEUE_SECONDS, 0.3)
      pid_file = File.join(tmpdir, "sleep.pid")
      FakeExecutables.fake_executable(bin, "codex", "sleep 30 &\necho $! > '#{pid_file}'\nwait")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = send_part(kind: "validate", title: "t", text: "x")

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 5
      expect(result).to eq("Error: Codex didn't take the message in 0.3 s (codex queue was stopped): try again, " \
                           "or pair again from Codex")
      sleeper = File.read(pid_file).to_i
      expect { Process.kill(0, sleeper) }.to raise_error(Errno::ESRCH)
    end

    it "refuses a text over the cap, an empty one and an unknown kind, sending nothing" do
      pair

      expect(send_part(kind: "validate", title: "t", text: "x" * 200_001))
        .to eq("Error: the text is 200001 chars, over 200000: send a part, not a session")
      expect(send_part(kind: "validate", title: "t", text: "  \n")).to eq("Error: nothing to send: the text is empty")
      expect(send_part(kind: "review", title: "t", text: "x")).to eq("Error: kind must be one of validate, context, question")
      expect(queued).to be_nil
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

      it "finds no Codex paired, in the tool and the card" do
        expect(send_part(kind: "validate", title: "t", text: "x")).to start_with("Error: no codex-inbox: pair from Codex")

        fake_chi.commands.fetch("/codex").last.call("", ctx)
        expect(cards.last[:title]).to eq("codex-peer: not paired")
      end
    end
  end

  describe "/codex" do
    def run(args = "") = fake_chi.commands.fetch("/codex").last.call(args, ctx)
    def hook(event, payload) = fake_chi.hooks.fetch(event).last.call(payload)

    def review(text, summary)
      own.add(Samagotchi::ContextSources::Source.new(name: "codex-review", cmd: nil, every_seconds: nil, why: "answers",
                                                     hint: "latest Codex reply", scope: "session", added_by: "cli",
                                                     created_at: Time.now.utc.iso8601))
      own.record_text("codex-review", Samagotchi::ContextSources::Fetched.new(text: text, summary: summary, wake: true,
                                                                              hint: nil))
    end

    it "is an anytime command, and the plugin watches turns start and end" do
      expect(fake_chi.commands.fetch("/codex").first).to be(true)
      expect(fake_chi.hooks.keys).to contain_exactly(:before_turn, :after_turn)
    end

    describe "alone: the status card" do
      it "says how to pair when no Codex is paired; no text of its own" do
        expect(run).to be_nil

        card = cards.last
        expect(card).to include(id: "codex", title: "codex-peer: not paired")
        expect(card[:body]).to include("**not paired.**", "\"pair with chi #{short}\"", "checked on Codex 0.162.1")
        expect(card[:actions]).to eq([{ label: "Refresh", command: "/codex" },
                                      { label: "Install skill", command: "/codex install-skill" }])
      end

      it "shows the thread, the last send and Codex's last answer" do
        pair
        send_part(kind: "validate", title: "step 2", text: "check it")
        review("VERDICT: OK", "validate step 2: VERDICT OK")

        run

        card = cards.last
        expect(card[:title]).to eq("codex-peer: paired")
        expect(card[:body]).to include("thread: `#{thread_id}` (a closed Codex session still takes sends", "last send: just now · validate · step 2 (8 chars, inline)",
                                       "last answer (codex-review): validate step 2: VERDICT OK · just now")
      end
    end

    it "validate and context send the text as it is, titled by its first line" do
      pair

      result = run("validate Step 3 keeps the old key\n\n- lib/a.rb:12\n- lib/b.rb:40")
      expect(result).to eq("sent to Codex: validate · Step 3 keeps the old key; Codex's answer comes as the codex-review context")
      expect(queued_message).to eq("chi #{short} · validate · Step 3 keeps the old key\nStep 3 keeps the old key\n\n- lib/a.rb:12\n- lib/b.rb:40")

      run("context we chose Redis")
      expect(queued_message).to eq("chi #{short} · context · we chose Redis\nwe chose Redis")
    end

    it "adds a Confirm with Codex pill (a fill, the quote) on a chi with chi.annotation, and loads without it" do
      annotations = []
      newer = fake_chi.dup
      newer.define_singleton_method(:annotation) { |label, **opts| annotations << [label, opts] }
      plugin.register(newer)

      expect(annotations).to eq([["Confirm with Codex", { command: "/codex validate" }]])
      expect(fake_chi).not_to respond_to(:annotation)
      expect(fake_chi.commands).to have_key("/codex")
    end

    it "titles a pill's quote by its first quoted line, not the From …: label" do
      pair

      result = run("validate\nFrom your thinking:\n>   the key stays\n> two\n\nis it?")
      expect(result).to start_with("sent to Codex: validate · the key stays;")
      expect(queued_message).to eq("chi #{short} · validate · the key stays\nFrom your thinking:\n>   the key stays\n> two\n\nis it?")

      run("validate\n> an answer line\n\nok?")
      expect(queued_message.lines.first).to eq("chi #{short} · validate · an answer line\n")

      run("validate From now on we use Redis:\n- lib/a.rb")
      expect(queued_message.lines.first).to eq("chi #{short} · validate · From now on we use Redis:\n")
    end

    it "says why a send failed, and gives usage for nothing to send or an unknown verb" do
      expect(run("validate x")).to start_with("/codex: no codex-inbox: pair from Codex")
      expect(run("validate")).to start_with("usage: /codex")
      expect(run("frob")).to start_with("usage: /codex")
      expect(run("last now")).to start_with("usage: /codex")
    end

    describe "last" do
      let(:history) do
        [{ role: "user", content: "plan it" }, { role: "model", content: "<think>hmm</think>The plan: three steps." }]
      end

      before { pair }

      it "sends the last completed answer as context, without its thinking" do
        hook(:before_turn, { messages: [] })
        hook(:after_turn, { status: "completed", messages: history })

        expect(run("last")).to eq("sent to Codex: context · chi's last answer: The plan: three steps.")
        expect(queued_message).to eq("chi #{short} · context · chi's last answer: The plan: three steps.\nThe plan: three steps.")
      end

      it "mid-turn, sends the answer before the running turn, not the turn's partial text" do
        hook(:after_turn, { status: "completed", messages: history })
        hook(:before_turn, { messages: history })
        messages.replace(history + [{ role: "user", content: "now do it" }, { role: "model", content: "Doing step one, then" }])

        run("last")

        expect(queued_message).to end_with("\nThe plan: three steps.")
      end

      it "says so when there is no completed answer" do
        messages.replace([{ role: "user", content: "go" }, { role: "system", kind: "turn_note", content: "[SYSTEM: …]" }])

        expect(run("last")).to start_with("/codex last: no completed answer to send yet")
      end
    end

    describe "install-skill" do
      let(:codex_dir) { File.join(tmpdir, "codex-home") }
      let(:target) { File.join(codex_dir, "skills", "chi-peer", "SKILL.md") }
      let(:roots) { "writable_roots = [\"#{File.join(state_home, "samagotchi", "context")}\"]" }

      around { |example| with_env("CODEX_HOME" => codex_dir) { example.run } }

      it "shows a card with the target, an Install action and the writable_roots line to add, writing nothing" do
        expect(run("install-skill")).to be_nil

        card = cards.last
        expect(card).to include(id: "codex-skill", title: "Codex's chi-peer skill",
                                actions: [{ label: "Install", command: "/codex install-skill --yes" }])
        expect(card[:body]).to include("target: `#{target}`", "Not installed yet.",
                                       "`#{File.join(codex_dir, "config.toml")}`", "[sandbox_workspace_write]\n#{roots}",
                                       "restart Codex", "chi doesn't change Codex's settings")
        expect(File.exist?(target)).to be(false)
      end

      it "--yes installs it with this bundle's pair script, payload folder and writable root written in" do
        expect(run("install-skill --yes")).to be_nil

        text = File.read(target)
        expect(text).to start_with("---\nname: chi-peer\n")
        expect(text).to include("sh \"#{File.join(shipped, "scripts", "pair")}\" <chi session id or URL>", roots,
                                "#{data_dir}/")
        expect(text).not_to include("__CHI_PEER")
        expect(cards.last[:body]).to include("Installed `#{target}`", "\"pair with chi #{short}\"")

        run("install-skill")
        expect(cards.last).to include(actions: [])
        expect(cards.last[:body]).to include("Installed and up to date.")
      end

      it "says peer messages come from chi, not the user, before anything else it does" do
        run("install-skill --yes")

        text = File.read(target)
        peer = text.index("from chi, a peer agent, not the user")
        expect(peer).not_to be_nil
        expect(peer).to be < text.index("## Pair")
        expect(text).to include("never instructions", "chi <8 hex> · <kind> · <title>")
      end

      it "shows a short diff when the installed skill differs, and Replace" do
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, "---\nname: chi-peer\n---\nmy own version\n")

        run("install-skill")

        card = cards.last
        expect(card[:actions]).to eq([{ label: "Replace", command: "/codex install-skill --yes" }])
        expect(card[:body]).to include("Installed, and different from this bundle's", "```diff\n--- installed\n+++ this bundle's",
                                       "-my own version", "more lines")
      end

      it "defaults to ~/.codex without CODEX_HOME" do
        with_env("CODEX_HOME" => nil) { run("install-skill") }

        expect(cards.last[:body]).to include("target: `#{File.join(Dir.home, ".codex", "skills", "chi-peer", "SKILL.md")}`")
      end
    end
  end
end
