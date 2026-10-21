# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require_relative "../script/deps/deps_check"

# `rake deps:check` (Rakefile): engines, gems and npm against a temp state
# file, every HTTP request and command stubbed.
RSpec.describe DepsCheck do
  let(:tmp) { Dir.mktmpdir("deps-check-") }
  let(:state_path) { File.join(tmp, "state", "deps-check.json") }
  let(:llama) { DepsCheck::Host.new(name: "main", host: "192.168.1.29", port: 8081, scheme: "http", api: nil) }
  let(:splash) { DepsCheck::Host.new(name: "splash", host: "192.168.1.29", port: 8082, scheme: "http", api: "openai") }
  let(:public_host) do
    DepsCheck::Host.new(name: "openrouter", host: "openrouter.ai", port: 443, scheme: "https", api: "openai")
  end
  let(:hosts) { [llama, splash, public_host] }
  let(:commands) do
    {
      %w[bundle outdated --only-explicit --parseable] =>
        ["Fetching gem metadata from https://rubygems.org/...\n\n" \
         "rubocop (newest 1.92.0, installed 1.91.0, requested ~> 1.91)\nwebmock (newest 3.34.0, installed 3.26.2)\n",
         "", 1],
      %w[npm outdated --json] =>
        [JSON.generate("eslint" => { "current" => "10.13.0", "wanted" => "10.14.0", "latest" => "10.14.0" }), "", 1],
      %w[npm audit --json] => [JSON.generate(audit_data), "", 1]
    }
  end
  let(:audit_data) do
    { "vulnerabilities" => {
      "brace-expansion" => { "severity" => "low", "via" => [
        { "source" => 1, "title" => "ReDoS", "url" => "https://github.com/advisories/GHSA-low", "severity" => "low" }
      ] },
      "minimist" => { "severity" => "critical", "via" => [
        { "source" => 2, "title" => "Prototype pollution", "url" => "https://github.com/advisories/GHSA-crit",
          "severity" => "critical" }
      ] },
      "mkdirp" => { "severity" => "critical", "via" => ["minimist"] }
    } }
  end

  after { FileUtils.rm_rf(tmp) }

  before do
    allow(Open3).to receive(:capture3) do |*argv, chdir:|
      expect(chdir).to eq(tmp)
      out, err, code = commands.fetch(argv)
      [out, err, instance_double(Process::Status, success?: code.zero?)]
    end
  end

  def stub_llama(build: "b11700-abc1234", up: true)
    stub = stub_request(:get, "http://192.168.1.29:8081/props")
    return stub.to_raise(Errno::ECONNREFUSED) unless up

    stub.to_return(body: JSON.generate("build_info" => build, "model_path" => "/models/gemma.gguf"))
  end

  def stub_splash(build_id: "src-aaaa1111", up: true)
    props = stub_request(:get, "http://192.168.1.29:8082/props")
    return props.to_timeout unless up

    props.to_return(status: 404, body: JSON.generate("error" => { "message" => "not found" }))
    stub_request(:get, "http://192.168.1.29:8082/status").to_return(body: JSON.generate(
      "schema_version" => 3, "chat_template" => {}, "instance" => { "model" => "Qwen3.6-35B" },
      "identity" => { "cache" => { "build_id" => build_id } }
    ))
  end

  def stub_github(splash_tag: "1.4.0", llama_tag: "b11803", status: 200)
    splash_releases = [
      { "tag_name" => "1.5.0-rc1", "prerelease" => true, "draft" => false },
      { "tag_name" => splash_tag, "prerelease" => false, "draft" => false, "published_at" => "2026-10-20T22:35:11Z",
        "html_url" => "https://github.com/incoai/splash/releases/tag/#{splash_tag}" }
    ]
    llama_releases = [{ "tag_name" => llama_tag, "prerelease" => true, "draft" => false,
                        "published_at" => "2026-10-21T22:30:59Z",
                        "html_url" => "https://github.com/ggml-org/llama.cpp/releases/tag/#{llama_tag}" }]
    { "incoai/splash" => splash_releases, "ggml-org/llama.cpp" => llama_releases }.each do |repo, list|
      stub_request(:get, %r{\Ahttps://api\.github\.com/repos/#{Regexp.escape(repo)}/releases})
        .to_return(status: status, body: status == 200 ? JSON.generate(list) : "{}")
    end
  end

  def check(format: nil, now: Time.utc(2026, 10, 22, 12)) =
    described_class.check(tmp, format: format, hosts: hosts, state_path: state_path, now: now)

  def new_lines(text) = text.lines.select { |l| l.start_with?("NEW") }.map(&:strip)

  context "with every engine up" do
    before do
      stub_llama
      stub_splash
      stub_github
    end

    it "tells llama.cpp and Splash apart and shows each upstream release, llama.cpp with its builds behind" do
      out = check
      expect(out).to include("llama.cpp 192.168.1.29:8081  b11700-abc1234 · gemma.gguf · upstream b11803 (2026-10-21), " \
                             "103 builds behind https://github.com/ggml-org/llama.cpp/releases/tag/b11803")
      expect(out).to include("splash 192.168.1.29:8082  version unknown · Qwen3.6-35B · upstream 1.4.0 (2026-10-20) " \
                             "https://github.com/incoai/splash/releases/tag/1.4.0")
      expect(out).to include(%(record it: rake "deps:splash_version[X.Y.Z]"))
    end

    it "never probes a host on a public address" do
      check
      expect(a_request(:any, /openrouter\.ai/)).not_to have_been_made
    end

    it "lists outdated gems and npm packages, and npm advisories most severe first" do
      out = check
      expect(out).to include("rubocop 1.91.0 → 1.92.0 (Gemfile ~> 1.91)", "webmock 3.26.2 → 3.34.0")
      expect(out).to include("eslint 10.13.0 → 10.14.0")
      expect(out).not_to include("Fetching gem metadata")
      advisories = out.lines.grep(/advisory/)
      expect(advisories.map(&:strip)).to eq([
        "NEW advisory critical: minimist · Prototype pollution https://github.com/advisories/GHSA-crit",
        "NEW advisory low: brace-expansion · ReDoS https://github.com/advisories/GHSA-low"
      ])
    end

    it "marks everything NEW on the first run and nothing on a second run that saw the same" do
      first = check
      expect(first).to include("first run: all NEW")
      expect(new_lines(first).size).to eq(7)
      second = check(now: Time.utc(2026, 10, 22, 13))
      expect(second).to include("NEW = changed since 2026-10-22T12:00:00Z")
      expect(new_lines(second)).to be_empty
    end

    it "marks NEW only what changed since the last run, NEW lines first" do
      check
      WebMock.reset!
      stub_llama(build: "b11790-def")
      stub_splash
      stub_github(splash_tag: "1.4.1")
      commands[%w[bundle outdated --only-explicit --parseable]][0] =
        "rubocop (newest 1.92.0, installed 1.91.0, requested ~> 1.91)\nwebmock (newest 3.35.0, installed 3.26.2)\n"
      out = check
      expect(new_lines(out)).to eq([
        "NEW llama.cpp 192.168.1.29:8081  b11790-def · gemma.gguf · upstream b11803 (2026-10-21), 13 builds behind " \
        "https://github.com/ggml-org/llama.cpp/releases/tag/b11803",
        "NEW splash 192.168.1.29:8082  version unknown · Qwen3.6-35B · upstream 1.4.1 (2026-10-20) " \
        "https://github.com/incoai/splash/releases/tag/1.4.1",
        "NEW webmock 3.26.2 → 3.35.0"
      ])
    end

    it "gives the same data as JSON" do
      data = JSON.parse(check(format: "json"))
      expect(data.keys).to eq(%w[checked_at previous_checked_at engines gems npm])
      llama_row = data["engines"]["hosts"].find { |h| h["kind"] == "llama.cpp" }
      expect(llama_row).to include("address" => "192.168.1.29:8081", "status" => "up", "build_info" => "b11700-abc1234",
                                   "builds_behind" => 103, "new" => true)
      expect(data["engines"]["upstream"]["splash"]).to eq(
        "tag" => "1.4.0", "date" => "2026-10-20", "url" => "https://github.com/incoai/splash/releases/tag/1.4.0"
      )
      expect(data["gems"]["outdated"].first).to include("name" => "rubocop", "requested" => "~> 1.91")
      expect(data["npm"]["advisories"].map { |a| a["id"] }).to eq(%w[https://github.com/advisories/GHSA-crit
                                                                     https://github.com/advisories/GHSA-low])
    end
  end

  describe "the recorded Splash version" do
    before do
      stub_llama
      stub_github
    end

    it "is shown against upstream once recorded" do
      stub_splash
      lines = described_class.record_splash_version("1.3.2", hosts: hosts, state_path: state_path)
      expect(lines).to eq(["splash 192.168.1.29:8082: recorded 1.3.2 (build aaaa1111)"])
      out = check
      expect(out).to include("splash 192.168.1.29:8082  recorded 1.3.2 · Qwen3.6-35B · upstream 1.4.0")
      expect(out).not_to include("record it")
    end

    it "asks to confirm it once Splash's build_id changes" do
      stub_splash
      described_class.record_splash_version("1.3.2", hosts: hosts, state_path: state_path)
      check
      stub_splash(build_id: "src-bbbb2222")
      out = check
      expect(new_lines(out).first).to start_with("NEW splash 192.168.1.29:8082  recorded 1.3.2")
      expect(out).to include("Splash on 192.168.1.29:8082 changed build since you recorded 1.3.2: " \
                             "confirm with `splash --version` and record it")
    end

    it "records one host given as host:port, and refuses when no Splash answers there" do
      stub_splash
      expect(described_class.record_splash_version("1.3.2", address: "192.168.1.29:8082", hosts: hosts,
                                                             state_path: state_path).size).to eq(1)
      expect do
        described_class.record_splash_version("1.3.2", address: "192.168.1.29:8081", hosts: hosts, state_path: state_path)
      end.to raise_error(DepsCheck::Error, "no Splash host answered /status on 192.168.1.29:8081")
      expect do
        described_class.record_splash_version("latest", hosts: hosts, state_path: state_path)
      end.to raise_error(DepsCheck::Error, /not a version/)
    end
  end

  it "says a host that stopped answering is down and skipped (NEW once), with what it ran last time" do
    stub_llama
    stub_splash
    stub_github
    check
    stub_llama(up: false)
    stub_splash(up: false)
    out = check
    expect(out).to include("NEW llama.cpp 192.168.1.29:8081  down, skipped (last seen b11700-abc1234) · upstream b11803")
    expect(out).to include("NEW splash 192.168.1.29:8082  down, skipped · upstream 1.4.0")
    expect(out).not_to include("changed build")
    expect(new_lines(check)).to be_empty
  end

  it "guesses llama.cpp for a down host without api: on the first run, and skips a host that is neither" do
    stub_llama(up: false)
    stub_request(:get, "http://192.168.1.29:8082/props").to_return(status: 404)
    stub_request(:get, "http://192.168.1.29:8082/status").to_return(body: "{}")
    stub_github
    out = check
    expect(out).to include("NEW llama.cpp 192.168.1.29:8081  down, skipped · upstream b11803")
    expect(out).not_to include("8082")
  end

  it "keeps the other sections when GitHub fails, and compares with the last tags it had" do
    stub_llama
    stub_splash
    stub_github
    check
    stub_github(status: 403)
    out = check
    expect(out).to include("upstream llama.cpp: api.github.com: HTTP 403 (rate limit?)")
    expect(out).to include("    rubocop 1.91.0 → 1.92.0")
    expect(new_lines(out)).to be_empty
    expect(JSON.parse(File.read(state_path))["upstream"]["splash"]["tag"]).to eq("1.4.0")
  end

  it "says why when bundle or npm can't run, and keeps what it knew" do
    stub_github
    hosts.clear
    check
    commands[%w[bundle outdated --only-explicit --parseable]] = ["", "Could not reach rubygems.org\n", 7]
    commands[%w[npm audit --json]] = [JSON.generate("error" => { "summary" => "audit endpoint down" }), "", 1]
    out = check
    expect(out).to include("bundle outdated failed: Could not reach rubygems.org", "npm audit: audit endpoint down")
    expect(out).to include("no Splash or llama.cpp host on a private address")
    state = JSON.parse(File.read(state_path))
    expect(state["gems"]).to eq("rubocop" => "1.92.0", "webmock" => "3.34.0")
    expect(state["advisories"].size).to eq(2)
  end

  describe ".local_host?" do
    it "takes loopback, private and LAN names as local, anything else as public" do
      local = %w[localhost 127.0.0.1 10.0.0.5 172.16.3.4 192.168.1.29 ::1 [fd00::1] studio studio.local mac.lan]
      public = %w[openrouter.ai api.anthropic.com 8.8.8.8 172.32.0.1]
      expect(local.reject { |h| described_class.local_host?(h) }).to be_empty
      expect(public.select { |h| described_class.local_host?(h) }).to be_empty
    end
  end

  describe ".config_hosts" do
    after { remove_hosts_config_homes }

    it "reads config.yml's hosts: entries" do
      stub_hosts_config("main" => { "host" => "192.168.1.29", "port" => 8081 },
                        "router" => { "url" => "https://openrouter.ai/api/v1", "api" => "openai" })
      expect(described_class.config_hosts.map { |h| [h.name, h.address, h.api] }).to contain_exactly(
        ["main", "192.168.1.29:8081", nil], ["router", "openrouter.ai:443", "openai"]
      )
    end
  end

  describe ".state_path" do
    it "is DEPS_CHECK_STATE, else under XDG_STATE_HOME" do
      expect(described_class.state_path(env: { "DEPS_CHECK_STATE" => "/x/s.json" })).to eq("/x/s.json")
      expect(described_class.state_path(env: { "XDG_STATE_HOME" => "/st" })).to eq("/st/samagotchi/deps-check.json")
    end
  end
end
