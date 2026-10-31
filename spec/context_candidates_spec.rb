# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/context_candidates"
require "samagotchi/session"

RSpec.describe Samagotchi::ContextCandidates do
  let(:tmpdir) { Dir.mktmpdir("context-candidates") }
  let(:state_dir) { File.join(tmpdir, "samagotchi", "sessions").tap { |d| FileUtils.mkdir_p(d) } }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: tmpdir).tap do |s|
      s.save(state_dir: state_dir)
    end
  end
  let(:own) { Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir) }

  after { FileUtils.rm_rf(tmpdir) }

  def candidate(name = "pr-412", mentions: ["#412", "feat/login-fix", "https://github.com/a/b/pull/412"], cmd: "printf 'the PR'")
    Samagotchi::ContextSources::Candidate.new(name: name, url: nil, cmd: cmd, title: "#412 Fix login", describe: nil,
                                              mentions: mentions, proposed_by: "plugin:spec", at: nil)
  end

  describe ".mention_in (the mention rules)" do
    def mentions?(text, mentions) = !described_class.mention_in(text, candidate(mentions: mentions)).nil?

    it "matches #N for N >= 10 as a whole token, in any text around it" do
      expect(mentions?("review #412 please", ["#412"])).to be(true)
      expect(mentions?("(#412)", ["#412"])).to be(true)
      expect(mentions?("see #4120", ["#412"])).to be(false)
      expect(mentions?("issue a#412", ["#412"])).to be(false)
      expect(mentions?("color &#412;", ["#412"])).to be(false)
    end

    it "matches #N below 10 only after PR / pull" do
      expect(mentions?("step #4 first", ["#4"])).to be(false)
      expect(mentions?("look at PR #4", ["#4"])).to be(true)
      expect(mentions?("pr#4 again", ["#4"])).to be(true)
      expect(mentions?("the pull request #4", ["#4"])).to be(true)
      expect(mentions?("pull #4", ["#4"])).to be(true)
    end

    it "matches a branch only at 6+ chars with a /, - or _, whole-token and in any case" do
      expect(mentions?("on Feat/Login-Fix now", ["feat/login-fix"])).to be(true)
      expect(mentions?("branch feat/login-fix.", ["feat/login-fix"])).to be(true)
      expect(mentions?("feat/login-fixes", ["feat/login-fix"])).to be(false)
      expect(mentions?("x/feat/login-fix", ["feat/login-fix"])).to be(false)
      expect(mentions?("feat/login-fix.rb", ["feat/login-fix"])).to be(false)
      expect(mentions?("the web is down", ["web"])).to be(false)
      expect(mentions?("a-b-c", ["a-b-c"])).to be(false)
      expect(mentions?("work on develop", ["develop"])).to be(false)
      expect(mentions?("my_branch", ["my_branch"])).to be(true)
    end

    it "matches a URL exactly" do
      url = "https://github.com/a/b/pull/412"
      expect(mentions?("see #{url}", [url])).to be(true)
      expect(mentions?("(#{url})", [url])).to be(true)
      expect(mentions?("#{url}.", [url])).to be(true)
      expect(mentions?("#{url}/files", [url])).to be(false)
      expect(mentions?("#{url}3", [url])).to be(false)
    end

    it "ignores text inside fenced code blocks (pasted logs), outside them still counts" do
      expect(mentions?("why?\n```\nMerged #412 into main\n```\n", ["#412"])).to be(false)
      expect(mentions?("~~~\n#412\n~~~\nand #412", ["#412"])).to be(true)
      expect(mentions?("```\nunclosed #412", ["#412"])).to be(false)
    end

    it "names the mention found" do
      expect(described_class.mention_in("fix feat/login-fix", candidate)).to eq("feat/login-fix")
    end
  end

  describe ".before_turn" do
    before { own.add_candidate(candidate) }

    it "attaches a mentioned candidate, its why naming the mention, and fetches it first" do
      names = described_class.before_turn(session: session, prompt: "review #412", author: nil, state_dir: state_dir)

      expect(names).to eq(["pr-412"])
      expect(own.source("pr-412")).to have_attributes(why: "you mentioned #412", title: "#412 Fix login", cmd: "printf 'the PR'",
                                                      added_by: "plugin:spec", scope: "session")
      expect(own.snapshot("pr-412").text).to eq("the PR")
      expect(described_class.with_status(session.id, project_root: nil, state_dir: state_dir).map(&:last)).to eq(["attached"])
    end

    it "attaches nothing for a participant's prompt, in a review session, or without a mention" do
      expect(described_class.before_turn(session: session, prompt: "#412", author: "p:abc", state_dir: state_dir)).to eq([])
      expect(described_class.before_turn(session: session, prompt: "unrelated", author: nil, state_dir: state_dir)).to eq([])
      session.review = { "subjects" => ["a.md"] }
      expect(described_class.before_turn(session: session, prompt: "#412", author: nil, state_dir: state_dir)).to eq([])
      expect(own.sources).to eq([])
    end

    it "never attaches a declined candidate again" do
      own.decline("pr-412", nil)

      expect(described_class.before_turn(session: session, prompt: "#412", author: nil, state_dir: state_dir)).to eq([])
      expect(described_class.with_status(session.id, project_root: nil, state_dir: state_dir).map(&:last)).to eq(["declined"])
    end

    it "stops waiting for a slow first fetch at its limit; nothing is recorded, so the poller fetches it soon" do
      own.remove_candidate("pr-412")
      own.add_candidate(candidate(cmd: "sleep 5; printf late"))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect(described_class.before_turn(session: session, prompt: "#412", author: nil, state_dir: state_dir, seconds: 0.3))
        .to eq(["pr-412"])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 3
      expect(own.snapshot("pr-412")).to have_attributes(text: nil, checked_at: nil, error: nil)
    end

    it "attaches one an earlier owner prompt mentions (a proposal that came while it ran: the REPL)" do
      session.messages = [{ role: "user", turn_id: "t1", content: "look at #412" }, { role: "model", content: "ok" },
                          { role: "user", turn_id: "t2", content: "#999", author: "p:abc" }]

      expect(described_class.before_turn(session: session, prompt: "next", author: nil, state_dir: state_dir)).to eq(["pr-412"])
      expect(own.source("pr-412").why).to eq("you mentioned #412")
    end

    it "fetches a candidate a late proposal attached that was never tried" do
      described_class.after_propose(candidate, own: own,
                                               messages: [{ role: "user", turn_id: "t1", content: "look at #412" }])
      expect(own.snapshot("pr-412").checked_at).to be_nil

      described_class.before_turn(session: session, prompt: "next", author: nil, state_dir: state_dir)
      expect(own.snapshot("pr-412").text).to eq("the PR")
    end
  end

  describe ".after_propose (a late proposal)" do
    it "attaches when an owner prompt already in the session mentions it, not a participant's or a note" do
      messages = [{ role: "user", turn_id: "t1", content: "#412", author: "p:abc" },
                  { role: "system", kind: "note", content: "#412" },
                  { role: "user", turn_id: "t2", content: "unrelated" }]
      expect(described_class.after_propose(candidate, own: own, messages: messages)).to be_nil

      messages << { role: "user", turn_id: "t3", content: "and feat/login-fix?" }
      expect(described_class.after_propose(candidate, own: own, messages: messages)).to eq("pr-412")
      expect(own.source("pr-412").why).to eq("you mentioned feat/login-fix")
    end
  end

  describe ".deliver_notes (the REPL's turn start)" do
    it "adds the attached notes of candidate sources only, once" do
      own.add_candidate(candidate)
      described_class.before_turn(session: session, prompt: "#412", author: nil, state_dir: state_dir)
      own.add(Samagotchi::ContextSources::Source.new(name: "other", cmd: nil, every_seconds: nil, why: nil, hint: nil,
                                                     scope: "session", added_by: "cli", created_at: nil))
      own.record_text("other", Samagotchi::ContextSources::Fetched.new(text: "x", summary: nil, wake: false, hint: nil))
      engine = Class.new do
        attr_reader :notes

        def add_context_note(_session, note) = (@notes ||= []) << note
      end.new

      expect(described_class.deliver_notes(engine, session, state_dir: state_dir)).to eq(1)
      expect(engine.notes.map { _1[:context_source] }).to eq(["pr-412"])
      expect(engine.notes.first[:text]).to include("Attached: pr-412. Why: you mentioned #412.")
      expect(described_class.deliver_notes(engine, session, state_dir: state_dir)).to eq(0)
    end
  end

  it "lists the candidates with their status for /context" do
    expect(described_class.listing(session.id, project_root: nil, state_dir: state_dir)).to be_nil
    own.add_candidate(candidate)

    expect(described_class.listing(session.id, project_root: nil, state_dir: state_dir))
      .to eq("Candidates (attached when a prompt of yours mentions one):\n- pr-412 · proposed · #412 Fix login")
  end
end
