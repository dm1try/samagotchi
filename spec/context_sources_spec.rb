# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/context_sources"

RSpec.describe Samagotchi::ContextSources do
  let(:tmpdir) { Dir.mktmpdir("context-sources") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions") }
  let(:session_id) { "11111111-2222-3333-4444-555555555555" }

  after { FileUtils.rm_rf(tmpdir) }

  def source(name, scope: "session", cmd: nil, why: nil)
    described_class::Source.new(name: name, cmd: cmd, every_seconds: nil, why: why, hint: nil, scope: scope,
                                added_by: "cli", created_at: "2026-10-05T10:00:00Z")
  end

  def fetched(text, summary: nil, wake: false, hint: nil)
    described_class::Fetched.new(text: text, summary: summary, wake: wake, hint: hint)
  end

  it "keeps everything under <state dir>/context, apart from the session dirs" do
    loc = described_class.session_location(session_id, state_dir: state_dir)
    project = described_class.project_location("app_12345678", state_dir: state_dir)

    expect(loc.dir).to eq(File.join(tmpdir, "samagotchi", "context", "sessions", session_id))
    expect(project.dir).to eq(File.join(tmpdir, "samagotchi", "context", "projects", "app_12345678"))
  end

  describe "names" do
    it "takes lowercase slugs up to 40 chars" do
      expect(described_class.check_name!("pr-123")).to eq("pr-123")
      expect(described_class.check_name!("a" * 40)).to eq("a" * 40)
    end

    it "refuses anything else, path tricks included, and the reserved subscriptions" do
      ["", "-x", "PR", "a/b", "../x", "a.b", "a" * 41, "subscriptions"].each do |bad|
        expect { described_class.check_name!(bad) }.to raise_error(described_class::Invalid), bad
      end
    end
  end

  describe "--every" do
    it "is at least 30 seconds and a whole number" do
      expect(described_class.check_every!("30")).to eq(30)
      expect(described_class.check_every!(nil)).to be_nil
      expect { described_class.check_every!("29") }.to raise_error(described_class::Invalid, /least is 30/)
      expect { described_class.check_every!("5m") }.to raise_error(described_class::Invalid, /takes seconds/)
    end
  end

  describe "a location" do
    let(:loc) { described_class.session_location(session_id, state_dir: state_dir) }

    it "adds, lists and removes sources (with their snapshot; the lock stays for a fetch running), refusing a second of one name" do
      loc.add(source("pr-1", cmd: "gh pr view 1"))
      loc.add(source("notes"))
      loc.record_text("notes", fetched("hello"))
      FileUtils.touch(loc.lock_path("notes"))

      expect(loc.sources.map(&:name)).to eq(%w[notes pr-1])
      expect(loc.source("pr-1")).to have_attributes(cmd: "gh pr view 1", scope: "session", push?: false)
      expect { loc.add(source("notes")) }.to raise_error(described_class::Invalid, /already attached/)

      expect(loc.remove("notes")).to be(true)
      expect(Dir.children(loc.dir).sort).to eq(["notes.lock", "pr-1.json"])
      expect(loc.remove("notes")).to be(false)
    end

    it "doesn't list the snapshots, the subscriptions or the markers as sources" do
      loc.add(source("a"))
      loc.record_text("a", fetched("x"))
      loc.mute("a")
      loc.update_subscription("a") { |sub| sub.with(seen: "r") }

      expect(loc.sources.map(&:name)).to eq(["a"])
    end

    it "counts revisions, keeps the summary and wake of a new one, and only moves fetched_at for the same text" do
      first = loc.record_text("a", fetched("one", summary: "first", wake: true, hint: "https://x/1"),
                              now: Time.utc(2026, 10, 5, 10))
      same = loc.record_text("a", fetched("one", summary: "ignored", wake: false), now: Time.utc(2026, 10, 5, 11))
      second = loc.record_text("a", fetched("two", summary: "second"), now: Time.utc(2026, 10, 5, 12))

      expect(first).to have_attributes(serial: 1, summary: "first", wake: true, hint: "https://x/1",
                                       revision: described_class.revision_of("one"))
      expect(same).to have_attributes(serial: 1, summary: "first", wake: true, fetched_at: "2026-10-05T11:00:00Z")
      expect(second).to have_attributes(serial: 2, summary: "second", wake: false, hint: "https://x/1")
      expect(loc.snapshot("a")).to eq(second)
    end

    it "summarises a plain-text change by its line counts" do
      loc.record_text("a", fetched("a\nb\nc\n"))
      expect(loc.snapshot("a").summary).to eq("3 lines of text")

      loc.record_text("a", fetched("a\nc\nd\ne\n"))
      expect(loc.snapshot("a").summary).to eq("content changed (+2/−1 lines)")
    end

    it "records an error with the time the failures began, keeps the text, and a success clears it" do
      loc.record_text("a", fetched("good"))
      loc.record_error("a", "exit 1: boom\nmore", now: Time.utc(2026, 10, 5, 10))
      again = loc.record_error("a", "exit 1: again", now: Time.utc(2026, 10, 5, 11))

      expect(again).to have_attributes(text: "good", error: "exit 1: again", error_since: "2026-10-05T10:00:00.000000Z")
      expect(loc.record_text("a", fetched("good"))).to have_attributes(error: nil, error_since: nil, serial: 1)
    end

    it "mutes and unmutes with marker files" do
      loc.mute("pr-1")
      expect(loc.muted?("pr-1")).to be(true)
      loc.unmute("pr-1")
      expect(loc.muted?("pr-1")).to be(false)
    end

    it "keeps subscriptions by name" do
      loc.update_subscription("a") { |sub| sub.with(seen: "r1", seen_serial: 1) }
      loc.update_subscription("b") { |sub| sub.with(read: "r9") }

      expect(loc.subscription("a")).to have_attributes(seen: "r1", seen_serial: 1, read: nil)
      expect(loc.subscription("b").read).to eq("r9")
      expect(loc.subscription("c")).to eq(described_class::Subscription.blank("c"))
    end
  end

  describe ".attached" do
    let(:root) { "/work/app" }
    let(:project) { described_class.project_location_for(root, state_dir: state_dir) }
    let(:own) { described_class.session_location(session_id, state_dir: state_dir) }

    it "keys a project by MemoryPaths' project key" do
      expect(project.key).to eq("app_#{Digest::MD5.hexdigest(root)[0..7]}")
    end

    it "lists the session's own sources, then the project's; a session source shadows a project one" do
      project.add(source("pr-1", scope: "project", why: "project's"))
      project.add(source("ci", scope: "project"))
      own.add(source("pr-1", why: "mine"))

      list = described_class.attached(session_id, project_root: root, state_dir: state_dir)
      expect(list.map { |a| [a.name, a.source.scope] }).to eq([%w[pr-1 session], %w[ci project]])

      all = described_class.attached(session_id, project_root: root, state_dir: state_dir, shadowed: true)
      expect(all.map { |a| [a.name, a.source.scope, a.shadowed] })
        .to eq([["pr-1", "session", false], ["ci", "project", false], ["pr-1", "project", true]])
    end

    it "has no project sources for a session in no repo" do
      own.add(source("a"))
      expect(described_class.attached(session_id, project_root: nil, state_dir: state_dir).map(&:name)).to eq(["a"])
    end
  end

  it ".project_cwd: the root when it is a checkout (.git a dir or a file), else the fallback" do
    checkout = File.join(tmpdir, "app").tap { |d| FileUtils.mkdir_p(File.join(d, ".git")) }
    linked = File.join(tmpdir, "wt").tap { |d| FileUtils.mkdir_p(d) && File.write(File.join(d, ".git"), "gitdir: x\n") }
    bare = File.join(tmpdir, "proj", ".bare").tap { |d| FileUtils.mkdir_p(d) }

    expect(described_class.project_cwd(checkout, "/fallback")).to eq(checkout)
    expect(described_class.project_cwd(linked, "/fallback")).to eq(linked)
    expect(described_class.project_cwd(bare, "/fallback")).to eq("/fallback")
    expect(described_class.project_cwd(nil, "/fallback")).to eq("/fallback")
  end

  it "removes a deleted session's folder, and nothing for an id that isn't one" do
    loc = described_class.session_location(session_id, state_dir: state_dir)
    loc.add(source("a"))

    expect(described_class.remove_session("../x", state_dir: state_dir)).to eq([])
    expect(described_class.remove_session(session_id, state_dir: state_dir)).to eq([loc.dir])
    expect(Dir.exist?(loc.dir)).to be(false)
  end

  describe ".parse_output (the contract)" do
    it "takes plain text whole" do
      expect(described_class.parse_output("line 1\nline 2\n"))
        .to eq(fetched("line 1\nline 2\n"))
    end

    it "takes a JSON object with a string text, one-lining summary and hint, wake only when true" do
      raw = JSON.generate(text: "PR body", summary: "2 new\ncomments  ", wake: true, hint: "https://x", other: 1)
      expect(described_class.parse_output(raw)).to eq(fetched("PR body", summary: "2 new comments", wake: true, hint: "https://x"))
      expect(described_class.parse_output(JSON.generate(text: "t", wake: "yes")).wake).to be(false)
    end

    it "cuts a long summary at 200 chars" do
      summary = described_class.parse_output(JSON.generate(text: "t", summary: "x" * 300)).summary
      expect(summary.length).to eq(200)
      expect(summary).to end_with("…")
    end

    it "treats JSON without a string text as plain text" do
      raw = JSON.generate(summary: "s")
      expect(described_class.parse_output(raw).text).to eq(raw)
      expect(described_class.parse_output("[1, 2]").text).to eq("[1, 2]")
    end

    it "refuses empty output and text over 1 MiB" do
      expect { described_class.parse_output(" \n") }.to raise_error(described_class::Invalid, /empty/)
      expect { described_class.parse_output(JSON.generate(text: "")) }.to raise_error(described_class::Invalid, /empty/)
      expect { described_class.parse_output("x" * ((1024 * 1024) + 1)) }.to raise_error(described_class::Invalid, /1 MiB/)
    end

    it "reads bytes that aren't UTF-8 as UTF-8, invalid ones replaced" do
      expect(described_class.parse_output((+"caf\xC3\xA9 \xFF").force_encoding(Encoding::BINARY)).text).to eq("café �")
    end
  end
end
