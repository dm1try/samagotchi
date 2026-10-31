# frozen_string_literal: true

require "tmpdir"
require "json"
require "samagotchi/testing/rspec"
require "samagotchi/context_providers"
require "samagotchi/answer_display"
require "samagotchi/answer_refs"
require "digest"

# The github-pr bundle as installed: its provider resolves PR URLs, and its
# plugin's init task attaches the branch's open PR to the session (not to a
# scratch session or a delegate child), quietly doing nothing without gh,
# a branch or an open PR. Its line links: a `path:line` in an answer links
# to that line of the session's PR, from a cache filled off the turn.
RSpec.describe "The github-pr bundle", :bundle do
  let(:shipped) { File.expand_path("..", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("github-pr-plugin") }
  let(:state_dir) { File.join(tmpdir, "state", "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:bin) { sandbox.bin_dir }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                       .tap { |s| s.save(state_dir: state_dir) }
  end
  let(:scratch) { false }
  # The Engine's interface ctx.frontend names (nil: a worker).
  let(:interface) { nil }
  let(:settings) { {} }
  let(:bundle) { load }
  let(:ctx) { bundle.ctx }
  let(:cards) { bundle.cards }
  let(:namespace) { bundle.namespace }
  let(:plugin) { bundle.plugin }
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }

  # The session's values the plugin's ctx reads (the kit's host).
  def host_values
    { session_id: session.id, cwd: tmpdir, state_dir: state_dir, scratch: scratch, model_name: "host:gemma4",
      frontend: interface || :worker }
  end

  # The bundle as chi loads it, with these settings (a second load is a
  # worker's restart: the same session, the same sandbox).
  def load(with_settings = settings) = shipped_bundle("github-pr", settings: with_settings, host: host_values)

  # Only the fakes and the system's own tools: no gh of the user's (the
  # sandbox puts ENV back after the example).
  before do
    ENV["PATH"] = "#{bin}:/usr/bin:/bin"
    Samagotchi::Testing::Install.run(shipped, sandbox: sandbox)
  end

  after { FileUtils.rm_rf(tmpdir) }

  def fake(name, script) = sandbox.fake_executable(name, script)

  def on_branch_with(pr)
    fake("git", 'echo "feat/x"')
    fake("gh", "printf '%s\\n' '#{JSON.generate(pr)}'")
  end

  it "resolves a PR URL to pr-<n>, run by its installed script" do
    resolved = Samagotchi::ContextProviders.resolve("https://github.com/acme/app/pull/42/files")

    expect(resolved).to have_attributes(bundle: "github-pr", name: "pr-42", hint: "https://github.com/acme/app/pull/42",
                                        cmd: "{ruby} {bundle_dir}/scripts/pr_context.rb https://github.com/acme/app/pull/42",
                                        every_seconds: 300)
  end

  def delegate_child
    parent = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
    parent.save(state_dir: state_dir)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir, parent_id: parent.id,
                                    delegate: true).tap { |s| s.save(state_dir: state_dir) }
  end

  describe "proposing the branch's PR (auto_attach: propose, the default)" do
    let(:pr_url) { "https://github.com/acme/app/pull/42" }

    before { on_branch_with("number" => 42, "url" => pr_url, "state" => "OPEN", "title" => "Make  the\nthing") }

    it "proposes it as a candidate, titled and mentioned by #N, the branch and the URL; nothing is attached" do
      expect(plugin.attach_branch_pr(ctx)).to eq("proposed pr-42")

      expect(own.sources).to eq([])
      expect(cards).to eq([])
      expect(ctx.context.candidates).to match([have_attributes(name: "pr-42", url: pr_url, title: "#42 Make the thing",
                                                               mentions: ["#42", "feat/x", pr_url],
                                                               proposed_by: "plugin:github-pr")])
      # A worker restart proposes it again: the same candidate.
      expect(load.plugin.attach_branch_pr(ctx)).to eq("proposed pr-42")
      expect(ctx.context.candidates.size).to eq(1)
    end

    it "attaches it at once when an owner prompt already in the session mentions it (the init task ran late)" do
      bundle.set(messages: [{ role: "user", turn_id: "t1", content: "Please review #42" }])

      expect(plugin.attach_branch_pr(ctx)).to eq("proposed pr-42")
      expect(own.source("pr-42")).to have_attributes(provider: "github-pr", why: "you mentioned #42", title: "#42 Make the thing",
                                                     hint: pr_url, added_by: "plugin:github-pr")
      expect(plugin.attach_branch_pr(ctx)).to eq("pr-42 is attached already")
    end

    it "attaches nothing a participant's line or a pasted log mentions" do
      bundle.set(messages: [{ role: "user", turn_id: "t1", content: "#42", author: "p:abc" },
                            { role: "user", turn_id: "t2", content: "why?\n```\nfeat/x: Merged #42\n```" }])

      plugin.attach_branch_pr(ctx)
      expect(own.sources).to eq([])
    end

    it "doesn't propose a PR the user removed from the session" do
      own.decline("pr-42", pr_url)
      expect(plugin.attach_branch_pr(ctx)).to eq("pr-42 was removed from this session; not proposed")
      expect(ctx.context.candidates).to eq([])
    end

    it "proposes nothing for a closed PR, no PR, no branch, or no gh" do
      on_branch_with("number" => 42, "url" => pr_url, "state" => "MERGED")
      expect(plugin.attach_branch_pr(ctx)).to eq("pull request #42 isn't open")

      fake("gh", "echo 'no pull requests found' >&2; exit 1")
      expect(plugin.attach_branch_pr(ctx)).to eq("no pull request for feat/x")

      FileUtils.rm(File.join(bin, "gh"))
      expect(plugin.attach_branch_pr(ctx)).to eq("no pull request for feat/x")

      fake("git", "exit 128")
      expect(plugin.attach_branch_pr(ctx)).to eq("not on a branch")
      expect(ctx.context.candidates).to eq([])
    end

    context "in a scratch session" do
      let(:scratch) { true }

      it "proposes nothing" do
        expect(plugin.attach_branch_pr(ctx)).to eq("skipped: a scratch session")
      end
    end

    context "in a delegate child" do
      let(:session) { delegate_child }

      it "proposes it too (nothing attaches without a mention)" do
        expect(plugin.attach_branch_pr(ctx)).to eq("proposed pr-42")
        expect(own.sources).to eq([])
      end
    end

    context "in a review session" do
      let(:session) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                           .tap { |s| s.review = { "subjects" => ["a.md"] } }.tap { |s| s.save(state_dir: state_dir) }
      end

      it "proposes nothing" do
        expect(plugin.attach_branch_pr(ctx)).to eq("skipped: a review session")
        expect(ctx.context.candidates).to eq([])
      end
    end

    describe "looking again at a turn's start" do
      it "looks again on a thread of its own once the last look is over 5 minutes old, never on the turn's" do
        expect(bundle.run_inits).to eq(["proposed pr-42"])

        on_branch_with("number" => 43, "url" => "https://github.com/acme/app/pull/43", "state" => "OPEN", "title" => "Next")
        expect(plugin.relook(ctx)).to be_nil # just looked

        plugin.instance_variable_set(:@looked_at, plugin.send(:now) - namespace::Plugin::RELOOK_SECONDS - 1)
        thread = plugin.relook(ctx)
        expect(thread).to be_a(Thread)
        expect(thread).not_to eq(Thread.current)
        join!(thread, "the second look")
        expect(ctx.context.candidates.map(&:name)).to eq(%w[pr-42 pr-43])
        expect(plugin.relook(ctx)).to be_nil
      end

      it "doesn't look again in attach mode" do
        attach = load("auto_attach" => "attach")
        attach.plugin.instance_variable_set(:@looked_at, attach.plugin.send(:now) - 1000)
        expect(attach.plugin.relook(attach.ctx)).to be_nil
      end
    end
  end

  describe "auto_attach: attach (the old default)" do
    let(:settings) { { "auto_attach" => "attach" } }

    it "attaches the branch's open PR to the session, once" do
      on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")

      expect(plugin.attach_branch_pr(ctx)).to eq("attached pr-42")
      expect(own.source("pr-42")).to have_attributes(provider: "github-pr", added_by: "plugin:github-pr",
                                                     why: "branch feat/x has open PR #42", scope: "session")
      expect(plugin.attach_branch_pr(ctx)).to eq("pr-42 is attached already")
      expect(ctx.context.candidates).to eq([])
      expect(cards).to eq([])
    end

    it "doesn't attach the PR again once the user removed it (chi context rm, the web's detach)" do
      on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")
      plugin.attach_branch_pr(ctx)
      own.remove("pr-42")

      expect(plugin.attach_branch_pr(ctx)).to eq("pr-42 was removed from this session; not attached again")
      expect(own.sources).to eq([])
    end

    context "in a delegate child" do
      let(:session) { delegate_child }

      it "attaches nothing" do
        on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")
        expect(plugin.attach_branch_pr(ctx)).to eq("skipped: a delegate child")
      end
    end
  end

  describe "auto_attach" do
    # A ctx with other settings for the same session (another load's).
    def ctx_with(new_settings) = load(new_settings).ctx

    it "reads the mode: propose by default, YAML's true/false, any case" do
      expect(plugin.auto_attach_mode(ctx_with({}))).to eq(:propose)
      expect(plugin.auto_attach_mode(ctx_with("auto_attach" => " Propose "))).to eq(:propose)
      expect(plugin.auto_attach_mode(ctx_with("auto_attach" => true))).to eq(:attach)
      expect(plugin.auto_attach_mode(ctx_with("auto_attach" => "ATTACH"))).to eq(:attach)
      expect(plugin.auto_attach_mode(ctx_with("auto_attach" => false))).to eq(:off)
      expect(plugin.auto_attach_mode(ctx_with("auto_attach" => "OFF"))).to eq(:off)
    end

    it "reads offer (the old card) as propose, warned once" do
      expect(Samagotchi::Log).to receive(:warn).with(:plugins, "pr_auto_attach_offer_is_propose", bundle: "github-pr",
                                                                                                  value: " Offer ").once
      expect(plugin.auto_attach_mode(ctx_with("auto_attach" => " Offer "))).to eq(:propose)
      expect(plugin.auto_attach_mode(ctx_with("auto_attach" => "offer"))).to eq(:propose)
    end

    it "reads an unknown value as propose, never attach (warned once)" do
      expect(Samagotchi::Log).to receive(:warn).with(:plugins, "pr_auto_attach_unknown", bundle: "github-pr", value: "ask").once
      expect(plugin.auto_attach_mode(ctx_with("auto_attach" => "ask"))).to eq(:propose)
      expect(plugin.auto_attach_mode(ctx_with("auto_attach" => "ask"))).to eq(:propose)
    end

    it "has no /pr-attach or /pr-decline any more" do
      expect(bundle.bundle_commands.map(&:name)).not_to include("/pr-attach", "/pr-decline")
    end

    context "when off" do
      let(:settings) { { "auto_attach" => "off" } }

      it "attaches and proposes nothing, running neither git nor gh" do
        fake("gh", "touch #{tmpdir}/gh-ran; exit 1")
        fake("git", "touch #{tmpdir}/git-ran; exit 1")

        expect(plugin.attach_branch_pr(ctx)).to eq("auto_attach: off")
        expect(own.sources).to eq([])
        expect(ctx.context.candidates).to eq([])
        expect(File.exist?(File.join(tmpdir, "gh-ran")) || File.exist?(File.join(tmpdir, "git-ran"))).to be(false)
      end
    end
  end

  describe "line links" do
    let(:pr_url) { "https://github.com/acme/app/pull/42" }
    let(:gh_log) { File.join(tmpdir, "gh.log") }
    let(:pr) { namespace::PrRef.parse(pr_url) }
    # The PR files API as `gh api --paginate … --jq '.[] | {…}'` prints it.
    let(:files) do
      [{ "filename" => "lib/foo.rb", "status" => "modified", "previous_filename" => nil,
         "patch" => "@@ -20,6 +20,12 @@ class Foo\n   a\n+  b\n@@ -80,3 +86,4 @@ def bar\n x\n+y" },
       { "filename" => "lib/samagotchi/source_links.rb", "status" => "modified", "previous_filename" => nil,
         "patch" => "@@ -1,3 +1,4 @@\n+# frozen" },
       { "filename" => "lib/old.rb", "status" => "removed", "previous_filename" => nil, "patch" => "@@ -1,10 +0,0 @@\n-x" },
       { "filename" => "lib/new_name.rb", "status" => "renamed", "previous_filename" => "lib/old_name.rb",
         "patch" => "@@ -5,3 +5,4 @@\n+z" },
       { "filename" => "assets/logo.png", "status" => "added", "previous_filename" => nil, "patch" => nil }]
    end

    def anchor(path, side_lines) = "#{pr_url}/files#diff-#{Digest::SHA256.hexdigest(path)}#{side_lines}"

    def fake_gh(head: "head1", list: files)
      File.write(File.join(tmpdir, "files.jsonl"), list.map { |file| JSON.generate(file) }.join("\n") + "\n")
      fake("gh", <<~SH)
        echo "$*" >> #{gh_log}
        case "$*" in
          *"pulls/42/files"*) cat #{File.join(tmpdir, "files.jsonl")} ;;
          "api repos/acme/app/pulls/42 "*) echo "#{head} base1" ;;
          *) exit 1 ;;
        esac
      SH
    end

    def gh_calls = File.exist?(gh_log) ? File.readlines(gh_log, chomp: true) : []

    # The block's value, once the refreshes its hooks kicked have ended
    # (#kick runs #refresh on a raw thread): what they fetched is in, and
    # nothing still runs when the example checks that nothing was fetched.
    def settled
      kicked = []
      allow(Thread).to receive(:new).and_wrap_original do |original, *args, &body|
        original.call(*args, &body).tap { |thread| kicked << thread if Thread.current[:github_pr_kick] }
      end
      allow(plugin).to receive(:kick).and_wrap_original do |original, *args|
        Thread.current[:github_pr_kick] = true
        original.call(*args)
      ensure
        Thread.current[:github_pr_kick] = nil
      end
      yield.tap { kicked.each { |thread| join!(thread, "the PR refresh") } }
    end

    # The after_turn hook on an answer, fired with the fire site's present:
    # and refs: helpers (they read the event only for its hook label); the
    # display text it leaves (the refs it added in @refs).
    def answer(text, user: "please review #{pr_url}")
      messages = [{ role: "user", content: user }, { role: "model", content: text }]
      site = { hook: "plugin.rb (bundle github-pr)" }
      display = Samagotchi::AnswerDisplay.new(messages)
      refs = Samagotchi::AnswerRefs.new(messages, cwd: tmpdir)
      bundle.fire(:after_turn, status: "completed", messages: messages, present: display.presenter(site), refs: refs.adder(site))
      @refs = refs.to_a
      display.text
    end

    def linker(*prs) = namespace::LineLinker.new(prs)

    def data(list = files, head: "head1")
      namespace::PrData.new(head_sha: head, base_sha: "base1", files: list.filter_map { |f| namespace::PrFile.from_api(f) },
                            fetched_at: 0)
    end

    context "filling the cache (never from after_turn)" do
      it "before_turn warms the PRs the turn's prompt names (a one-turn child's task)" do
        fake_gh
        settled { bundle.fire(:before_turn, messages: [], prompt: "review #{pr_url}/files") }

        expect(gh_calls).to include(a_string_including("/files"))
        expect(answer("see `lib/foo.rb:28`")).to eq("see [`lib/foo.rb:28`](#{anchor("lib/foo.rb", "R28")})")
      end

      it "takes no PR from a tool result or an answer" do
        fake_gh
        messages = [{ role: "user", content: "what's open?" }, { role: "tool", content: "#42 #{pr_url}" },
                    { role: "model", content: "#{pr_url} is open" }]
        settled { bundle.fire(:before_turn, messages: messages, prompt: "next") }

        expect(namespace::PrRef.from_messages(messages, prompt: "next")).to eq([])
        expect(gh_calls).to eq([])
      end

      it "takes the newest three PRs the user's messages name" do
        messages = (1..4).map { |n| { "role" => "user", "content" => "https://github.com/acme/app/pull/#{n}" } }

        expect(namespace::PrRef.from_messages(messages, prompt: "https://github.com/o/r/pull/9#discussion").map(&:number))
          .to eq([9, 4, 3])
      end

      context "in a delegate child" do
        let(:session) do
          parent = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
          parent.save(state_dir: state_dir)
          Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir,
                                          parent_id: parent.id, delegate: true).tap { |s| s.save(state_dir: state_dir) }
        end

        it "the init task warms an attached PR inline" do
          fake_gh
          ctx.context.attach(url: pr_url)

          expect(bundle.run_inits).to eq(["not on a branch"])
          expect(answer("lib/foo.rb:30", user: "go")).to eq("[lib/foo.rb:30](#{anchor("lib/foo.rb", "R30")})")
        end
      end

      it "before_generation picks up a PR attached mid-turn, at most every 30 s" do
        fake_gh
        settled do
          bundle.fire(:before_generation, iteration: 1)
          ctx.context.attach(url: pr_url)
          bundle.fire(:before_generation, iteration: 2)
        end
        expect(gh_calls).to eq([])

        plugin.instance_variable_set(:@generation_checked_at, nil)
        settled { bundle.fire(:before_generation, iteration: 3) }
        expect(gh_calls).to include(a_string_including("/files"))
      end

      it "the after_turn hook never runs gh, and links nothing before the cache has the PR" do
        fake_gh
        expect(bundle.hook_names(:after_turn)).to eq([["github-pr", "plugin.rb", 100]])

        expect(answer("see lib/foo.rb:28")).to eq("see lib/foo.rb:28")
        expect(gh_calls).to eq([])

        plugin.refresh(ctx, [pr])
        FileUtils.rm(gh_log)
        expect(answer("see lib/foo.rb:28")).to eq("see [lib/foo.rb:28](#{anchor("lib/foo.rb", "R28")})")
        expect(gh_calls).to eq([])
      end

      it "fetches the files again only when the head moved" do
        clock = [0.0]
        allow(plugin).to receive(:now) { clock[0] }
        fake_gh
        plugin.refresh(ctx, [pr])
        plugin.refresh(ctx, [pr])
        clock[0] = 61.0
        plugin.refresh(ctx, [pr])
        expect(gh_calls.count { |call| call.include?("/files") }).to eq(1)
        expect(gh_calls.size).to eq(3)

        fake_gh(head: "head2")
        clock[0] = 122.0
        plugin.refresh(ctx, [pr])
        expect(gh_calls.count { |call| call.include?("/files") }).to eq(2)
        expect(answer("lib/foo.rb:100")).to eq("[lib/foo.rb:100](https://github.com/acme/app/blob/head2/lib/foo.rb#L100)")
      end

      it "without gh, links nothing and logs it once" do
        allow(Samagotchi::Log).to receive(:info).and_call_original
        plugin.refresh(ctx, [pr])
        allow(plugin).to receive(:now).and_return(1e9)
        plugin.refresh(ctx, [pr])

        expect(answer("lib/foo.rb:28")).to eq("lib/foo.rb:28")
        expect(Samagotchi::Log).to have_received(:info).with(:plugins, "pr_lines_not_fetched", hash_including(bundle: "github-pr")).once
      end
    end

    context "linking the answer" do
      before do
        fake_gh
        plugin.refresh(ctx, [pr])
      end

      it "links refs in inline code and in text, ranges too; fenced code, links and URLs stay" do
        text = <<~MD
          `lib/foo.rb:28` and lib/foo.rb:28-30, `./lib/foo.rb:87:4`.
          ```
          lib/foo.rb:28
          ```
          [lib/foo.rb:28](https://x.test/a) https://x.test/lib/foo.rb:28 `see lib/foo.rb:28`
        MD

        expect(answer(text)).to eq(<<~MD)
          [`lib/foo.rb:28`](#{anchor("lib/foo.rb", "R28")}) and [lib/foo.rb:28-30](#{anchor("lib/foo.rb", "R28-R30")}), [`./lib/foo.rb:87:4`](#{anchor("lib/foo.rb", "R87")}).
          ```
          lib/foo.rb:28
          ```
          [lib/foo.rb:28](https://x.test/a) https://x.test/lib/foo.rb:28 `see lib/foo.rb:28`
        MD
      end

      it "resolves a bare name or an absolute worktree path by a unique suffix" do
        expect(answer("source_links.rb:2 /Users/me/samagotchi-pr42/lib/foo.rb:21"))
          .to eq("[source_links.rb:2](#{anchor("lib/samagotchi/source_links.rb", "R2")}) " \
                 "[/Users/me/samagotchi-pr42/lib/foo.rb:21](#{anchor("lib/foo.rb", "R21")})")
      end

      # A relative path that only ends with a PR path is another file (a
      # vendored copy), not the PR's.
      it "links no relative path that merely ends with a PR path" do
        text = "vendor/lib/foo.rb:21 and vendor/bundle/lib/samagotchi/source_links.rb:2"
        expect(answer(text)).to eq(text)
      end

      it "links an absolute path into a worktree here, not into a vendored copy inside it" do
        repo = File.join(tmpdir, "repo")
        FileUtils.mkdir_p([File.join(repo, ".git"), File.join(repo, "vendor/lib"), File.join(repo, "lib")])
        vendored = "#{repo}/vendor/lib/foo.rb:21"
        expect(answer(vendored)).to eq(vendored)
        expect(answer("#{repo}/lib/foo.rb:21")).to eq("[#{repo}/lib/foo.rb:21](#{anchor("lib/foo.rb", "R21")})")
      end

      it "links a path up from a subdir of the worktree to the PR's file" do
        expect(answer("../lib/foo.rb:21"))
          .to eq("[../lib/foo.rb:21](#{anchor("lib/foo.rb", "R21")})")
      end

      it "links a line outside every hunk to the file at the PR's head" do
        expect(answer("lib/foo.rb:100 and lib/foo.rb:30-40"))
          .to eq("[lib/foo.rb:100](https://github.com/acme/app/blob/head1/lib/foo.rb#L100) and " \
                 "[lib/foo.rb:30-40](https://github.com/acme/app/blob/head1/lib/foo.rb#L30-L40)")
      end

      it "a removed file: its old side, else the file at the PR's base; a renamed file by either name" do
        expect(answer("lib/old.rb:3 lib/old.rb:12 lib/old_name.rb:6 lib/new_name.rb:6 assets/logo.png:1"))
          .to eq("[lib/old.rb:3](#{anchor("lib/old.rb", "L3")}) " \
                 "[lib/old.rb:12](https://github.com/acme/app/blob/base1/lib/old.rb#L12) " \
                 "[lib/old_name.rb:6](#{anchor("lib/new_name.rb", "R6")}) [lib/new_name.rb:6](#{anchor("lib/new_name.rb", "R6")}) " \
                 "[assets/logo.png:1](https://github.com/acme/app/blob/head1/assets/logo.png#L1)")
      end

      # The checkout's git remotes (`git remote -v`), as +remotes+ lines.
      def checkout_with(*remotes)
        repo = File.join(tmpdir, "repo")
        FileUtils.mkdir_p(File.join(repo, ".git"))
        allow(ctx).to receive(:repo_root).and_return(repo)
        listing = remotes.map { |url| "origin\t#{url} (fetch)" }.join("\n")
        File.write(File.join(tmpdir, "remotes.txt"), "#{listing}\n")
        fake("git", <<~SH)
          case "$*" in
            "remote -v") cat #{File.join(tmpdir, "remotes.txt")} ;;
            *) exit 1 ;;
          esac
        SH
        repo
      end

      it "adds each linked ref as a file ref: the checkout's file, a PR diff or File at head/base action" do
        # Kept under the session folder's real path (AnswerRef, as RowRefs).
        repo = File.realpath(checkout_with("git@github.com:Acme/app.git"))
        text = "`lib/foo.rb:28` and lib/foo.rb:30-40, lib/old.rb:12"

        expect(answer(text)).to eq("[`lib/foo.rb:28`](#{anchor("lib/foo.rb", "R28")}) and " \
                                   "[lib/foo.rb:30-40](https://github.com/acme/app/blob/head1/lib/foo.rb#L30-L40), " \
                                   "[lib/old.rb:12](https://github.com/acme/app/blob/base1/lib/old.rb#L12)")
        expect(@refs).to eq(
          [{ match: "lib/foo.rb:28", kind: "file", target: { path: "#{repo}/lib/foo.rb", line: 28 },
             actions: [{ id: "pr_diff", label: "PR diff", url: anchor("lib/foo.rb", "R28") }] },
           { match: "lib/foo.rb:30-40", kind: "file", target: { path: "#{repo}/lib/foo.rb", line: 30, end_line: 40 },
             actions: [{ id: "blob", label: "File at head", url: "https://github.com/acme/app/blob/head1/lib/foo.rb#L30-L40" }] },
           { match: "lib/old.rb:12", kind: "file", target: { path: "#{repo}/lib/old.rb", line: 12 },
             actions: [{ id: "blob", label: "File at base", url: "https://github.com/acme/app/blob/base1/lib/old.rb#L12" }] }]
        )
      end

      it "adds file refs for a PR of a repo any remote names (https, ssh: a fork's upstream too)" do
        %w[https://github.com/acme/app ssh://git@github.com/acme/app.git].each do |url|
          plugin.instance_variable_set(:@checkout_repos, {})
          checkout_with("git@github.com:me/fork.git", url)
          answer("lib/foo.rb:28")
          expect(@refs.map { |ref| ref[:target][:line] }).to eq([28]), url
        end
      end

      it "adds no file ref for another project's PR, or outside a repo: the link stays" do
        checkout_with("git@github.com:acme/other.git", "https://gitlab.com/acme/app.git")
        expect(answer("lib/foo.rb:28")).to eq("[lib/foo.rb:28](#{anchor("lib/foo.rb", "R28")})")
        expect(@refs).to eq([])

        allow(ctx).to receive(:repo_root).and_raise(StandardError, "not a repo")
        expect(answer("lib/foo.rb:28")).to eq("[lib/foo.rb:28](#{anchor("lib/foo.rb", "R28")})")
        expect(@refs).to eq([])
      end

      it "adds no ref for what it doesn't link" do
        answer("lib/other.rb:3 [lib/foo.rb:28](https://x.test/a) `see lib/foo.rb:28`")
        expect(@refs).to eq([])
      end

      it "links nothing that isn't a PR file (or a path at all)" do
        text = "lib/other.rb:3, example.com:443, at 10:30, bar.rb:28"
        expect(answer(text)).to eq(text)
      end

      it "leaves alone a ref source-links (priority 90) already linked" do
        text = "[`lib/foo.rb:28`](https://elsewhere.test/x)"
        expect(answer(text)).to eq(text)
      end

      it "links nothing without a PR: none attached, none in the user's messages" do
        expect(answer("lib/foo.rb:28", user: "look at #{pr_url.sub("42", "43")}")).to eq("lib/foo.rb:28")
        expect(answer("lib/foo.rb:28", user: "hi")).to eq("lib/foo.rb:28")
      end

      context "with line_links: false" do
        let(:settings) { { "line_links" => false } }

        it "links nothing and fetches nothing" do
          FileUtils.rm_f(gh_log)
          settled { bundle.fire(:before_turn, messages: [], prompt: pr_url) }

          expect(answer("lib/foo.rb:28")).to eq("lib/foo.rb:28")
          expect(gh_calls).to eq([])
        end
      end
    end

    # The line-link prefetch (gh api) runs only where a page shows the
    # links while the session runs: a worker. The PR lookup (gh pr view)
    # and its attach run everywhere.
    describe "by frontend" do
      def fake_gh_with_view
        fake_gh
        fake("git", 'echo "feat/x"')
        script = File.read(File.join(bin, "gh.sh"))
        view = JSON.generate("number" => 42, "url" => pr_url, "state" => "OPEN", "title" => "T")
        fake("gh", script.sub("case \"$*\" in\n", "case \"$*\" in\n  \"pr view\"*) echo '#{view}' ;;\n"))
      end

      # The init task, a turn naming the PR and a generation check.
      def run_hooks
        settled do
          summary = bundle.run_inits.first
          bundle.fire(:before_turn, messages: [], prompt: "review #{pr_url}")
          bundle.fire(:before_generation, iteration: 1)
          summary
        end
      end

      def api_calls = gh_calls.select { |call| call.start_with?("api ") }

      it "reads line_links: a worker's by default, YAML's true/false, always in any case, an unknown value as a worker's (warned once)" do
        mode = ->(value) { plugin.send(:line_links_mode, ctx_with(value.nil? ? {} : { "line_links" => value })) }
        expect([nil, true, false, "Always", " ALWAYS "].map(&mode)).to eq(%i[worker worker off always always])

        expect(Samagotchi::Log).to receive(:warn).with(:plugins, "pr_line_links_unknown", bundle: "github-pr", value: "false").once
        expect(mode.call("false")).to eq(:worker)
        expect(mode.call("never")).to eq(:worker)
      end

      # A ctx with other settings for the same session (another load's).
      def ctx_with(new_settings) = load(new_settings).ctx

      %i[repl non_interactive].each do |name|
        context "in #{name == :repl ? "the REPL" : "-p --non-interactive"}" do
          let(:interface) { name }

          it "proposes the branch's PR (gh pr view) but fetches no line-link data (no gh api)" do
            fake_gh_with_view
            expect(run_hooks).to eq("proposed pr-42")
            expect(gh_calls).to include(a_string_starting_with("pr view"))
            expect(api_calls).to eq([])
            expect(answer("see lib/foo.rb:28")).to eq("see lib/foo.rb:28")
          end

          context "with line_links: always" do
            let(:settings) { { "line_links" => "always" } }

            it "fetches and links as a worker does" do
              fake_gh_with_view
              run_hooks
              expect(api_calls).to include(a_string_including("/files"))
              expect(answer("see lib/foo.rb:28")).to eq("see [lib/foo.rb:28](#{anchor("lib/foo.rb", "R28")})")
            end
          end
        end
      end

      context "in a worker" do
        let(:interface) { :worker }

        it "proposes the PR and fetches the line-link data of the PR the prompt names" do
          fake_gh_with_view
          expect(run_hooks).to eq("proposed pr-42")
          expect(api_calls).to include(a_string_including("pulls/42/files"))
        end
      end

      context "in a scratch session" do
        let(:scratch) { true }
        let(:interface) { :worker }
        let(:settings) { { "line_links" => "always" } }

        it "fetches nothing, even with line_links: always" do
          fake_gh_with_view
          ctx.context.attach(url: pr_url)
          FileUtils.rm_f(gh_log)
          expect(run_hooks).to eq("skipped: a scratch session")
          expect(gh_calls).to eq([])
        end
      end

      it "on a chi without ctx.frontend, prefetches as before (a worker)" do
        allow(ctx).to receive(:respond_to?).and_call_original
        allow(ctx).to receive(:respond_to?).with(:frontend).and_return(false)
        fake_gh_with_view
        run_hooks
        expect(api_calls).to include(a_string_including("pulls/42/files"))
      end
    end

    it "with several PRs, links a path only one of them has" do
      other = namespace::PrRef.parse("https://github.com/acme/lib/pull/7")
      other_files = [{ "filename" => "lib/foo.rb", "status" => "modified", "patch" => "@@ -1,1 +1,2 @@" },
                     { "filename" => "README.md", "status" => "modified", "patch" => "@@ -1,1 +1,2 @@" }]
      both = linker([pr, data], [other, data(other_files)])

      expect(both.link("lib/foo.rb:28 README.md:2"))
        .to eq("lib/foo.rb:28 [README.md:2](https://github.com/acme/lib/pull/7/files#diff-#{Digest::SHA256.hexdigest("README.md")}R2)")
    end
  end
end
