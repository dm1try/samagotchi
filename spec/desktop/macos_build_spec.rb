# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "socket"
require "tmpdir"
require "spec_helper"
require "samagotchi/desktop"
require "samagotchi/context_quote"

RSpec.describe "the desktop helper's Swift sources", :macos_build do
  # One build for the file: swiftc takes ~15 s.
  before(:all) do
    # The around hook skips each example without SAMAGOTCHI_MACOS_BUILD, but
    # before(:all) runs first: don't build (no swiftc on Linux CI) then.
    next unless ENV["SAMAGOTCHI_MACOS_BUILD"] == "1"

    @build_dir = Dir.mktmpdir("desktop-build")
    @macos = Samagotchi::Desktop::MacOS.new(app_dir: File.join(@build_dir, "Apps"),
                                            support_dir: File.join(@build_dir, "Support"), register: false)
    @macos.install
  end

  after(:all) { FileUtils.remove_entry(@build_dir) if @build_dir }

  let(:app) { @macos.app_path }
  let(:executable) { File.join(app, "Contents", "MacOS", "ChiHelper") }

  it "compile into a signed app with the Service in its Info.plist" do
    _out, status = Open3.capture2e("codesign", "--verify", app)
    expect(status).to be_success
    expect(File.executable?(executable)).to be(true)
    plist, = Open3.capture2("plutil", "-convert", "json", "-o", "-", File.join(app, "Contents", "Info.plist"))
    expect(plist).to include('"NSMessage":"sendToChi"', '"LSUIElement":true', '"NSSendFileTypes":["public.image"]')
  end

  describe "ChiHelper --kitty, against a fake kitty" do
    # Short: a unix socket path has a ~104-byte limit.
    let(:tmp) { Dir.mktmpdir("kt", "/tmp") }
    let(:sock_dir) { File.join(tmp, "s").tap { |d| FileUtils.mkdir_p(d) } }
    let(:ls_dir) { File.join(tmp, "ls").tap { |d| FileUtils.mkdir_p(d) } }
    let(:temp_dir) { File.join(tmp, "t").tap { |d| FileUtils.mkdir_p(d) } }
    let(:log) { File.join(tmp, "kitty.log") }
    let(:launch) { File.join(tmp, "launch.json") }
    let(:fake) { File.expand_path("../fixtures/desktop/fake_kitty", __dir__) }
    let(:agents) { %w[claude codex] }
    let(:listen_on) { "unix:$SOCKDIR/kitty.${KITTY_PID}" }
    let(:base) { "kitty.${KITTY_PID}" }

    after { FileUtils.remove_entry(tmp) }

    def socket(name)
      UNIXServer.new(File.join(sock_dir, name)).close
    end

    def window(id, *cmdlines, title: "t#{id}", cwd: "/w/p#{id}")
      { "id" => id, "title" => title, "cwd" => cwd, "foreground_processes" => cmdlines.map { |c| { "cmdline" => c } } }
    end

    def canned(name, *windows)
      File.write(File.join(ls_dir, "#{name}.json"), JSON.generate([{ "id" => 1, "tabs" => [{ "windows" => windows }] }]))
    end

    def write_launch(kitty = { "listen_on" => listen_on, "binary" => fake, "agents" => agents })
      File.write(launch, JSON.generate({ "version" => "x", "argv" => ["/bin/echo"], "env" => {} }
        .merge(kitty ? { "kitty" => kitty } : {})))
    end

    # The helper with this spec's env; kitty's own variables (this spec may
    # run in a kitty window) unset.
    def helper(*args, stdin: "")
      env = ENV.keys.grep(/\AKITTY_/).to_h { |k| [k, nil] }
               .merge("SOCKDIR" => sock_dir, "FAKE_KITTY_LOG" => log, "FAKE_KITTY_LS" => ls_dir,
                      "TMPDIR" => "#{temp_dir}/", "HOME" => tmp)
      out, err, status = Open3.capture3(env, executable, "--kitty", *args, "--launch", launch, stdin_data: stdin)
      [out, err, status.exitstatus]
    end

    def calls
      File.exist?(log) ? File.readlines(log).map { |line| JSON.parse(line) } : []
    end

    def list
      out, err, = helper("list")
      JSON.parse(out).tap { expect(err).to eq("") }
    end

    before do
      write_launch
      %w[-1 -2 -3].each { |suffix| socket("#{base}#{suffix}") }
      socket("other-1")
      File.write(File.join(sock_dir, "#{base}-4"), "") # a file, not a socket
      canned("#{base}-1", window(1, ["/usr/local/bin/claude"]),
             window(2, ["node", "/opt/lib/codex/bin/codex"]), window(3, ["-fish"]))
      canned("#{base}-2", window(7, %w[caffeinate -i], ["claude"], title: "✳ Claude Code", cwd: "/w/samagotchi"))
      canned("other-1", window(9, ["claude"]))
      # -3 has no canned ls: a socket a dead kitty left
    end

    it "lists agent windows from every live socket listen_on names, ${VAR} kept literal when unset" do
      result = list
      expect(result["error"]).to be_nil
      expect(result["windows"].map { |w| [w["key"], w["agent"]] }).to eq(
        [["#{sock_dir}/#{base}-1#1", "claude"], ["#{sock_dir}/#{base}-1#2", "codex"], ["#{sock_dir}/#{base}-2#7", "claude"]]
      )
      expect(result["windows"].last).to include("title" => "Claude Code", "label" => "claude · samagotchi")
      asked = calls.map { |c| c["argv"][c["argv"].index("--to") + 1] }
      expect(asked).to contain_exactly(*%w[-1 -2 -3].map { |s| "unix:#{sock_dir}/#{base}#{s}" })
      expect(calls.map { |c| c["argv"].drop(3) }.uniq).to eq([["ls"]])
    end

    context "with agents: *" do
      let(:agents) { %w[*] }

      it "lists every window" do
        expect(list["windows"].map { |w| w["agent"] }).to eq(%w[claude codex fish claude])
      end
    end

    context "with ~ and {kitty_pid} in listen_on" do
      let(:listen_on) { "unix:~/s/k-{kitty_pid}.sock" }

      it "expands the home folder and takes any pid" do
        socket("k-123.sock")
        socket("k-x.sock")
        canned("k-123.sock", window(5, ["claude"]))
        expect(list["windows"].map { |w| w["key"] }).to eq(["#{sock_dir}/k-123.sock#5"])
      end
    end

    context "with a tcp listen_on" do
      let(:listen_on) { "tcp:localhost:12345" }

      it "says only unix: sockets work" do
        out, _err, status = helper("list")
        expect(status).to eq(1)
        expect(JSON.parse(out)).to eq("windows" => [], "error" => "kitty.listen_on tcp:localhost:12345: only unix: sockets")
      end
    end

    it "lists nothing and runs no kitty without a kitty section" do
      write_launch(nil)
      expect(list).to eq("windows" => [], "error" => nil)
      expect(calls).to be_empty
    end

    describe "send" do
      let(:key) { "#{sock_dir}/#{base}-1#1" }
      let(:to) { ["@", "--to", "unix:#{sock_dir}/#{base}-1"] }
      let(:context) { "  \nline one  \n\nline three\n" }
      let(:shot) { File.join(tmp, "clip dir", "clipboard.tiff").tap { |p| FileUtils.mkdir_p(File.dirname(p)); File.write(p, "tiff") } }
      let(:finder) { File.join(tmp, "my shot.png").tap { |p| File.write(p, "png") } }

      it "checks the window, pastes quote, message and image paths as one bracketed paste, then presses Enter" do
        out, _err, status = helper("send", key, "--message", "same bug?", "--image", finder, "--temp-image", shot, stdin: context)
        expect([out, status]).to eq(["sent\n", 0])
        argvs = calls.map { |c| c["argv"] }
        expect(argvs).to eq([to + %w[ls --match id:1],
                             to + %w[send-text --match id:1 --bracketed-paste=disable --stdin],
                             to + %w[send-key --match id:1 enter]])
        copies = Dir[File.join(temp_dir, "chi-helper-sent", "*")]
        expect(copies.map { |c| File.extname(c) }).to eq([".tiff"])
        expect(File.read(copies.first)).to eq("tiff")
        expect(calls[1]["stdin"]).to eq("\e[200~#{Samagotchi::ContextQuote.block(context)}same bug?\n'#{finder}'\n#{copies.first}\e[201~")
      end

      it "with --paste-only presses no Enter and ends the paste with a newline" do
        out, _err, status = helper("send", key, "--paste-only", "--message", "the login page", "--image", finder)
        expect([out, status]).to eq(["pasted\n", 0])
        expect(calls.map { |c| c["argv"][3] }).to eq(%w[ls send-text])
        expect(calls[1]["stdin"]).to eq("\e[200~the login page\n'#{finder}'\n\e[201~")
      end

      it "takes bracketed-paste markers out of the text" do
        helper("send", key, "--message", "a\e[201~b\e[200~c")
        expect(calls[1]["stdin"]).to eq("\e[200~abc\e[201~")
      end

      it "says window closed and pastes nothing when the window is gone" do
        out, _err, status = helper("send", "#{sock_dir}/#{base}-1#99", "--message", "hi")
        expect([out, status]).to eq(["window closed\n", 1])
        expect(calls.map { |c| c["argv"][3] }).to eq(%w[ls])
      end
    end
  end

  describe "ChiHelper --model-pick, the model chooser's rules" do
    let(:payload) do
      {
        "default" => "box:gemma-small", "default_typed" => "small", "default_host" => "main",
        "models" => [
          { "name" => "gemma-4", "host" => "main", "id" => "gemma-4" },
          { "name" => "main:qwen3:8b", "host" => "main", "id" => "qwen3:8b" },
          { "name" => "taken", "host" => "main", "id" => "taken", "shadowed_by" => "taken" },
          { "name" => "box:gemma-small", "host" => "box", "id" => "gemma-small" },
          { "name" => "openrouter:qwen/qwen3.8-27b", "host" => "openrouter", "id" => "qwen/qwen3.8-27b" },
          { "name" => "openrouter:qwen/qwen3.8-max", "host" => "openrouter", "id" => "qwen/qwen3.8-max" },
          { "name" => "openrouter:anthropic/claude-x", "host" => "openrouter", "id" => "anthropic/claude-x" },
          { "name" => "openrouter:z/aqxwxexn", "host" => "openrouter", "id" => "z/aqxwxexn" }
        ],
        "aliases" => [{ "name" => "small", "ref" => "box:gemma-small", "host" => "box" },
                      { "name" => "fast", "ref" => "gemma-4", "host" => "main" }],
        "warnings" => ["splash: no answer in 4 s"]
      }
    end

    def pick(*args, input: JSON.generate(payload))
      out, err, status = Open3.capture3(executable, "--model-pick", *args, stdin_data: input)
      [status.exitstatus.zero? ? JSON.parse(out) : out, err, status.exitstatus]
    end

    def names(result) = result["rows"].map { |r| r["name"] }

    it "lists Default first, then the default host's ids and aliases, then the other hosts; no shadowed row" do
      result, = pick

      expect(result["rows"].first).to eq("kind" => "default", "name" => "box:gemma-small",
                                         "label" => "Default (small → box:gemma-small)")
      expect(names(result)).to eq(["box:gemma-small", "gemma-4", "main:qwen3:8b", "fast", "small",
                                   "openrouter:qwen/qwen3.8-27b", "openrouter:qwen/qwen3.8-max",
                                   "openrouter:anthropic/claude-x", "openrouter:z/aqxwxexn"])
      expect(result["rows"].map { |r| r["label"] }).to include("fast → gemma-4", "openrouter · qwen/qwen3.8-27b", "gemma-4")
      expect(result["warnings"]).to eq(["splash: no answer in 4 s"])
    end

    it "puts the recent picks still offered after Default" do
      result, = pick("--recent", "OPENROUTER:z/aqxwxexn", "--recent", "gone:model", "--recent", "box:gemma-small")

      expect(names(result).first(3)).to eq(["box:gemma-small", "openrouter:z/aqxwxexn", "gemma-4"])
      expect(names(result).count("openrouter:z/aqxwxexn")).to eq(1)
    end

    it "ranks matches: segment-start substrings, then other substrings, then subsequences; a new name is offered as not listed" do
      result, = pick("--query", "qwen")
      expect(names(result)).to eq(["box:gemma-small", "main:qwen3:8b", "openrouter:qwen/qwen3.8-27b",
                                   "openrouter:qwen/qwen3.8-max", "openrouter:z/aqxwxexn", "qwen"])
      expect(result["rows"].last).to eq("kind" => "typed", "name" => "qwen", "label" => "qwen — not listed")

      result, = pick("--query", "open max")
      expect(names(result)).to eq(["box:gemma-small", "openrouter:qwen/qwen3.8-max", "open max"])

      result, = pick("--query", "axe")
      expect(names(result)).to eq(["box:gemma-small", "openrouter:z/aqxwxexn", "small", "axe"])

      result, = pick("--query", "Gemma-4")
      expect(names(result)).to eq(["box:gemma-small", "gemma-4", "fast"])
    end

    it "keeps a remembered pick only while offered, spelled as listed; a gone one falls back to the default with a note" do
      expect(pick("--stored", "GEMMA-4").first.values_at("pick", "note")).to eq(["gemma-4", nil])
      expect(pick("--stored", "small").first.values_at("pick", "note")).to eq(["small", nil])
      expect(pick("--stored", "box:gemma-small").first.values_at("pick", "note")).to eq([nil, nil])
      expect(pick("--stored", "old:model").first.values_at("pick", "note"))
        .to eq([nil, "old:model isn't listed any more; using the default"])
    end

    it "remembers five recent picks, the newest first, without copies" do
      result, = pick("--recent", "a", "--recent", "b", "--recent", "c", "--recent", "d", "--recent", "e", "--push", "C")

      expect(result["recent"]).to eq(%w[C a b d e])
    end

    it "reads the exit-1 payload (no host listed): the default alone, and a remembered pick kept" do
      result, = pick("--stored", "gemma-4", input: JSON.generate("default" => "gemma-4", "default_typed" => nil, "default_host" => nil,
                                                                 "models" => [], "aliases" => [], "warnings" => ["main: refused"]))

      expect(result["rows"]).to eq([{ "kind" => "default", "name" => "gemma-4", "label" => "Default (gemma-4)" }])
      expect(result["pick"]).to be_nil
      expect(pick("--stored", "box:x", input: JSON.generate("default" => "gemma-4", "models" => [])).first["pick"]).to eq("box:x")
    end

    it "fails on what isn't a payload" do
      _out, err, status = pick(input: "not json")

      expect(status).to eq(1)
      expect(err).to include("not a chi models payload")
    end
  end
end

# No build needed: runs everywhere, CI's Linux too.
RSpec.describe "the desktop helper's Swift sources, as text" do
  it "use no SwiftUI macros or property wrappers the Command Line Tools may lack" do
    # code only: comments explain why they're avoided
    sources = Dir[File.join(Samagotchi::Desktop::MacOS::SOURCES_DIR, "*.swift")].map { |path| File.read(path).gsub(%r{//.*$}, "") }.join
    expect(sources).to include("struct PanelView")
    expect(sources).not_to match(/@State\b|@Observable\b|#Preview|@Entry\b/)
  end
end
