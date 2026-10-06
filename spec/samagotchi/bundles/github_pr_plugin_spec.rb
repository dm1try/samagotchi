# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "samagotchi/plugin/context"
require "samagotchi/memory_bundle/installer"
require "samagotchi/context_providers"
require "samagotchi/answer_display"
require "digest"

# The github-pr bundle as installed: its provider resolves PR URLs, and its
# plugin's init task attaches the branch's open PR to the session (not to a
# scratch session or a delegate child), quietly doing nothing without gh,
# a branch or an open PR. Its line links: a `path:line` in an answer links
# to that line of the session's PR, from a cache filled off the turn.
RSpec.describe "The github-pr bundle" do
  let(:shipped) { File.expand_path("../../../lib/samagotchi/bundles/github-pr", __dir__) }
  let(:tmpdir) { Dir.mktmpdir("github-pr-plugin") }
  let(:state_dir) { File.join(tmpdir, "state", "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:bin) { File.join(tmpdir, "bin").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
                       .tap { |s| s.save(state_dir: state_dir) }
  end
  let(:scratch) { false }
  let(:settings) { {} }
  let(:ctx) do
    host = Samagotchi::Plugin::Host.new(session_id: -> { session.id }, cwd: -> { tmpdir }, state_dir: -> { state_dir },
                                        scratch: -> { scratch })
    Samagotchi::Plugin::Context.new(bundle: "github-pr", label: "plugin.rb (bundle github-pr)", settings: settings, host: host)
  end
  let(:namespace) { Module.new.tap { |n| n.module_eval(File.read(File.join(shipped, "plugin.rb")), "plugin.rb", 1) } }
  let(:plugin) { namespace.const_get(:Plugin).new }
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }

  around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

  around do |example|
    path = ENV.fetch("PATH", nil)
    ENV["PATH"] = "#{bin}:/usr/bin:/bin"
    example.run
  ensure
    ENV["PATH"] = path
  end

  before do
    Samagotchi::MemoryBundle::Installer.new(source: shipped, name: "github-pr", scope: "system", strict: true).run
  end

  after { FileUtils.rm_rf(tmpdir) }

  def fake(name, script)
    File.write(File.join(bin, name), "#!/bin/sh\n#{script}\n")
    File.chmod(0o755, File.join(bin, name))
  end

  def on_branch_with(pr)
    fake("git", 'echo "feat/x"')
    fake("gh", "echo '#{JSON.generate(pr)}'")
  end

  it "resolves a PR URL to pr-<n>, run by its installed script" do
    resolved = Samagotchi::ContextProviders.resolve("https://github.com/acme/app/pull/42/files")

    expect(resolved).to have_attributes(bundle: "github-pr", name: "pr-42", hint: "https://github.com/acme/app/pull/42",
                                        cmd: "{ruby} {bundle_dir}/scripts/pr_context.rb https://github.com/acme/app/pull/42",
                                        every_seconds: 300)
  end

  it "attaches the branch's open PR to the session, once" do
    on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")

    expect(plugin.attach_branch_pr(ctx)).to eq("attached pr-42")
    expect(own.source("pr-42")).to have_attributes(provider: "github-pr", added_by: "plugin:github-pr",
                                                   why: "branch feat/x has open PR #42", scope: "session")
    expect(plugin.attach_branch_pr(ctx)).to eq("pr-42 is attached already")
  end

  it "doesn't attach the PR again once the user removed it (chi context rm, the web's detach)" do
    on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")
    plugin.attach_branch_pr(ctx)
    own.remove("pr-42")

    expect(plugin.attach_branch_pr(ctx)).to eq("pr-42 was removed from this session; not attached again")
    expect(own.sources).to eq([])
  end

  it "attaches nothing for a closed PR, no PR, no branch, or no gh" do
    on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "MERGED")
    expect(plugin.attach_branch_pr(ctx)).to eq("pull request #42 isn't open")

    fake("gh", "echo 'no pull requests found' >&2; exit 1")
    expect(plugin.attach_branch_pr(ctx)).to eq("no pull request for feat/x")

    FileUtils.rm(File.join(bin, "gh"))
    expect(plugin.attach_branch_pr(ctx)).to eq("no pull request for feat/x")

    fake("git", "exit 128")
    expect(plugin.attach_branch_pr(ctx)).to eq("not on a branch")
    expect(own.sources).to eq([])
  end

  context "in a scratch session" do
    let(:scratch) { true }

    it "attaches nothing" do
      on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")
      expect(plugin.attach_branch_pr(ctx)).to eq("skipped: a scratch session")
    end
  end

  context "in a delegate child" do
    let(:session) do
      parent = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir)
      parent.save(state_dir: state_dir)
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir, parent_id: parent.id,
                                      delegate: true).tap { |s| s.save(state_dir: state_dir) }
    end

    it "attaches nothing" do
      on_branch_with("number" => 42, "url" => "https://github.com/acme/app/pull/42", "state" => "OPEN")
      expect(plugin.attach_branch_pr(ctx)).to eq("skipped: a delegate child")
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
    let(:fake_chi) do
      Class.new do
        attr_reader :inits, :hooks

        def initialize
          @inits = []
          @hooks = {}
        end

        def init(_label, **_options, &block) = @inits << block

        def on(event, priority: 100, &block)
          @hooks[event] = [priority, block]
        end
      end.new
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

    def wait_for(seconds = 5)
      deadline = Time.now + seconds
      sleep 0.02 until yield || Time.now > deadline
      yield
    end

    # The after_turn hook on an answer; the display text it leaves.
    def answer(text, user: "please review #{pr_url}", context: ctx)
      messages = [{ role: "user", content: user }, { role: "model", content: text }]
      event = { type: :after_turn, status: "completed", messages: messages }
      display = Samagotchi::AnswerDisplay.new(messages)
      event[:present] = display.presenter(event)
      plugin.link_answer(event, context)
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
        plugin.register(fake_chi)
        fake_chi.hooks[:before_turn][1].call({ type: :before_turn, messages: [], prompt: "review #{pr_url}/files" }, ctx)

        expect(wait_for { gh_calls.any? { |call| call.include?("/files") } }).to be(true)
        expect(wait_for { answer("see `lib/foo.rb:28`") != "see `lib/foo.rb:28`" }).to be(true)
        expect(answer("see `lib/foo.rb:28`")).to eq("see [`lib/foo.rb:28`](#{anchor("lib/foo.rb", "R28")})")
      end

      it "takes no PR from a tool result or an answer" do
        fake_gh
        plugin.register(fake_chi)
        messages = [{ role: "user", content: "what's open?" }, { role: "tool", content: "#42 #{pr_url}" },
                    { role: "model", content: "#{pr_url} is open" }]
        fake_chi.hooks[:before_turn][1].call({ type: :before_turn, messages: messages, prompt: "next" }, ctx)

        expect(namespace::PrRef.from_messages(messages, prompt: "next")).to eq([])
        sleep 0.1
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

        it "the init task warms an attached PR inline, though it attaches nothing" do
          fake_gh
          ctx.context.attach(url: pr_url)
          plugin.register(fake_chi)

          expect(fake_chi.inits.first.call(ctx)).to eq("skipped: a delegate child")
          expect(answer("lib/foo.rb:30", user: "go")).to eq("[lib/foo.rb:30](#{anchor("lib/foo.rb", "R30")})")
        end
      end

      it "before_generation picks up a PR attached mid-turn, at most every 30 s" do
        fake_gh
        plugin.register(fake_chi)
        generation = fake_chi.hooks[:before_generation][1]
        generation.call({ type: :before_generation, iteration: 1 }, ctx)
        ctx.context.attach(url: pr_url)
        generation.call({ type: :before_generation, iteration: 2 }, ctx)
        sleep 0.1
        expect(gh_calls).to eq([])

        plugin.instance_variable_set(:@generation_checked_at, nil)
        generation.call({ type: :before_generation, iteration: 3 }, ctx)
        expect(wait_for { gh_calls.any? { |call| call.include?("/files") } }).to be(true)
      end

      it "the after_turn hook never runs gh, and links nothing before the cache has the PR" do
        fake_gh
        plugin.register(fake_chi)
        expect(fake_chi.hooks[:after_turn][0]).to eq(100)

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
          plugin.register(fake_chi)
          FileUtils.rm_f(gh_log)
          fake_chi.hooks[:before_turn][1].call({ type: :before_turn, messages: [], prompt: pr_url }, ctx)

          expect(answer("lib/foo.rb:28")).to eq("lib/foo.rb:28")
          sleep 0.1
          expect(gh_calls).to eq([])
        end
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
