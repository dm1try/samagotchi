# frozen_string_literal: true

require "yaml"
require "open3"
require "tmpdir"
require "fileutils"
require "digest"
require "samagotchi/hooks"
require "samagotchi/answer_display"

# The source-links bundle (lib/samagotchi/bundles/source-links): an
# after_turn hook that announces the source refs (JIRA tickets, GitHub
# issues, …) the model's answer mentions as one line after the turn.
RSpec.describe "The source-links bundle" do
  let(:bundle_dir) { File.expand_path("../../../lib/samagotchi/bundles/source-links", __dir__) }
  let(:manifest) { YAML.safe_load_file(File.join(bundle_dir, "manifest.yml")) }
  let(:settings) do
    {
      "sources" => [
        { "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/" }
      ]
    }
  end
  let(:notices) { [] }
  let(:registry) do
    registry = Samagotchi::Hooks::Registry.new
    loaded = Samagotchi::Hooks::BundleLoader.load(bundle_name: "source-links", hooks_dir: File.join(bundle_dir, "hooks"),
                                                  metadata: manifest["hooks"], registry: registry, settings: settings)
    raise "the hook did not load" unless loaded == 1

    registry.runtime = Samagotchi::Hooks::Runtime.new(
      notify: ->(**kw) { notices << kw },
      ask_user: ->(**) {},
      stop_turn: ->(**) { false }
    )
    registry
  end

  # Fire :after_turn with the given messages and return the notices.
  def fire(messages, status: "completed")
    registry.fire(:after_turn, { type: :after_turn, status: status, messages: messages })
    notices
  end

  def model(content) = { role: "model", content: content }
  def user(content) = { role: "user", content: content }

  it "notifies with the refs in first-occurrence order, deduped, with URLs" do
    fire([user("hi"), model("See JIRA-123 and JIRA-10, then JIRA-123 again.")])
    expect(notices).to eq([{ text: "sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123, " \
                                   "JIRA JIRA-10 → https://myjira.com/browse/JIRA-10",
                             level: :info, hook: "source_links.rb (bundle source-links)" }])
  end

  it "scans only the last model message" do
    fire([model("JIRA-1"), user("and?"), model("nothing here")])
    expect(notices).to be_empty
  end

  it "handles string-keyed messages" do
    fire([{ "role" => "model", "content" => "JIRA-7" }])
    expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-7 → https://myjira.com/browse/JIRA-7"])
  end

  it "does not notify on a canceled turn" do
    fire([model("JIRA-123")], status: "canceled")
    expect(notices).to be_empty
  end

  it "does not notify when the turn ends with a turn_note and no model answer" do
    fire([user("hi"), { role: "system", content: "…", kind: "turn_note" }])
    expect(notices).to be_empty
  end

  it "does not notify when there is no model message at all" do
    fire([user("hi")])
    expect(notices).to be_empty
  end

  it "is a silent no-op with no sources configured" do
    settings.replace({})
    fire([model("JIRA-123")])
    expect(notices).to be_empty
  end

  describe "the pattern form" do
    let(:settings) do
      {
        "sources" => [
          { "name" => "GitHub", "pattern" => '\bGH-(\d+)\b', "url" => "https://github.com/org/repo/issues/{match}" }
        ]
      }
    end

    it "uses the first capture group for {match}" do
      fire([model("fixed in GH-42")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: GitHub GH-42 → https://github.com/org/repo/issues/42"])
    end

    it "uses the full match when the pattern has no group" do
      settings.replace("sources" => [{ "name" => "Wiki", "pattern" => "WIKI-\\d+", "url" => "https://wiki/{match}" }])
      fire([model("see WIKI-9")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: Wiki WIKI-9 → https://wiki/WIKI-9"])
    end

    it "honours case_insensitive" do
      settings.replace("sources" => [{ "name" => "GH", "pattern" => "gh-(\\d+)", "url" => "https://x/{match}",
                                       "case_insensitive" => true }])
      fire([model("see GH-5")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: GH GH-5 → https://x/5"])
    end

    it "is case-sensitive by default" do
      settings.replace("sources" => [{ "name" => "GH", "pattern" => "gh-(\\d+)", "url" => "https://x/{match}" }])
      fire([model("see GH-5")])
      expect(notices).to be_empty
    end
  end

  describe "the URL-skip rule" do
    it "skips a ref inside a bare URL and links one after a space" do
      fire([model("https://x.com/JIRA-123 and see https://x.com JIRA-10")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-10 → https://myjira.com/browse/JIRA-10"])
    end

    it "stops a bare URL at an unbalanced closing paren" do
      fire([model("(https://x.com/a)JIRA-4")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-4 → https://myjira.com/browse/JIRA-4"])
    end

    it "keeps a balanced paren inside a bare URL" do
      fire([model("see https://en.wikipedia.org/wiki/JIRA-8_(bar) and JIRA-9")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-9 → https://myjira.com/browse/JIRA-9"])
    end

    it "skips a ref in a markdown link's label when the target names the same ref" do
      fire([model("[JIRA-123](https://x.com/JIRA-123) plus JIRA-10")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-10 → https://myjira.com/browse/JIRA-10"])
    end

    it "links a ref in a markdown link's label when the target is something else" do
      fire([model("[fix for JIRA-123](https://github.com/o/r/pull/9)")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123"])
    end

    it "announces a label ref when the target names a different ref (JIRA-1 vs JIRA-12)" do
      fire([model("[JIRA-1](https://myjira.com/browse/JIRA-12)")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-1 → https://myjira.com/browse/JIRA-1"])
    end

    it "skips a label ref whose target names it in another case, for a case_insensitive source" do
      settings.replace("sources" => [{ "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/",
                                       "case_insensitive" => true }])
      fire([model("[jira-123](https://x.com/JIRA-123) plus JIRA-10")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-10 → https://myjira.com/browse/JIRA-10"])
    end

    it "keeps the label ref when only the case matches the target, for a case-sensitive pattern" do
      settings.replace("sources" => [{ "name" => "GH", "pattern" => "gh-(\\d+)", "url" => "https://x/{1}" }])
      fire([model("[gh-5](https://x.com/GH-5)")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: GH gh-5 → https://x/5"])
    end

    it "skips a ref in a markdown link's target" do
      fire([model("[the fix](https://x.com/JIRA-123)")])
      expect(notices).to be_empty
    end

    it "skips a ref in a query string" do
      fire([model("?key=JIRA-123")])
      expect(notices).to be_empty
    end

    it "skips a ref in a relative path" do
      fire([model("/browse/JIRA-123")])
      expect(notices).to be_empty
    end

    it "skips a ref followed by a slash" do
      fire([model("JIRA-123/foo")])
      expect(notices).to be_empty
    end

    it "links a ref after a colon or a hash (plain-text ticket shapes)" do
      fire([model("Ticket:JIRA-5 and #JIRA-6")])
      expect(notices.map { |n| n[:text] }).to eq(
        ["sources: JIRA JIRA-5 → https://myjira.com/browse/JIRA-5, " \
         "JIRA JIRA-6 → https://myjira.com/browse/JIRA-6"]
      )
    end
  end

  describe "ordering and dedupe" do
    let(:settings) do
      {
        "sources" => [
          { "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/" },
          { "name" => "GitHub", "pattern" => '\bGH-(\d+)\b', "url" => "https://github.com/org/repo/issues/{match}" }
        ]
      }
    end

    it "lists refs in first-occurrence order, not config order" do
      fire([model("GH-1 then JIRA-2")])
      expect(notices.map { |n| n[:text] }).to eq(
        ["sources: GitHub GH-1 → https://github.com/org/repo/issues/1, " \
         "JIRA JIRA-2 → https://myjira.com/browse/JIRA-2"]
      )
    end

    it "dedupes case-insensitively" do
      settings.replace("sources" => [{ "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/",
                                       "case_insensitive" => true }])
      fire([model("JIRA-123 and jira-123")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123"])
    end
  end

  describe "placeholders in the url template" do
    def texts = notices.map { |n| n[:text] }

    def warned_events
      events = []
      allow(Samagotchi::Log).to receive(:warn).and_wrap_original do |original, *args, **kw|
        events << [args[1], kw[:echo]]
        original.call(*args, **kw)
      end
      events
    end

    it "fills numbered groups" do
      settings.replace("sources" => [{ "name" => "GH", "pattern" => '\b([a-z]+)/([a-z]+)!(\d+)\b',
                                       "url" => "https://gh.test/{1}/{2}/pull/{3}" }])
      fire([model("see acme/web!7")])
      expect(texts).to eq(["sources: GH acme/web!7 → https://gh.test/acme/web/pull/7"])
    end

    it "fills named groups" do
      settings.replace("sources" => [{ "name" => "T", "pattern" => '\b(?<proj>[A-Z]+)~(?<num>\d+)\b',
                                       "url" => "https://t.test/{proj}/{num}" }])
      fire([model("see ABC~12")])
      expect(texts).to eq(["sources: T ABC~12 → https://t.test/ABC/12"])
    end

    it "skips a ref whose numbered or named group did not take part" do
      settings.replace("sources" => [
        { "name" => "N", "pattern" => '\bN(?:-(\d+))?!', "url" => "https://n.test/{1}" },
        { "name" => "M", "pattern" => '\bM(?:-(?<id>\d+))?!', "url" => "https://m.test/{id}" }
      ])
      fire([model("N! and M! but N-3! and M-4!")])
      expect(texts).to eq(["sources: N N-3! → https://n.test/3, M M-4! → https://m.test/4"])
    end

    it "leaves an unknown {word} and an out-of-range {7} as text and warns once at compile" do
      events = warned_events
      settings.replace("sources" => [{ "name" => "W", "pattern" => '\bW-(\d+)\b',
                                       "url" => "https://w.test/{match}/{nope}/{7}" }])
      fire([model("W-1")])
      fire([model("W-2")])
      expect(texts).to eq(["sources: W W-1 → https://w.test/1/{nope}/{7}", "sources: W W-2 → https://w.test/2/{nope}/{7}"])
      placeholder_warnings = events.select { |event, _| event == "source_links_unknown_placeholder" }
      expect(placeholder_warnings.size).to eq(1)
      expect(placeholder_warnings.first[1]).to include("{nope}", "{7}", "W")
    end

    it "keeps the slashes of {repo} from a named group and escapes each segment" do
      settings.replace("sources" => [{ "name" => "GL", "pattern" => '\b(?<repo>[\w/ ]+\w)!(?<num>\d+)\b',
                                       "url" => "https://gl.test/{repo}/-/merge_requests/{num}" }])
      fire([model("group/sub/my proj!5")])
      expect(texts).to eq(["sources: GL group/sub/my proj!5 → https://gl.test/group/sub/my%20proj/-/merge_requests/5"])
    end

    it "escapes / in {match} and other names" do
      settings.replace("sources" => [{ "name" => "W", "pattern" => '\bW:(?<page>[a-z/]+)', "url" => "https://w.test/{page}" }])
      fire([model("W:a/b")])
      expect(texts).to eq(["sources: W W:a/b → https://w.test/a%2Fb"])
    end

    it "skips a {repo} with an empty, . or .. segment" do
      settings.replace("sources" => [{ "name" => "GH", "pattern" => '(?<repo>[\w./]+)#(?<num>\d+)',
                                       "url" => "https://gh.test/{repo}/issues/{num}" }])
      fire([model("../x#6 a//b#7 ./c#8 ok/repo#9")])
      expect(texts).to eq(["sources: GH ok/repo#9 → https://gh.test/ok/repo/issues/9"])
    end

    it "{match} is the first named group when the pattern has named groups, else the whole ref" do
      settings.replace("sources" => [{ "name" => "GH", "pattern" => '(?:(?<repo>[a-z]+/[a-z]+))?#(?<num>\d+)',
                                       "url" => "https://gh.test/{match}" }])
      fire([model("o/r#1 and #2")])
      expect(texts).to eq(["sources: GH o/r#1 → https://gh.test/o%2Fr, GH #2 → https://gh.test/%232"])
    end

    it "lists one URL once: two refs to the same URL, the first wins" do
      settings.replace("sources" => [{ "name" => "GH", "pattern" => '(?:(?<repo>[a-z]+/[a-z]+))?#(?<num>\d+)',
                                       "url" => "https://gh.test/o/r/issues/{num}" }])
      fire([model("#12 is o/r#12, and x/y#12 too")])
      expect(texts).to eq(["sources: GH #12 → https://gh.test/o/r/issues/12"])
    end

    it "lets another source link a ref the first one left unlinked" do
      settings.replace("sources" => [
        { "name" => "Opt", "pattern" => '\bX(?:-(\d+))?\b', "url" => "https://opt.test/{1}" },
        { "name" => "Any", "pattern" => '\bX\b', "url" => "https://any.test/{match}" }
      ])
      fire([model("just X")])
      expect(texts).to eq(["sources: Any X → https://any.test/X"])
    end

    it "does not link an unresolved ref in the answer either" do
      settings.replace("sources" => [{ "name" => "N", "pattern" => '\bN(?:-(\d+))?!', "url" => "https://n.test/{1}" }])
      messages = [user("q"), model("N! and N-3!")]
      answer = Samagotchi::AnswerDisplay.new(messages)
      event = { type: :after_turn, status: "completed", messages: messages }
      event[:present] = answer.presenter(event)
      registry.fire(:after_turn, event)
      expect(answer.text).to eq("N! and [N-3!](https://n.test/3)")
    end
  end

  describe "parsing a git remote URL" do
    def parse(url)
      registry # loads the hook's class
      Samagotchi::Hooks::BundleLoader.send(:namespace_for, "source-links")::SourceLinks.parse_remote_url(url)
    end

    {
      "https://user:pw@github.com:8443/o/r.git" => { host: "github.com", repo: "o/r" },
      "http://git.example.com/o/r" => { host: "git.example.com", repo: "o/r" },
      "ssh://git@github.com:22/o/r.git/" => { host: "github.com", repo: "o/r" },
      "git://github.com/o/r.git" => { host: "github.com", repo: "o/r" },
      "git@github.com:dm1try/samagotchi.git" => { host: "github.com", repo: "dm1try/samagotchi" },
      "gh:o/r" => { host: "gh", repo: "o/r" },
      "git@github-work:o/r" => { host: "github-work", repo: "o/r" },
      "https://gitlab.com/group/sub/proj.git" => { host: "gitlab.com", repo: "group/sub/proj" },
      "/srv/git/r.git" => nil,
      "./r" => nil,
      "../r" => nil,
      "file:///srv/git/r.git" => nil,
      "https://github.com/" => nil,
      "https://github.com/a/../b" => nil,
      "git@github.com:a/./b.git" => nil,
      "" => nil
    }.each do |url, expected|
      it "#{url.inspect} → #{expected.inspect}" do
        expect(parse(url)).to eq(expected)
      end
    end
  end

  describe "{repo} and {host} from the project's git remote" do
    let(:github_pattern) { '(?<![\w/&])(?:(?<repo>[A-Za-z0-9][\w-]*/[\w.-]*\w))?#(?<num>\d+)\b' }
    let(:github) { { "name" => "GitHub", "pattern" => github_pattern, "url" => "https://github.com/{repo}/issues/{num}" } }
    let(:settings) { { "sources" => [github] } }
    let(:tmp) { Dir.mktmpdir("source-links-remote-") }

    around do |example|
      # The user's own git config (insteadOf rewrites) stays out of it.
      saved = ENV.to_h.slice("GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM")
      ENV["GIT_CONFIG_GLOBAL"] = File::NULL
      ENV["GIT_CONFIG_NOSYSTEM"] = "1"
      example.run
    ensure
      %w[GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM].each { |key| saved.key?(key) ? ENV[key] = saved[key] : ENV.delete(key) }
      FileUtils.rm_rf(tmp)
    end

    def git(*args) = system("git", "-C", tmp, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(" ")} failed")

    def repo_with(remotes)
      git("init", "-q")
      remotes.each { |name, url| git("remote", "add", name, url) }
    end

    def texts = notices.map { |n| n[:text] }

    it "links #12 to the origin's repo, and a qualified ref to its own" do
      repo_with("origin" => "git@github.com:dm1try/samagotchi.git")
      Dir.chdir(tmp) { fire([model("See #12 and rails/rails#5.")]) }
      expect(texts).to eq(["sources: GitHub #12 → https://github.com/dm1try/samagotchi/issues/12, " \
                           "GitHub rails/rails#5 → https://github.com/rails/rails/issues/5"])
    end

    it "fills {repo} and {host} from the remote for a pattern with no repo group" do
      repo_with("origin" => "https://gitlab.example.com/group/proj.git")
      github["pattern"] = '(?<![\w/&])#(\d+)\b'
      github["url"] = "https://{host}/{repo}/-/issues/{1}"
      Dir.chdir(tmp) { fire([model("#7")]) }
      expect(texts).to eq(["sources: GitHub #7 → https://gitlab.example.com/group/proj/-/issues/7"])
    end

    it "reads the remote named by remote:" do
      repo_with("origin" => "git@github.com:me/fork.git", "upstream" => "https://github.com/them/proj.git")
      github["remote"] = "upstream"
      Dir.chdir(tmp) { fire([model("#3")]) }
      expect(texts).to eq(["sources: GitHub #3 → https://github.com/them/proj/issues/3"])
    end

    it "fills {host} from the remote" do
      repo_with("origin" => "https://gitlab.example.com/group/sub/proj.git")
      github["url"] = "https://{host}/{repo}/-/issues/{num}"
      Dir.chdir(tmp) { fire([model("#4")]) }
      expect(texts).to eq(["sources: GitHub #4 → https://gitlab.example.com/group/sub/proj/-/issues/4"])
    end

    it "does not fill {host} from the remote for a ref that names its own repo" do
      repo_with("origin" => "https://gitlab.example.com/group/sub/proj.git")
      github["url"] = "https://{host}/{repo}/-/issues/{num}"
      Dir.chdir(tmp) { fire([model("#4 and other/repo#12")]) }
      expect(texts).to eq(["sources: GitHub #4 → https://gitlab.example.com/group/sub/proj/-/issues/4"])
    end

    it "fills {host} for such a ref when the remote's host is remote_host:" do
      repo_with("origin" => "https://gitlab.example.com/group/sub/proj.git")
      github["url"] = "https://{host}/{repo}/-/issues/{num}"
      github["remote_host"] = "gitlab.example.com"
      Dir.chdir(tmp) { fire([model("other/repo#12")]) }
      expect(texts).to eq(["sources: GitHub other/repo#12 → https://gitlab.example.com/other/repo/-/issues/12"])
    end

    it "does not link a remote-derived ref when the remote's host is not remote_host:" do
      repo_with("origin" => "git@gitlab.com:o/r.git")
      github["remote_host"] = "github.com"
      Dir.chdir(tmp) { fire([model("#12 and rails/rails#5")]) }
      expect(texts).to eq(["sources: GitHub rails/rails#5 → https://github.com/rails/rails/issues/5"])
    end

    it "compares remote_host case-insensitively and takes a list" do
      repo_with("origin" => "git@GitHub-Work:o/r.git")
      github["remote_host"] = ["github.com", "github-work"]
      Dir.chdir(tmp) { fire([model("#1")]) }
      expect(texts).to eq(["sources: GitHub #1 → https://github.com/o/r/issues/1"])
    end

    it "never calls git for a qualified ref" do
      expect(Open3).not_to receive(:capture2)
      Dir.chdir(tmp) { fire([model("rails/rails#5")]) }
      expect(texts).to eq(["sources: GitHub rails/rails#5 → https://github.com/rails/rails/issues/5"])
    end

    it "does not link #12 outside a git repo, and git says nothing on stderr" do
      outside = !system("git", "-C", tmp, "rev-parse", "--git-dir", out: File::NULL, err: File::NULL)
      skip "the tmp dir is inside a git repo" unless outside

      expect do
        Dir.chdir(tmp) { fire([model("#12")]) }
      end.not_to output.to_stderr_from_any_process
      expect(notices).to be_empty
    end

    it "does not link #12 when the named remote is missing" do
      repo_with({})
      Dir.chdir(tmp) { fire([model("#12")]) }
      expect(notices).to be_empty
    end

    it "asks git once per worker, across turns" do
      repo_with("origin" => "git@github.com:o/r.git")
      expect(Open3).to receive(:capture2).once.and_call_original
      Dir.chdir(tmp) do
        fire([model("#1")])
        fire([model("#2 and #3")])
      end
      expect(texts.last).to eq("sources: GitHub #2 → https://github.com/o/r/issues/2, GitHub #3 → https://github.com/o/r/issues/3")
    end

    it "remembers no remote too" do
      expect(Open3).to receive(:capture2).once.and_call_original
      Dir.chdir(tmp) do
        fire([model("#1")])
        fire([model("#2")])
      end
      expect(notices).to be_empty
    end

    it "the documented pattern links PR #12, and not PR#12, &#123;, x/#1 or a/b/c#1" do
      repo_with("origin" => "git@github.com:o/r.git")
      Dir.chdir(tmp) { fire([model("PR #12, PR#13, &#123; x/#1 a/b/c#1")]) }
      expect(texts).to eq(["sources: GitHub #12 → https://github.com/o/r/issues/12"])
    end

    it "never calls git for a JIRA-only config" do
      settings.replace("sources" => [{ "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/" },
                                     { "name" => "Wiki", "pattern" => '\bW-(\d+)', "url" => "https://w.test/{match}" }])
      repo_with("origin" => "git@github.com:o/r.git")
      expect(Open3).not_to receive(:capture2)
      Dir.chdir(tmp) { fire([model("JIRA-1 W-2 #3")]) }
      expect(texts).to eq(["sources: JIRA JIRA-1 → https://myjira.com/browse/JIRA-1, Wiki W-2 → https://w.test/2"])
    end
  end

  describe "URL escaping" do
    it "escapes a free-form capture group in the URL" do
      settings.replace("sources" => [{ "name" => "Wiki", "pattern" => "WIKI-([A-Za-z0-9 /]+)", "url" => "https://wiki/{match}" }])
      fire([model("see WIKI-a b")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: Wiki WIKI-a b → https://wiki/a%20b"])
    end
  end

  describe "the 20k scan cap" do
    it "finds a ref before the cap and misses one after it" do
      fire([model("JIRA-1 #{"x" * 20_000} JIRA-2")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-1 → https://myjira.com/browse/JIRA-1"])
    end
  end

  describe "the ReDoS guard" do
    let(:settings) do
      {
        "sources" => [
          { "name" => "Evil", "pattern" => "(a{0,10}){10}$", "url" => "https://x/{match}" },
          { "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/" }
        ]
      }
    end

    it "skips the timed-out source, still reports the others, and leaves Regexp.timeout alone" do
      before = Regexp.timeout
      warned = []
      allow(Samagotchi::Log).to receive(:warn).and_wrap_original do |original, *args, **kw|
        warned << [args, kw]
        original.call(*args, **kw)
      end
      expect { fire([model("JIRA-123 #{"a" * 20_000}")]) }.not_to raise_error
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123"])
      expect(warned.map { |args, _| args[1] }).to include("source_links_timeout")
      expect(Regexp.timeout).to eq(before)
    end

    it "discards a timed-out source's partial matches" do
      # The Evil source matches EVIL-1 early, then times out on the long run:
      # its partial hit must not be reported.
      settings.replace("sources" => [
        { "name" => "Evil", "pattern" => "EVIL-\\d+|(a{0,10}){10}$", "url" => "https://x/{match}" },
        { "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/" }
      ])
      fire([model("EVIL-1 JIRA-123 #{"a" * 20_000}")])
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123"])
    end
  end

  describe "the max cap" do
    let(:settings) do
      {
        "sources" => [{ "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/" }],
        "max" => 2
      }
    end

    it "caps the line and appends the overflow count" do
      fire([model("JIRA-1 JIRA-2 JIRA-3 JIRA-4")])
      expect(notices.map { |n| n[:text] }).to eq(
        ["sources: JIRA JIRA-1 → https://myjira.com/browse/JIRA-1, " \
         "JIRA JIRA-2 → https://myjira.com/browse/JIRA-2, … +2 more"]
      )
    end
  end

  describe "invalid entries" do
    it "skips an entry with neither prefix nor pattern, a bad regex and a non-mapping, without raising" do
      settings.replace("sources" => [
        { "name" => "Empty" },
        { "name" => "Bad", "pattern" => "(" },
        "not a mapping",
        { "name" => "JIRA", "prefix" => "JIRA", "base_url" => "https://myjira.com/browse/" }
      ])
      expect { fire([model("JIRA-123")]) }.not_to raise_error
      expect(notices.map { |n| n[:text] }).to eq(["sources: JIRA JIRA-123 → https://myjira.com/browse/JIRA-123"])
    end

    it "is a no-op when every entry is invalid" do
      settings.replace("sources" => [{ "name" => "Empty" }, { "pattern" => "(" }])
      expect { fire([model("JIRA-123")]) }.not_to raise_error
      expect(notices).to be_empty
    end
  end

  describe "the links in the answer (event[:present])" do
    # Fire :after_turn with a presenter, as the Engine does, and return the
    # display text (nil: nothing to present).
    def present(content, display: nil)
      messages = [user("q"), model(content).merge(display ? { display: display } : {})]
      answer = Samagotchi::AnswerDisplay.new(messages)
      event = { type: :after_turn, status: "completed", messages: messages }
      event[:present] = answer.presenter(event)
      registry.fire(:after_turn, event)
      answer.changed? ? answer.text : nil
    end

    def jira(ref) = "[#{ref}](https://myjira.com/browse/#{ref})"

    it "links every occurrence, the note still lists each ref once" do
      expect(present("See JIRA-1, then JIRA-2 and JIRA-1 again.")).to eq("See #{jira("JIRA-1")}, then #{jira("JIRA-2")} and #{jira("JIRA-1")} again.")
      expect(notices.map { |n| n[:text] }.first).to start_with("sources: JIRA JIRA-1 → ")
    end

    it "leaves a ref in a code span, a fenced block (``` or ~~~, closed or not) or a markdown link alone" do
      text = <<~MD
        Plain JIRA-1, `JIRA-2`, ``a `JIRA-3` b``, [JIRA-4](https://x.test/JIRA-4), [fix for JIRA-5](https://gh.test/pull/9).

        ```ruby
        JIRA-6
        ```

        ~~~
        JIRA-7
        ~~~

        After JIRA-8 and https://x.test/JIRA-9 and /browse/JIRA-10.

        ````
        JIRA-11
      MD

      expect(present(text)).to eq(text.sub("Plain JIRA-1", "Plain #{jira("JIRA-1")}").sub("After JIRA-8", "After #{jira("JIRA-8")}"))
      # The note is as before: a ref in code or in another link's label is still named.
      expect(notices.map { |n| n[:text] }.first.scan(/JIRA JIRA-\d+/)).to eq(
        ["JIRA JIRA-1", "JIRA JIRA-2", "JIRA JIRA-3", "JIRA JIRA-5", "JIRA JIRA-6", "JIRA JIRA-7", "JIRA JIRA-8", "JIRA JIRA-11"]
      )
    end

    it "links a ref after a lone backtick (no closing run: not code)" do
      expect(present("a ` JIRA-1")).to eq("a ` #{jira("JIRA-1")}")
    end

    it "leaves the text beyond the 20k scan cap as it is" do
      tail = "#{"x" * 20_000} JIRA-2 end"
      expect(present("JIRA-1 #{tail}")).to eq("#{jira("JIRA-1")} #{tail}")
    end

    it "presents nothing when there is no ref to link" do
      expect(present("nothing here, `JIRA-1` only in code")).to be_nil
    end

    it "builds on an earlier hook's display" do
      expect(present("see JIRA-1", display: "**see** JIRA-1")).to eq("**see** #{jira("JIRA-1")}")
    end

    it "keeps the link target in one piece: spaces and parentheses are percent-encoded" do
      settings.replace("sources" => [{ "name" => "Wiki", "pattern" => "\\bWIKI-(\\d+)\\b", "url" => "https://w.test/Page_(x) {match}" }])
      expect(present("see WIKI-7")).to eq("see [WIKI-7](https://w.test/Page_%28x%29%207)")
    end

    it "links one ref two sources match once, by the first configured" do
      settings["sources"] << { "name" => "Any", "pattern" => "\\b[A-Z]+-\\d+\\b", "url" => "https://any.test/{match}" }
      expect(present("JIRA-1 and ABC-2")).to eq("#{jira("JIRA-1")} and [ABC-2](https://any.test/ABC-2)")
    end

    it "with a timed-out source still links the others" do
      settings["sources"].unshift({ "name" => "Evil", "pattern" => "(a{0,10}){10}$", "url" => "https://x/{match}" })
      tail = "a" * 20_000
      expect(present("JIRA-1 #{tail}")).to eq("#{jira("JIRA-1")} #{tail}")
    end

    it "note: false drops the line and keeps the links" do
      settings["note"] = false
      expect(present("see JIRA-1")).to eq("see #{jira("JIRA-1")}")
      expect(notices).to be_empty
    end

    it "does nothing on a chi without event[:present] but the note" do
      expect { fire([model("see JIRA-1")]) }.not_to raise_error
      expect(notices.size).to eq(1)
    end
  end

  it "has a manifest whose file and hook checksums match" do
    manifest["files"].each do |file, sha|
      expect(sha).to eq("sha256:#{Digest::SHA256.hexdigest(File.binread(File.join(bundle_dir, file)))}")
    end
    manifest["hooks"].each do |file, meta|
      expect(meta["sha256"]).to eq("sha256:#{Digest::SHA256.hexdigest(File.binread(File.join(bundle_dir, "hooks", file)))}")
      expect(meta).to include("event" => "after_turn", "on_error" => "log", "priority" => 90)
    end
  end
end
