# frozen_string_literal: true

require "yaml"
require "digest"
require "samagotchi/hooks"
require "samagotchi/answer_display"

# The source-links bundle (lib/samagotchi/bundles/source-links): an
# after_turn hook that announces the source refs (JIRA tickets, GitHub
# issues, …) the model's answer mentions as one line after the turn.
RSpec.describe "The source-links bundle" do
  let(:bundle_dir) { File.expand_path("../../../lib/samagotchi/bundles/source-links", __dir__) }
  let(:manifest) { YAML.safe_load(File.read(File.join(bundle_dir, "manifest.yml"))) }
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
      ask_user: ->(**) { nil },
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
