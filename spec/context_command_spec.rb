# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/context_command"

RSpec.describe Samagotchi::ContextCommand do
  let(:tmpdir) { Dir.mktmpdir("context-command") }
  let(:state_dir) { File.join(tmpdir, "state", "samagotchi", "sessions") }
  let(:repo) { File.join(tmpdir, "app").tap { |dir| FileUtils.mkdir_p(File.join(dir, ".git")) } }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:env) { {} }

  after { FileUtils.rm_rf(tmpdir) }

  def make(cwd: repo)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd).tap do |s|
      s.project_root = Samagotchi::ProjectScope.root_for(cwd) if s.respond_to?(:project_root=)
      s.save(state_dir: state_dir)
    end
  end

  def run(*argv, stdin: StringIO.new(""), cwd: repo)
    described_class.new(argv, stdin: stdin, stdout: out, stderr: err, state_dir: state_dir, env: env, cwd: cwd).run
  end

  def own(session) = Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir)
  def project = Samagotchi::ContextSources.project_location_for(Samagotchi::MemoryPaths.project_root(repo), state_dir: state_dir)

  def reset_out
    out.truncate(0)
    out.rewind
  end

  it "prints its usage for no arguments and --help, and refuses an unknown subcommand" do
    expect(run).to eq(0)
    expect(out.string).to include("chi context <add|push|ls|show|refresh|rm|mute|unmute>")
    expect(run("bogus")).to eq(2)
    expect(err.string).to include("unknown subcommand bogus")
  end

  describe "add" do
    it "stores a command source for each session given, with why, hint and every" do
      a = make
      b = make

      code = run("add", "pr-1", "--cmd", "gh pr view 1", "--every", "60", "--why", "the PR", "--hint", "https://x/1",
                 a.id[0, 8], b.id)

      expect(code).to eq(0), err.string
      expect(own(a).source("pr-1")).to have_attributes(cmd: "gh pr view 1", every_seconds: 60, why: "the PR",
                                                       hint: "https://x/1", scope: "session", added_by: "cli")
      expect(own(b).source("pr-1")).not_to be_nil
      expect(out.string.lines).to eq(["#{a.id[0, 8]}  attached pr-1\n", "#{b.id[0, 8]}  attached pr-1\n"])
    end

    it "stores a push source for the project with --project" do
      expect(run("add", "notes", "--push", "--project")).to eq(0), err.string
      expect(project.source("notes")).to have_attributes(cmd: nil, scope: "project")
      expect(out.string).to eq("project app  attached notes\n")
    end

    it "refuses --project outside a git repository" do
      plain = File.join(tmpdir, "plain").tap { |d| FileUtils.mkdir_p(d) }
      expect(run("add", "notes", "--push", "--project", cwd: plain)).to eq(1)
      expect(err.string).to include("--project needs a git repository")
    end

    it "defaults to the session it runs in (SAMAGOTCHI_PARENT_SESSION) and marks it the agent's" do
      a = make
      env["SAMAGOTCHI_PARENT_SESSION"] = a.id

      expect(run("add", "notes", "--push")).to eq(0), err.string
      expect(own(a).source("notes").added_by).to eq("agent")
    end

    it "has no default target outside a session ('chi' is a run with no session)" do
      env["SAMAGOTCHI_PARENT_SESSION"] = "chi"

      expect(run("add", "notes", "--push")).to eq(1)
      expect(err.string).to include("give session ids (or unique prefixes), or --project")
    end

    it "takes one of --cmd and --push, --every only for --cmd and at least 30" do
      a = make
      expect(run("add", "x", a.id)).to eq(2)
      expect(run("add", "x", "--cmd", "date", "--push", a.id)).to eq(2)
      expect(run("add", "x", "--push", "--every", "60", a.id)).to eq(2)
      expect(run("add", "x", "--cmd", "date", "--every", "10", a.id)).to eq(1)
      expect(err.string).to include("the least is 30 seconds")
      expect(own(a).sources).to be_empty
    end

    it "refuses a bad name, a name already attached, an unknown session, and a URL no bundle resolves" do
      a = make
      expect(run("add", "Bad/Name", "--push", a.id)).to eq(1)
      expect(run("add", "x", "--push", a.id)).to eq(0)
      expect(run("add", "x", "--push", a.id)).to eq(1)
      expect(err.string).to include("x is already attached here")
      expect(run("add", "y", "--push", "ffffffff")).to eq(1)
      expect(err.string).to include("no session ffffffff")
      expect(run("add", "https://github.com/x/y/pull/1", a.id)).to eq(1)
      expect(err.string).to include("no installed bundle resolves https://github.com/x/y/pull/1 " \
                                    "(chi bundle install github-pr for GitHub PRs)")
    end

    describe "a URL" do
      around { |example| with_config_home(File.join(tmpdir, "config")) { example.run } }

      before do
        dir = File.join(Samagotchi::MemoryPaths.system_dir, ".bundles", "prs")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "manifest.json"), JSON.generate(
          "name" => "prs", "version" => "1.0.0", "files" => {},
          "context_providers" => [{ "match" => '\Ahttps://example\.com/pull/(\d+)', "name" => 'pr-\1',
                                    "cmd" => "ruby {bundle_dir}/scripts/pr.rb {url}", "why" => "a PR",
                                    "every_seconds" => 120 }]
        ))
      end

      it "attaches the source a bundle's provider makes of it; --why replaces the provider's" do
        a = make
        expect(run("add", "https://example.com/pull/7", a.id)).to eq(0)
        expect(out.string).to include("#{a.id[0, 8]}  attached pr-7")
        expect(own(a).source("pr-7")).to have_attributes(
          cmd: "ruby {bundle_dir}/scripts/pr.rb https://example.com/pull/7", provider: "prs", why: "a PR",
          hint: "https://example.com/pull/7", every_seconds: 120, added_by: "cli", scope: "session"
        )

        b = make
        expect(run("add", "https://example.com/pull/8", "--why", "review it", b.id)).to eq(0)
        expect(own(b).source("pr-8").why).to eq("review it")
      end

      it "takes no --cmd, --push or --every: the provider gives them" do
        a = make
        expect(run("add", "https://example.com/pull/7", "--cmd", "x", a.id)).to eq(2)
        expect(err.string).to include("a URL's command comes from its provider: give no --cmd, --push or --every")
      end
    end
  end

  describe "push" do
    it "writes new text from stdin, says when it's unchanged, and parses the JSON contract" do
      a = make
      run("add", "notes", "--push", a.id)
      reset_out

      expect(run("push", "notes", a.id, stdin: StringIO.new("hello\n"))).to eq(0), err.string
      expect(run("push", "notes", a.id, stdin: StringIO.new("hello\n"))).to eq(0)
      expect(run("push", "notes", "-m", JSON.generate(text: "bye", summary: "said bye", wake: true), a.id)).to eq(0)

      lines = out.string.lines
      expect(lines[0]).to include("notes: new text (")
      expect(lines[1]).to include("notes: unchanged (")
      expect(lines[2]).to include("notes: new text (")
      expect(own(a).snapshot("notes")).to have_attributes(text: "bye", summary: "said bye", wake: true, serial: 2)
    end

    it "pushes into the project's source a session sees" do
      a = make
      run("add", "notes", "--push", "--project")

      expect(run("push", "notes", "-m", "shared", a.id)).to eq(0), err.string
      expect(project.snapshot("notes").text).to eq("shared")
    end

    it "refuses an unknown source and empty text" do
      a = make
      expect(run("push", "nope", "-m", "x", a.id)).to eq(1)
      expect(err.string).to include("no source nope for #{a.id[0, 8]}")
      run("add", "notes", "--push", a.id)
      expect(run("push", "notes", "-m", "  ", a.id)).to eq(1)
      expect(err.string).to include("the output is empty")
    end
  end

  describe "ls and show" do
    it "lists a session's sources with the project's, shadowed and muted ones marked" do
      a = make
      run("add", "ci", "--cmd", "./ci.sh", "--why", "build status", "--project")
      run("add", "pr-1", "--push", "--project")
      run("add", "pr-1", "--push", "--why", "mine", a.id)
      run("push", "pr-1", "-m", "text", a.id)
      run("mute", "ci", a.id)
      reset_out

      expect(run("ls", a.id)).to eq(0), err.string
      expect(out.string.lines.map(&:split)).to eq([
        %w[pr-1 session push 0s ago ok mine],
        %w[ci project cmd every default - muted build status],
        %w[pr-1 project push - shadowed]
      ])
    end

    it "gives JSON rows with --format json, unread until context_read reads the revision" do
      a = make
      run("add", "notes", "--push", a.id)
      run("push", "notes", "-m", "text", a.id)
      reset_out

      run("ls", a.id, "--format", "json")
      row = JSON.parse(out.string).first
      expect(row).to include("name" => "notes", "scope" => "session", "unread" => true, "muted" => false,
                             "revision" => Samagotchi::ContextSources.revision_of("text"))
    end

    it "says when there is nothing attached" do
      a = make
      expect(run("ls", a.id)).to eq(0)
      expect(out.string).to eq("no attached context\n")
    end

    it "shows the text, or the source and snapshot as JSON, and fails for no text yet" do
      a = make
      run("add", "notes", "--push", a.id)
      expect(run("show", "notes", a.id)).to eq(1)
      expect(err.string).to include("notes has no text yet")

      run("push", "notes", "-m", "the text", a.id)
      reset_out
      expect(run("show", "notes", a.id)).to eq(0)
      expect(out.string).to eq("the text\n")

      reset_out
      run("show", "notes", "--json", a.id)
      expect(JSON.parse(out.string)).to include("source" => include("name" => "notes"),
                                                "snapshot" => include("text" => "the text", "serial" => 1))
    end
  end

  describe "refresh" do
    it "runs the command here, in the session's folder, and says what came of it" do
      a = make
      run("add", "where", "--cmd", "pwd", a.id)
      reset_out

      expect(run("refresh", "where", a.id)).to eq(0), err.string
      expect(out.string).to start_with("#{a.id[0, 8]}  where: new text (")
      expect(own(a).snapshot("where").text.strip).to eq(File.realpath(repo))
      run("refresh", "where", a.id)
      expect(out.string.lines.last).to include("where: unchanged (")
    end

    it "fails for a failing command, a push source and a source being fetched" do
      a = make
      run("add", "broken", "--cmd", "echo nope >&2; exit 2", a.id)
      run("add", "notes", "--push", a.id)

      expect(run("refresh", "broken", a.id)).to eq(1)
      expect(err.string).to include("broken failed: exit 2: nope")
      expect(run("refresh", "notes", a.id)).to eq(1)
      expect(err.string).to include("notes is pushed (chi context push), it has no command to run")

      File.open(own(a).lock_path("broken"), File::RDWR | File::CREAT) do |lock|
        lock.flock(File::LOCK_EX)
        expect(run("refresh", "broken", a.id)).to eq(1)
      end
      expect(err.string).to include("broken is being fetched right now")
    end
  end

  describe "rm, mute and unmute" do
    it "detaches a session's source, and points a project's at --project or mute" do
      a = make
      run("add", "mine", "--push", a.id)
      run("add", "ours", "--push", "--project")

      expect(run("rm", "mine", a.id)).to eq(0)
      expect(own(a).source("mine")).to be_nil
      expect(run("rm", "ours", a.id)).to eq(1)
      expect(err.string).to include("ours is the project's: chi context rm ours --project, or mute it for this session")
      expect(run("rm", "ours", "--project")).to eq(0)
      expect(project.source("ours")).to be_nil
    end

    it "mutes a project source for one session and unmutes it" do
      a = make
      run("add", "ours", "--push", "--project")

      expect(run("mute", "ours", a.id)).to eq(0)
      expect(own(a).muted?("ours")).to be(true)
      expect(run("unmute", "ours", a.id)).to eq(0)
      expect(own(a).muted?("ours")).to be(false)
      expect(run("mute", "nope", a.id)).to eq(1)
      expect(run("mute", "ours")).to eq(2)
    end
  end
end
