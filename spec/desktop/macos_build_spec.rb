# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "securerandom"
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

  describe "ChiHelper --agents, against a fake kitty" do
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
      out, err, status = Open3.capture3(env, executable, "--agents", *args, "--launch", launch, stdin_data: stdin)
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
      expect(result["errors"]).to eq({})
      expect(result["agents"].map { |w| [w["key"], w["agent"]] }).to eq(
        [["#{sock_dir}/#{base}-1#1", "claude"], ["#{sock_dir}/#{base}-1#2", "codex"], ["#{sock_dir}/#{base}-2#7", "claude"]]
      )
      expect(result["agents"].last).to include("terminal" => "kitty", "title" => "Claude Code", "label" => "claude · samagotchi")
      asked = calls.map { |c| c["argv"][c["argv"].index("--to") + 1] }
      expect(asked).to match_array(%w[-1 -2 -3].map { |s| "unix:#{sock_dir}/#{base}#{s}" })
      expect(calls.map { |c| c["argv"].drop(3) }.uniq).to eq([["ls"]])
    end

    context "with agents: *" do
      let(:agents) { %w[*] }

      it "lists every window" do
        expect(list["agents"].map { |w| w["agent"] }).to eq(%w[claude codex fish claude])
      end
    end

    context "with ~ and {kitty_pid} in listen_on" do
      let(:listen_on) { "unix:~/s/k-{kitty_pid}.sock" }

      it "expands the home folder and takes any pid" do
        socket("k-123.sock")
        socket("k-x.sock")
        canned("k-123.sock", window(5, ["claude"]))
        expect(list["agents"].map { |w| w["key"] }).to eq(["#{sock_dir}/k-123.sock#5"])
      end
    end

    context "with a tcp listen_on" do
      let(:listen_on) { "tcp:localhost:12345" }

      it "says only unix: sockets work" do
        out, _err, status = helper("list")
        expect(status).to eq(1)
        expect(JSON.parse(out)).to eq("agents" => [], "errors" => { "kitty" => "kitty.listen_on tcp:localhost:12345: only unix: sockets" })
      end
    end

    it "lists nothing and runs no kitty without a kitty section" do
      write_launch(nil)
      expect(list).to eq("agents" => [], "errors" => {})
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

      it "says not an agent and runs no kitty for a key no terminal owns" do
        out, _err, status = helper("send", "#{sock_dir}/#{base}-1#x", "--message", "hi")
        expect([out, status]).to eq(["not an agent: #{sock_dir}/#{base}-1#x\n", 1])
        expect(calls).to be_empty
      end
    end
  end

  describe "ChiHelper --agents, against a real tmux" do
    let(:tmux_binary) do
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { File.join(_1, "tmux") }.find { File.file?(_1) && File.executable?(_1) }
    end
    # Short: a unix socket path has a ~104-byte limit.
    let(:tmp) { Dir.mktmpdir("tx", "/tmp") }
    let(:socket_dir) { File.join(tmp, "tmux-#{Process.uid}") }
    let(:launch) { File.join(tmp, "launch.json") }
    let(:agents) { %w[claude codex] }
    let(:started) { [] }
    # tmux runs with this spec's own TMUX_TMPDIR, outside any tmux this may run in.
    let(:tmux_env) { { "TMUX" => nil, "TMUX_PANE" => nil, "TMUX_TMPDIR" => tmp } }

    before do
      skip "no tmux on PATH" unless tmux_binary
      FileUtils.mkdir_p(File.join(tmp, "bin"))
      # A copy named claude (pane_current_command says claude); a copied
      # system binary is killed until re-signed.
      FileUtils.cp("/bin/cat", File.join(tmp, "bin", "claude"))
      Open3.capture2e("codesign", "--force", "--sign", "-", File.join(tmp, "bin", "claude"))
      File.write(File.join(tmp, "codex"), "while read line; do :; done\n")
      write_launch
    end

    after do
      # Only this spec's servers: nothing else is killed.
      started.uniq.each { |name| Open3.capture2e(tmux_env, tmux_binary, "-L", name, "kill-server") }
      FileUtils.remove_entry(tmp)
    end

    def tmux(name, *args)
      out, status = Open3.capture2e(tmux_env, tmux_binary, "-L", name, *args)
      raise "tmux #{args.first}: #{out}" unless status.success?

      out.chomp
    end

    # A server with one pane running +command+ (in session "main").
    def server(name, command)
      started << name
      tmux(name, "-f", "/dev/null", "new-session", "-d", "-s", "main", "-x", "120", "-y", "30", command)
      name
    end

    def pane(name, command) = tmux(name, "new-window", "-d", "-P", "-F", "\#{pane_id}", command)
    def first_pane(name) = tmux(name, "list-panes", "-a", "-F", "\#{pane_id}").lines.first.strip
    def key(name, pane_id) = "tmux:#{socket_dir}/#{name}##{tmux(name, "display-message", "-p", "\#{pid}")}##{pane_id}"
    def buffers(name) = tmux(name, "list-buffers")

    def wait_for(what, &) = super(what, interval: 0.05, &)

    def running(name, pane_id, command)
      wait_for("#{command} in #{pane_id}") do
        tmux(name, "display-message", "-p", "-t", pane_id, "\#{pane_current_command}") == command
      end
    end

    def write_launch(tmux_section = { "binary" => tmux_binary, "socket_dir" => socket_dir, "agents" => agents }, kitty: nil)
      File.write(launch, JSON.generate({ "version" => "x", "argv" => ["/bin/echo"], "env" => {} }
        .merge(kitty ? { "kitty" => kitty } : {}).merge(tmux_section ? { "tmux" => tmux_section } : {})))
    end

    # The helper with launchd's bare env (no PATH to tmux, no LANG): the
    # absolute binary and -u carry it.
    def helper(*args, stdin: "", env: {})
      out, err, status = Open3.capture3({ "HOME" => tmp }.merge(env), executable, "--agents", *args, "--launch", launch,
                                        stdin_data: stdin, unsetenv_others: true)
      [out, err, status.exitstatus]
    end

    def list
      out, err, = helper("list")
      JSON.parse(out).tap { expect(err).to eq("") }
    end

    # A pane that records what it receives, raw, into +file+; with +bracketed+
    # it turns bracketed paste on first, as claude and codex do.
    def recorder(name, file, bracketed: true)
      mode = bracketed ? %(printf '\\033[?2004h'; ) : ""
      pane(name, %(sh -c "#{mode}stty raw -echo; exec cat > '#{file}'")).tap { |id| running(name, id, "cat") }
    end

    def received(file, bytes)
      wait_for("#{bytes} bytes in #{file}") { File.size?(file).to_i >= bytes && File.binread(file) }
    end

    context "listing" do
      before do
        server("chi-spec-1", File.join(tmp, "bin", "claude"))
        tmux("chi-spec-1", "select-pane", "-t", first_pane("chi-spec-1"), "-T", "✳ Claude Code")
        # The native claude's look: pane_current_command says cat, ps says claude.
        running("chi-spec-1", pane("chi-spec-1", "bash -c 'exec -a claude /bin/cat'"), "cat")
        pane("chi-spec-1", "/bin/sh #{tmp}/codex")
        pane("chi-spec-1", "/bin/sh")
        server("chi-spec-2", File.join(tmp, "bin", "claude"))
        # A stale socket: a server killed earlier leaves its file.
        server("chi-spec-3", "/bin/sh")
        tmux("chi-spec-3", "kill-server")
      end

      it "lists agent panes of every live server, matched on ps's names, keyed with the server pid" do
        result = list
        expect(result["errors"]).to eq({})
        rows = result["agents"].map { |a| a.values_at("terminal", "agent", "title") }
        expect(rows).to eq([["tmux", "claude", "Claude Code"], ["tmux", "claude", ""], ["tmux", "codex", ""], ["tmux", "claude", ""]])
        pid = tmux("chi-spec-1", "display-message", "-p", "\#{pid}")
        expect(result["agents"].first["key"]).to eq("tmux:#{socket_dir}/chi-spec-1##{pid}#%0")
        expect(result["agents"].last["key"]).to start_with("tmux:#{socket_dir}/chi-spec-2#")
        expect(result["agents"].first["cwd"]).not_to be_empty
      end

      context "with agents: *" do
        let(:agents) { %w[*] }

        it "lists every pane and names the look-alike claude, not cat" do
          expect(list["agents"].map { |a| a["agent"] }).to eq(%w[claude claude codex sh claude])
        end
      end

      it "says tmux isn't found, beside kitty's rows, when the binary is gone" do
        sock_dir = File.join(tmp, "k").tap { |d| FileUtils.mkdir_p(d) }
        ls_dir = File.join(tmp, "ls").tap { |d| FileUtils.mkdir_p(d) }
        UNIXServer.new(File.join(sock_dir, "kitty-1")).close
        File.write(File.join(ls_dir, "kitty-1.json"), JSON.generate([{ "id" => 1, "tabs" => [{ "windows" => [
          { "id" => 4, "title" => "", "cwd" => "/w", "foreground_processes" => [{ "cmdline" => ["claude"] }] }
        ] }] }]))
        fake = File.expand_path("../fixtures/desktop/fake_kitty", __dir__)
        write_launch({ "binary" => File.join(tmp, "no", "tmux"), "socket_dir" => socket_dir, "agents" => agents },
                     kitty: { "listen_on" => "unix:#{sock_dir}/kitty", "binary" => fake, "agents" => agents })
        # fake_kitty is a ruby script: it needs the PATH to ruby.
        out, _err, status = helper("list", env: { "PATH" => ENV.fetch("PATH"), "FAKE_KITTY_LOG" => File.join(tmp, "k.log"),
                                                  "FAKE_KITTY_LS" => ls_dir })
        expect(status).to eq(1)
        expect(JSON.parse(out)).to eq(
          "agents" => [{ "key" => "#{sock_dir}/kitty-1#4", "terminal" => "kitty", "agent" => "claude", "title" => "",
                         "cwd" => "/w", "label" => "claude · w" }],
          "errors" => { "tmux" => "tmux not found at #{tmp}/no/tmux: set tmux.binary, then chi update" }
        )
      end
    end

    describe "send" do
      let(:name) { server("chi-spec-s", "/bin/sh") }
      let(:out_file) { File.join(tmp, "out") }
      let(:message) { "same bug?" }
      let(:text) { "#{Samagotchi::ContextQuote.block("line one\nline two\n")}#{message}" }

      it "pastes quote and message as one bracketed paste, then presses Enter; no buffer left" do
        id = recorder(name, out_file)
        out, _err, status = helper("send", key(name, id), "--message", message, stdin: "line one\nline two\n")
        expect([out, status]).to eq(["sent\n", 0])
        expected = "\e[200~#{text}\e[201~\r"
        expect(received(out_file, expected.bytesize)).to eq(expected.b)
        expect(buffers(name)).to eq("")
      end

      it "with --paste-only ends the paste with a newline and presses no Enter" do
        id = recorder(name, out_file)
        out, _err, status = helper("send", key(name, id), "--paste-only", "--message", message)
        expect([out, status]).to eq(["pasted\n", 0])
        expected = "\e[200~#{message}\n\e[201~"
        expect(received(out_file, expected.bytesize)).to eq(expected.b)
        sleep 0.2 # sleep-ok: a late Enter shows by now (tmux has no pass to count)
        expect(File.binread(out_file)).to eq(expected.b)
      end

      it "pastes bare text, newlines kept, into a program without bracketed paste" do
        id = recorder(name, out_file, bracketed: false)
        helper("send", key(name, id), "--paste-only", "--message", "a\nb")
        expect(received(out_file, 4)).to eq("a\nb\n")
      end

      it "leaves copy mode first" do
        id = recorder(name, out_file)
        tmux(name, "copy-mode", "-t", id)
        expect(tmux(name, "display-message", "-p", "-t", id, "\#{pane_mode}")).to eq("copy-mode")
        out, = helper("send", key(name, id), "--message", "hi")
        expect(out).to eq("sent\n")
        expect(received(out_file, 15)).to eq("\e[200~hi\e[201~\r".b)
        expect(tmux(name, "display-message", "-p", "-t", id, "\#{pane_in_mode}")).to eq("0")
      end

      it "refuses a pane in another mode, pasting nothing" do
        id = recorder(name, out_file)
        tmux(name, "choose-tree", "-t", id)
        out, _err, status = helper("send", key(name, id), "--message", "hi")
        expect([out, status]).to eq(["pane in tree-mode\n", 1])
        expect(File.size(out_file)).to eq(0)
        expect(buffers(name)).to eq("")
      end

      it "says pane closed for a killed pane, and for a restarted server's pane of the same id" do
        id = recorder(name, out_file)
        old = key(name, id)
        tmux(name, "kill-pane", "-t", id)
        expect(helper("send", old, "--message", "hi").values_at(0, 2)).to eq(["pane closed\n", 1])
        expect(buffers(name)).to eq("")

        restarted = key(name, first_pane(name))
        tmux(name, "kill-server")
        server(name, "/bin/sh")
        expect(first_pane(name)).to eq("%0")
        expect(helper("send", restarted, "--message", "hi").values_at(0, 2)).to eq(["pane closed\n", 1])
      end
    end
  end

  describe "ChiHelper --broadcast, the Everyone row's chi broadcast, against a fake chi" do
    let(:tmp) { Dir.mktmpdir("bc") }
    let(:launch) { File.join(tmp, "launch.json") }
    let(:fake) { File.join(tmp, "chi") }

    before do
      # Records its argv and stdin, then answers as FAKE_CHI_MODE says.
      File.write(fake, <<~SH)
        printf '%s\\n' "$@" > "$FAKE_CHI_DIR/argv"
        cat > "$FAKE_CHI_DIR/stdin"
        case "$FAKE_CHI_MODE" in
          slow) exec sleep 5 ;;
          refused) echo "chi broadcast: no sessions to send to: none runs now" >&2; exit 1 ;;
          failed)
            echo 'broadcast b-1234abcd  "disk"'
            echo "3f2a1c9e  failed     No space left on device"
            echo "delivered 0 · skipped 1"
            exit 1 ;;
          *)
            echo "chi broadcast: a warning" >&2
            echo 'broadcast b-7f3a1c9e  "payments API returns 500"'
            echo "3f2a1c9e  delivered  ticket PAY-123 matches (branch)"
            echo "c0ffee12  skipped    model: no"
            echo "delivered 1 · skipped 1 · 1 unchecked: triage deadline" ;;
        esac
      SH
      write_launch
    end

    after { FileUtils.remove_entry(tmp) }

    def write_launch(extra = {})
      File.write(launch, JSON.generate({ "version" => "x", "argv" => ["/bin/sh", fake], "env" => {} }.merge(extra)))
    end

    def broadcast(note, mode: "ok")
      out, err, status = Open3.capture3({ "FAKE_CHI_DIR" => tmp, "FAKE_CHI_MODE" => mode },
                                        executable, "--broadcast", "--launch", launch, stdin_data: note)
      expect(err).to eq("")
      [JSON.parse(out), status.exitstatus]
    end

    it "runs chi broadcast with the note on stdin and shows the id and the summary line, pointing to the log" do
      result, status = broadcast("shopfront/checkout\n\n> payments API returns 500\n")

      expect(status).to eq(0)
      expect(File.read(File.join(tmp, "argv"))).to eq("broadcast\n")
      expect(File.read(File.join(tmp, "stdin"))).to eq("shopfront/checkout\n\n> payments API returns 500\n")
      expect(result).to eq("ok" => true, "timeout" => 30,
                           "message" => "b-7f3a1c9e: delivered 1 · skipped 1 · 1 unchecked: triage deadline\n" \
                                        "details: chi broadcast log")
    end

    it "gives it the launch file's broadcast_timeout, and says so when it took longer and was stopped" do
      write_launch("broadcast_timeout" => 1)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result, status = broadcast("note", mode: "slow")

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 4
      expect(status).to eq(1)
      expect(result).to eq("ok" => false, "timeout" => 1,
                           "message" => "chi broadcast took over 1 s and was stopped; " \
                                        "the note may be partly delivered (chi broadcast log)")
    end

    it "shows why it was refused, and a failed delivery's lines under the summary" do
      result, status = broadcast("note", mode: "refused")
      expect(status).to eq(1)
      expect(result).to include("ok" => false, "message" => "chi broadcast: no sessions to send to: none runs now")

      result, = broadcast("note", mode: "failed")
      expect(result).to include("ok" => false,
                                "message" => "b-1234abcd: delivered 0 · skipped 1\n3f2a1c9e  failed     No space left on device")
    end

    it "says so when the launch file is missing" do
      File.delete(launch)
      result, status = broadcast("note")

      expect(status).to eq(1)
      expect(result["message"]).to start_with("No launch file at #{launch}")
    end
  end

  describe "ChiHelper --sessions, the panel's session rows, against a fake chi" do
    let(:tmp) { Dir.mktmpdir("ss") }
    let(:launch) { File.join(tmp, "launch.json") }
    let(:fake) { File.join(tmp, "chi") }
    let(:ids) { Array.new(9) { SecureRandom.uuid } }
    let(:dirs) { %w[a b].map { |name| File.join(tmp, name).tap { |d| FileUtils.mkdir_p(d) } } }

    def session(index, cwd: dirs[0], updated: "2026-10-27T10:00:00Z", **extra)
      { "id" => ids[index], "desc" => "s#{index}", "cwd" => cwd, "busy" => false, "owner" => nil,
        "updated_at" => updated }.merge(extra.transform_keys(&:to_s))
    end

    before do
      # Logs each call's argv on one line (and its CHI_REMOTE on another
      # file); --live answers live.json, any other list recent.json, as
      # FAKE_CHI_MODE says. `remote ls` answers remotes.json (an older chi
      # without it exits 2); `--remote NAME` lists NAME-live.json and
      # NAME-recent.json, unless NAME.mode says it hangs or is refused.
      File.write(fake, <<~SH)
        echo "$*" >> "$FAKE_CHI_DIR/calls"
        echo "$PATH" >> "$FAKE_CHI_DIR/path"
        echo "${CHI_REMOTE-unset}" >> "$FAKE_CHI_DIR/env"
        if [ "$1" = remote ]; then
          [ -f "$FAKE_CHI_DIR/remotes.json" ] || { echo "chi: unknown command remote" >&2; exit 2; }
          cat "$FAKE_CHI_DIR/remotes.json"; exit 0
        fi
        if [ "$1" = --remote ]; then
          name=$2
          case "$(cat "$FAKE_CHI_DIR/$name.mode" 2>/dev/null)" in
            slow) exec sleep 8 ;;
            refused)
              printf 'chi sessions: remote %s (http://10.0.0.9:4567): the token was refused (add it again)\nsecond line\n' "$name" >&2
              exit 1 ;;
            warned)
              echo "/gems/foo.rb:3: warning: method redefined" >&2
              echo "chi sessions: remote $name (http://10.0.0.9:4567): connection refused" >&2
              exit 1 ;;
          esac
          case "$*" in
            *--live*) cat "$FAKE_CHI_DIR/$name-live.json" ;;
            *) cat "$FAKE_CHI_DIR/$name-recent.json" ;;
          esac
          exit 0
        fi
        case "$*" in
          *--live*)
            if [ "$FAKE_CHI_MODE" = live-fails ]; then echo "chi: no state dir" >&2; exit 1; fi
            cat "$FAKE_CHI_DIR/live.json" ;;
          *)
            if [ "$FAKE_CHI_MODE" = recent-fails ]; then exit 1; fi
            cat "$FAKE_CHI_DIR/recent.json" ;;
        esac
      SH
      File.write(launch, JSON.generate({ "version" => "x", "argv" => ["/bin/sh", fake], "env" => {} }))
      # In chi's order (created_at asc): the newest updated, with a folder
      # that exists, is where a new session starts.
      File.write(File.join(tmp, "live.json"), JSON.generate([
        session(0, cwd: dirs[0], updated: "2026-10-27T10:00:00Z"),
        session(1, cwd: dirs[1], updated: "2026-10-27T11:00:00.123Z", busy: true),
        session(2, cwd: File.join(tmp, "gone"), updated: "2026-10-27T12:00:00Z")
      ]))
      # Newest first: a live one, a REPL's, a non-UUID id, then four stopped.
      File.write(File.join(tmp, "recent.json"), JSON.generate([
        session(1), session(3, owner: "repl"), session(4).merge("id" => "--flag"),
        session(5, desc: nil), session(6), session(7), session(8)
      ]))
    end

    after { FileUtils.remove_entry(tmp) }

    def sessions(*args, mode: "ok", env: {})
      out, err, status = Open3.capture3({ "FAKE_CHI_DIR" => tmp, "FAKE_CHI_MODE" => mode }.merge(env),
                                        executable, "--sessions", "--launch", launch, *args)
      [status.exitstatus.zero? ? JSON.parse(out) : out, err, status.exitstatus]
    end

    def calls = File.readlines(File.join(tmp, "calls"), chomp: true)

    # The local calls, in their order (`remote ls` runs beside them).
    def local_calls = calls.reject { |c| c.start_with?("remote ", "--remote ") }

    it "runs chi with the launch file's PATH over the helper's environment" do
      baked_path = "#{tmp}/baked:/usr/bin:/bin"
      config = JSON.parse(File.read(launch))
      config["env"] = { "PATH" => baked_path }
      File.write(launch, JSON.generate(config))

      _, err, status = sessions(env: { "PATH" => "/usr/bin:/bin" })

      expect([err, status]).to eq(["", 0])
      expect(File.readlines(File.join(tmp, "path"), chomp: true).uniq).to eq([baked_path])
    end

    it "lists the live sessions in chi's order, then up to 3 stopped ones neither live nor a REPL's, newest first" do
      result, err, status = sessions

      expect([err, status]).to eq(["", 0])
      expect(result["rows"].map { |r| [r["id"], r["recent"]] })
        .to eq([[ids[0], false], [ids[1], false], [ids[2], false], [ids[5], true], [ids[6], true], [ids[7], true]])
      expect(result["rows"][1]).to eq("id" => ids[1], "desc" => "s1", "cwd" => dirs[1], "busy" => true, "recent" => false)
      expect(result["rows"][3]["desc"]).to be_nil
      expect(result["new_dir"]).to eq(dirs[1])
      expect(local_calls).to eq(["sessions list --live --sort created_at --order asc --scope=all --format json",
                                 "sessions list --limit 20 --scope=all --format json"])
      expect(calls - local_calls).to eq(["remote ls --format json"])
      expect(result["remotes"]).to eq([])
    end

    it "keeps the live rows when the recent list fails, and fails with chi's stderr when the live one does" do
      result, = sessions(mode: "recent-fails")
      expect(result["rows"].map { |r| r["id"] }).to eq(ids.first(3))

      out, err, status = sessions(mode: "live-fails")
      expect([out, status]).to eq(["", 1])
      expect(err).to eq("chi sessions list failed (exit 1): chi: no state dir\n\n")
    end

    describe "another machine's sessions, through `chi remote ls`" do
      let(:rids) { Array.new(4) { SecureRandom.uuid } }

      def remote_session(index, **extra)
        { "id" => rids[index], "desc" => "r#{index}", "cwd" => "/Users/other/proj", "busy" => false, "owner" => nil,
          "updated_at" => "2026-10-27T09:00:00Z" }.merge(extra.transform_keys(&:to_s))
      end

      def remotes(*entries) = File.write(File.join(tmp, "remotes.json"), JSON.generate(entries))

      def remote_lists(name, live, recent)
        File.write(File.join(tmp, "#{name}-live.json"), JSON.generate(live))
        File.write(File.join(tmp, "#{name}-recent.json"), JSON.generate(recent))
      end

      def remote_mode(name, mode) = File.write(File.join(tmp, "#{name}.mode"), mode)

      def ids_of(rows) = rows.map { |r| [r["id"], r["recent"]] }

      before do
        remotes({ "name" => "studio", "url" => "http://10.0.0.9:4567", "token" => true },
                { "name" => "nokey", "url" => "http://10.0.0.8:4567", "token" => false },
                { "name" => "bad name", "url" => "http://10.0.0.7:4567", "token" => true },
                { "name" => "-x", "url" => "http://10.0.0.6:4567", "token" => true })
        remote_lists("studio", [remote_session(0)],
                     [remote_session(0), remote_session(1), remote_session(2, owner: "repl")])
      end

      it "lists each remote with a token after this Mac's rows, live then recent, with chi's own name rule" do
        result, err, status = sessions

        expect([err, status]).to eq(["", 0])
        expect(result["rows"].size).to eq(6)
        expect(result["remotes"].map { |r| r.except("rows", "new_dir") }).to eq([{ "name" => "studio", "error" => nil }])
        rows = result["remotes"][0]["rows"]
        expect(ids_of(rows)).to eq([[rids[0], false], [rids[1], true]])
        expect(rows[0]).to include("remote" => "studio", "cwd" => "/Users/other/proj")
        expect(calls).to include("--remote studio sessions list --live --sort created_at --order asc --scope=all --format json",
                                 "--remote studio sessions list --limit 20 --scope=all --format json")
        expect(calls.grep(/nokey|bad|-x /)).to eq([])
        # This Mac's new row stays on this Mac's folders.
        expect(result["new_dir"]).to eq(dirs[1])
      end

      it "keeps CHI_REMOTE from the shell away from chi: this Mac's rows stay this Mac's" do
        sessions(env: { "CHI_REMOTE" => "studio" })

        expect(File.readlines(File.join(tmp, "env"), chomp: true).uniq).to eq(["unset"])
      end

      it "says a remote gave no answer within 4 s, running its two lists at once, and keeps the other rows" do
        remotes({ "name" => "studio", "url" => "http://10.0.0.9:4567", "token" => true },
                { "name" => "pod", "url" => "http://10.0.0.5:4567", "token" => true })
        remote_mode("studio", "slow")
        remote_lists("pod", [remote_session(3)], [])
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result, err, status = sessions

        # Two sequential 4 s calls would take 8 s.
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 7
        expect([err, status]).to eq(["", 0])
        expect(result["rows"].size).to eq(6)
        expect(result["remotes"].map { |r| [r["name"], r["error"], ids_of(r["rows"])] })
          .to eq([["studio", "studio: no answer within 4 s", []], ["pod", nil, [[rids[3], false]]]])
      end

      it "shows the first line of chi's stderr when chi gives up by itself (a refused token)" do
        remote_mode("studio", "refused")
        result, = sessions

        expect(result["remotes"]).to eq([{ "name" => "studio", "rows" => [], "new_dir" => nil,
                                           "error" => "chi sessions: remote studio (http://10.0.0.9:4567): " \
                                                      "the token was refused (add it again)" }])
        expect(result["rows"].size).to eq(6)
      end

      it "skips Ruby's warnings for that line, and names the remote when its answer isn't a list" do
        File.write(File.join(tmp, "studio.mode"), "warned")
        result, = sessions
        expect(result["remotes"][0]["error"]).to eq("chi sessions: remote studio (http://10.0.0.9:4567): connection refused")

        File.write(File.join(tmp, "studio-live.json"), "<html>")
        File.delete(File.join(tmp, "studio.mode"))
        result, = sessions
        expect(result["remotes"][0]["error"]).to eq("studio: chi sessions list answered no session list")
      end

      it "lists a session once, where it shows first: this Mac, then the remotes in their order" do
        remotes({ "name" => "studio", "url" => "http://10.0.0.9:4567", "token" => true },
                { "name" => "studio-ts", "url" => "http://studio.ts.net", "token" => true })
        # studio is this Mac too (ids[0]); studio-ts is the same Studio by another address.
        remote_lists("studio", [session(0), remote_session(0)], [remote_session(1)])
        remote_lists("studio-ts", [remote_session(0), remote_session(3)], [remote_session(1)])
        result, = sessions

        expect(result["remotes"].map { |r| [r["name"], ids_of(r["rows"])] })
          .to eq([["studio", [[rids[0], false], [rids[1], true]]], ["studio-ts", [[rids[3], false]]]])
      end

      describe "a new session on a remote" do
        before do
          remotes({ "name" => "studio", "url" => "http://10.0.0.9:4567", "token" => true },
                  { "name" => "pod", "url" => "http://10.0.0.5:4567", "token" => true },
                  { "name" => "empty", "url" => "http://10.0.0.4:4567", "token" => true },
                  { "name" => "down", "url" => "http://10.0.0.3:4567", "token" => true })
          # studio: a live session, and a recent one updated later (live comes first).
          remote_lists("studio", [remote_session(0, cwd: "/Users/other/live", updated_at: "2026-10-27T08:00:00Z")],
                       [remote_session(1, cwd: "/Users/other/newer", updated_at: "2026-10-27T12:00:00Z")])
          # pod: recent only; the newest updated wins.
          remote_lists("pod", [], [remote_session(2, cwd: "/srv/old", updated_at: "2026-10-26T08:00:00Z"),
                                   remote_session(3, cwd: "/srv/pod", updated_at: "2026-10-27T08:00:00Z")])
          remote_lists("empty", [], [])
          remote_mode("down", "refused")
        end

        def new_dirs(result) = result["remotes"].to_h { |r| [r["name"], r["new_dir"]] }

        it "starts in that remote's newest session's folder, live first, never checked on this Mac; no session, no row" do
          result, err, status = sessions

          expect([err, status]).to eq(["", 0])
          expect(new_dirs(result))
            .to eq("studio" => "/Users/other/live", "pod" => "/srv/pod", "empty" => nil, "down" => nil)
          expect(result["new_dir"]).to eq(dirs[1])
        end

        it "is never preselected, whichever list answers first" do
          File.write(File.join(tmp, "live.json"), "[]")
          %w[local-first remotes-first].each do |order|
            result, = sessions("--order", order)
            expect(result.slice("selected", "new_selected", "new_remote"))
              .to eq("selected" => [], "new_selected" => true, "new_remote" => nil)
          end
        end

        it "is ticked alone: it clears the sessions and the new row, and either clears it; it names its machine" do
          result, = sessions("--click", ids[0], "--click", "studio:#{rids[0]}", "--click", "new:studio")
          expect(result.slice("selected", "new_selected", "new_remote", "hint"))
            .to eq("selected" => [], "new_selected" => false, "new_remote" => "studio", "hint" => " → studio")

          result, = sessions("--click", "new:studio", "--click", "studio:#{rids[0]}")
          expect(result.slice("selected", "new_remote")).to eq("selected" => ["studio:#{rids[0]}"], "new_remote" => nil)

          result, = sessions("--click", "new:studio", "--click", "new")
          expect(result.slice("new_selected", "new_remote")).to eq("new_selected" => true, "new_remote" => nil)

          result, = sessions("--click", "new", "--click", "new:pod")
          expect(result.slice("new_selected", "new_remote")).to eq("new_selected" => false, "new_remote" => "pod")

          result, = sessions("--click", "new:studio", "--click", "new:studio")
          expect(result["new_remote"]).to be_nil
        end

        it "has no row to tick on a remote without a folder" do
          result, = sessions("--click", "new:empty")
          expect(result["new_remote"]).to be_nil
        end

        it "refuses the model chooser on it: model choice is for this Mac's sessions" do
          result, = sessions("--click", "new:studio", "--click", "model")
          expect(result.slice("new_remote", "picker_open", "message"))
            .to eq("new_remote" => "studio", "picker_open" => false, "message" => "Model choice is for this Mac's sessions")

          result, = sessions("--click", "model")
          expect(result.slice("new_selected", "picker_open")).to eq("new_selected" => true, "picker_open" => true)
        end
      end

      describe "the preselection" do
        it "keeps the last choice where it is still live, a remote row's too, and says where it goes" do
          result, = sessions("--last", "studio:#{rids[0]}", "--last", "studio:#{rids[1]}")

          expect(result.slice("selected", "new_selected", "hint"))
            .to eq("selected" => ["studio:#{rids[0]}"], "new_selected" => false, "hint" => " → studio")
        end

        it "never picks a remote row as the only live session" do
          File.write(File.join(tmp, "live.json"), JSON.generate([session(0)]))
          result, = sessions
          expect(result.slice("selected", "new_selected", "hint"))
            .to eq("selected" => [ids[0]], "new_selected" => false, "hint" => "")

          File.write(File.join(tmp, "live.json"), "[]")
          result, = sessions
          expect(result.slice("selected", "new_selected")).to eq("selected" => [], "new_selected" => true)
        end

        # The panel's steps in the order the answers come: this Mac's list
        # ticks its only live session, then a late remote answer.
        it "never lets a late remote answer change what this Mac's list ticked (the user may be typing)" do
          File.write(File.join(tmp, "live.json"), JSON.generate([session(0)]))
          result, = sessions("--last", "studio:#{rids[0]}")
          expect(result.slice("selected", "hint")).to eq("selected" => [ids[0]], "hint" => "")

          File.write(File.join(tmp, "live.json"), "[]")
          result, = sessions("--last", "studio:#{rids[0]}")
          expect(result.slice("selected", "new_selected")).to eq("selected" => [], "new_selected" => true)
        end

        it "ticks the remembered remote row when the remote answers before this Mac's list" do
          File.write(File.join(tmp, "live.json"), JSON.generate([session(0)]))
          result, = sessions("--last", "studio:#{rids[0]}", "--order", "remotes-first")

          expect(result.slice("selected", "new_selected", "hint"))
            .to eq("selected" => ["studio:#{rids[0]}"], "new_selected" => false, "hint" => " → studio")
        end
      end
    end
  end

  describe "ChiHelper --send-plan, the chi call a send to sessions makes" do
    let(:ids) { [SecureRandom.uuid, SecureRandom.uuid] }
    let(:context) { "  \nline one\n" }

    # Each call's time limit only where asked.
    def plan(*args, stdin: context, timeouts: false)
      out, err, status = Open3.capture3(executable, "--send-plan", *args, stdin_data: stdin)
      expect([err, status.exitstatus]).to eq(["", 0])
      JSON.parse(out).map { |call| timeouts ? call : call.except("timeout") }
    end

    it "sends a message: -m, an --image per image, the ids last, the context on stdin" do
      result = plan("message", "--id", ids[0], "--id", ids[1], "--prompt", "  same bug? ",
                    "--image", "/tmp/a b.png", "--image", "/tmp/c.png")

      expect(result).to eq([{ "command" => "chi send", "stdin" => context,
                              "args" => ["send", "-m", "same bug?", "--image", "/tmp/a b.png", "--image", "/tmp/c.png", *ids] }])
    end

    it "sends the context alone as the message, a paste's chi part as a message, and no stdin without context" do
      expect(plan("message", "--id", ids[0])).to eq([{ "command" => "chi send", "args" => ["send", ids[0]], "stdin" => context }])
      expect(plan("paste", "--id", ids[0])).to eq(plan("message", "--id", ids[0]))
      expect(plan("message", "--id", ids[0], "--prompt", "hi", stdin: " \n"))
        .to eq([{ "command" => "chi send", "args" => ["send", "-m", "hi", ids[0]], "stdin" => nil }])
    end

    it "notes the message line then the context on stdin, with the trimmed source and no images" do
      result = plan("note", "--id", ids[0], "--id", ids[1], "--prompt", "look", "--source", " safari ", "--image", "/tmp/a.png")

      expect(result).to eq([{ "command" => "chi note", "args" => ["note", "--source", "safari", *ids],
                              "stdin" => "look\n\n#{context}" }])
      expect(plan("note", "--id", ids[0], stdin: "x")).to eq([{ "command" => "chi note", "args" => ["note", ids[0]], "stdin" => "x" }])
    end

    it "starts a new session in the new row's folder, with --model only for a pick that isn't the default" do
      dir = Dir.pwd
      expect(plan("message", "--new", dir, "--id", ids[0], "--prompt", "hi"))
        .to eq([{ "command" => "chi send", "args" => ["send", "--new", "--dir", dir, "-m", "hi"], "stdin" => context }])
      expect(plan("message", "--new", dir, "--default", "box:small", "--model", "qwen", "--image", "/tmp/a.png").first["args"])
        .to eq(["send", "--new", "--dir", dir, "--model", "qwen", "--image", "/tmp/a.png"])
      expect(plan("message", "--new", dir, "--default", "box:small", "--model", "BOX:small").first["args"])
        .to eq(["send", "--new", "--dir", dir])
    end

    it "starts a new session on a remote in its folder (--new REMOTE:DIR), never with --model, 15 s for text" do
      result = plan("message", "--new", "studio:/Users/other/proj", "--default", "box:small", "--model", "qwen",
                    "--prompt", "hi", timeouts: true)
      expect(result).to eq([{ "command" => "chi send", "stdin" => context, "timeout" => 15,
                              "args" => ["--remote", "studio", "send", "--new", "--dir", "/Users/other/proj", "-m", "hi"] }])
      expect(plan("message", "--new", "studio:/Users/other/proj", "--image", "/tmp/a.png", timeouts: true))
        .to eq([{ "command" => "chi send", "stdin" => context, "timeout" => 30,
                  "args" => ["--remote", "studio", "send", "--new", "--dir", "/Users/other/proj", "--image", "/tmp/a.png"] }])
      expect(plan("message", "--new", "bad name:/Users/other/proj")).to eq([])
    end

    describe "to sessions on other machines (an --id of remote:ID)" do
      let(:rid) { SecureRandom.uuid }

      it "makes one call per machine, this Mac's first, --remote NAME only on a remote's, 15 s for a remote's text" do
        result = plan("message", "--id", "studio:#{rid}", "--id", ids[0], "--id", "pod:#{ids[1]}", "--id", "studio:#{ids[1]}",
                      "--prompt", "hi", timeouts: true)

        expect(result).to eq([
          { "command" => "chi send", "args" => ["send", "-m", "hi", ids[0]], "stdin" => context, "timeout" => 10 },
          { "command" => "chi send", "args" => ["--remote", "studio", "send", "-m", "hi", rid], "stdin" => context,
            "timeout" => 15 },
          { "command" => "chi send", "args" => ["--remote", "pod", "send", "-m", "hi", ids[1]], "stdin" => context,
            "timeout" => 15 }
        ])
        expect(plan("message", "--id", "studio:#{rid}", "--prompt", "hi", "--image", "/tmp/a.png", timeouts: true)
          .map { |c| c["timeout"] }).to eq([30])
        expect(plan("note", "--id", ids[0], "--id", "studio:#{rid}", stdin: "x"))
          .to eq([{ "command" => "chi note", "args" => ["note", ids[0]], "stdin" => "x" },
                  { "command" => "chi note", "args" => ["--remote", "studio", "note", rid], "stdin" => "x" }])
      end

      it "sends to a session once, the first machine it is listed on" do
        expect(plan("message", "--id", ids[0], "--id", "studio:#{ids[0]}", "--id", "pod:#{ids[0]}").map { |c| c["args"] })
          .to eq([["send", ids[0]]])
      end

      it "leaves out a remote whose name chi wouldn't take" do
        expect(plan("message", "--id", "bad name:#{rid}", "--id", "-x:#{rid}", "--id", ids[0]).map { |c| c["args"] })
          .to eq([["send", ids[0]]])
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
