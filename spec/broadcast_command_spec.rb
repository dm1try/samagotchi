# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "json"
require "spec_helper"
require "samagotchi/broadcast_command"
require "samagotchi/note_command"
require "samagotchi/owner_lock"

RSpec.describe Samagotchi::BroadcastCommand do
  let(:tmpdir) { File.realpath(Dir.mktmpdir("broadcast-command")) }
  let(:state_dir) { File.join(tmpdir, "state", "sessions") }
  let(:locks) { [] }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:now) { Time.now }
  let(:stamp) { now.localtime.strftime("%Y-%m-%d %H:%M") }
  let(:note) { "payments API returns 500 since 14:00 (PAY-123)\nsee https://notion.so/team/checkout-v2" }
  # The triage model's answers: yes for a card whose recent prompt names
  # one of +yes+, no otherwise; a card naming one of +slow+ waits past the
  # deadline.
  let(:triage_yes) { [] }
  let(:triage_slow) { [] }
  let(:judged) { [] }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  # A session in its own folder, a git checkout of +branch+ when given.
  def make(name, branch: nil, owner: nil, prompts: ["hello"], **attrs)
    cwd = File.join(tmpdir, name)
    FileUtils.mkdir_p(File.join(cwd, ".git"))
    File.write(File.join(cwd, ".git", "HEAD"), "ref: refs/heads/#{branch || "main"}\n")
    messages = prompts.map { |text| { role: "user", content: text } }
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: cwd, test_run: false,
                                    messages: messages, **attrs).tap do |s|
      s.last_prompt = prompts.last.to_s
      s.save(state_dir: state_dir)
      age(s)
      locks << Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(s.id, state_dir: state_dir), kind: owner) if owner
    end
  end

  # Saves within one millisecond tie: each session made is a second newer
  # than the one before, so the lists' newest-first order is fixed.
  def age(session)
    @made = (@made || 0) + 1
    file = Samagotchi::Session.session_file(session.id, state_dir: state_dir)
    data = JSON.parse(File.read(file)).merge("updated_at" => (Time.now - 100 + @made).iso8601(3))
    File.write(file, JSON.generate(data))
  end

  def triage(cancel)
    yes = triage_yes
    slow = triage_slow
    seen = judged
    Class.new do
      define_method(:judge) do |_note, card|
        seen << card.id
        if slow.any? { |word| card.recent.to_s.include?(word) }
          sleep 0.01 until cancel.cancelled?
        end
        relevant = yes.any? { |word| card.recent.to_s.include?(word) }
        Samagotchi::Broadcast::Triage::Verdict.new(relevant: relevant, p: relevant ? 1.0 : 0.0,
                                                   reason: "model: #{relevant ? "yes" : "no"}", by: "model")
      end
    end.new
  end

  def run(*argv, env: {}, stdin: StringIO.new(""), deadline: 5)
    described_class.new(argv, stdin: stdin, stdout: out, stderr: err, state_dir: state_dir, env: env, now: now,
                              active_hours: 8, ticket_pattern: nil, triage: method(:triage), triage_parallel: 2,
                              triage_deadline: deadline, threshold: 0.5).run
  end

  def notes_of(session)
    dir = File.join(Samagotchi::Session.session_dir(session.id, state_dir: state_dir), Samagotchi::SessionInbox::NOTES_DIR)
    Dir.glob(File.join(dir, "*.json")).map { |path| JSON.parse(File.read(path)) }
  end

  def short(session) = session.id[0, 8]

  context "with sessions on different work" do
    let!(:repl) { make("repl", branch: "fix/pay-123-x", owner: "tui") }
    let!(:other) { make("docs", owner: "worker", prompts: ["write the composer docs"]) }
    let!(:prd) { make("checkout", prompts: ["the PRD: https://notion.so/team/checkout-v2"]) }
    let!(:pay) { make("pay", branch: "feat/pay-123-retry", owner: "worker") }
    let!(:delegate) { make("child", branch: "feat/pay-123-retry", owner: "worker", parent_id: pay.id, delegate: true) }
    let!(:scratch) { make("scratch", branch: "feat/pay-123-retry", scratch: true) }

    it "delivers to the sessions that share a tag with the note, asks triage about the rest, delivered first" do
      code = run("-m", note)

      expect(code).to eq(0), err.string
      expect(out.string.lines.map(&:chomp)).to eq(
        ["broadcast  \"payments API returns 500 since 14:00 (PAY-123) …\"",
         "#{short(pay)}  delivered  ticket PAY-123 matches (branch)",
         "#{short(prd)}  delivered  link notion.so/team/checkout-v2 matches (messages); waits for its next start",
         "#{short(other)}  skipped    model: no",
         "#{short(repl)}  skipped    open in a chi REPL",
         "delivered 2 · skipped 2"]
      )
      expect(judged).to eq([other.id])
      expect(notes_of(pay)).to contain_exactly(include("source" => "broadcast"))
      expect(notes_of(pay).first["text"]).to eq(
        "#{note}\n(Shared by your user on #{stamp} with the sessions it may concern; " \
        "it reached you because ticket PAY-123 matches your branch.)"
      )
      expect(notes_of(prd).first["text"]).to end_with(
        "it reached you because link notion.so/team/checkout-v2 is in your user's messages too.)"
      )
      expect([other, repl, delegate, scratch].map { |s| notes_of(s) }).to all(eq([]))
    end

    it "delivers to every recipient with --all, and still not into a chi REPL" do
      code = run("--all", stdin: StringIO.new("deploy freeze until 18:00\n"))

      expect(code).to eq(0), err.string
      expect(out.string.lines.map(&:chomp)).to eq(
        ["broadcast  \"deploy freeze until 18:00\"",
         "#{short(pay)}  delivered  --all",
         "#{short(prd)}  delivered  --all; waits for its next start",
         "#{short(other)}  delivered  --all",
         "#{short(repl)}  skipped    open in a chi REPL",
         "delivered 3 · skipped 1"]
      )
      expect([pay, prd, other].map { |s| notes_of(s).map { |n| n["text"] } })
        .to all(eq(["deploy freeze until 18:00\n(Shared by your user on #{stamp} with every active session.)"]))
      expect([repl, delegate, scratch].map { |s| notes_of(s) }).to all(eq([]))
    end

    it "shows the note's tags, each recipient's verdict and scope card with --dry-run, and delivers nothing" do
      code = run("--dry-run", "-m", note)

      expect(code).to eq(0), err.string
      lines = out.string.lines.map(&:chomp)
      expect(lines.first(3)).to eq(
        ["broadcast (dry run: nothing is delivered)  \"payments API returns 500 since 14:00 (PAY-123) …\"",
         "note tags: ticket PAY-123 · link notion.so/team/checkout-v2",
         "#{short(pay)}  would get it  ticket PAY-123 matches (branch)"]
      )
      expect(lines).to include("          project: pay (branch feat/pay-123-retry)",
                               "          tags:    ticket PAY-123",
                               "#{short(other)}  skipped       model: no",
                               "          recent:  write the composer docs")
      expect(lines.last).to eq("would deliver 2 · skipped 2")
      expect([pay, prd, other, repl].map { |s| notes_of(s) }).to all(eq([]))
    end
  end

  context "with sessions triage judges" do
    let!(:docs) { make("docs", owner: "worker", prompts: ["write the composer docs"]) }
    let!(:retry_client) { make("client", owner: "worker", prompts: ["make the payments client retry on 5xx"]) }
    let!(:slow) { make("slow", owner: "worker", prompts: ["tune the slow checkout query"]) }
    let(:triage_yes) { ["payments"] }

    it "delivers what the model says concerns it, with no reason line of its own, and skips the rest" do
      code = run("-m", "payments API returns 500 since 14:00")

      expect(code).to eq(0), err.string
      expect(out.string.lines.map(&:chomp).drop(1)).to eq(
        ["#{short(retry_client)}  delivered  model: yes",
         "#{short(slow)}  skipped    model: no",
         "#{short(docs)}  skipped    model: no",
         "delivered 1 · skipped 2"]
      )
      expect(notes_of(retry_client).map { |n| n["text"] }).to eq(
        ["payments API returns 500 since 14:00\n(Shared by your user on #{stamp} with the sessions it may concern.)"]
      )
      expect(judged).to contain_exactly(docs.id, retry_client.id, slow.id)
    end

    context "when triage is slow" do
      let(:triage_slow) { ["slow"] }

      it "delivers unchecked what the deadline leaves unjudged, and the summary says so" do
        code = run("-m", "payments API returns 500 since 14:00", deadline: 0.3)

        expect(code).to eq(0), err.string
        expect(out.string.lines.map(&:chomp).drop(1)).to eq(
          ["#{short(slow)}  delivered  unchecked: triage deadline",
           "#{short(retry_client)}  delivered  model: yes",
           "#{short(docs)}  skipped    model: no",
           "delivered 2 · skipped 1 · 1 unchecked: triage deadline"]
        )
        expect(notes_of(slow).size).to eq(1)
      end
    end

    it "keeps a note whose first line names a project to that project's sessions" do
      elsewhere = make("elsewhere", owner: "worker", prompts: ["payments work elsewhere"])

      code = run("--dry-run", "-m", "client\n> payments API returns 500")

      expect(code).to eq(0), err.string
      expect(out.string).to include("#{short(retry_client)}  would get it  model: yes")
      expect(out.string).to include("#{short(docs)}  skipped       scope line names client",
                                    "#{short(elsewhere)}  skipped       scope line names client")
      expect(judged).to eq([retry_client.id])
    end
  end

  it "is refused inside a chi session, whatever its id: an agent runs it there" do
    session = make("pay", branch: "PAY-1", owner: "worker")

    [{ "SAMAGOTCHI_PARENT_SESSION" => "chi" }, { "SAMAGOTCHI_PARENT_SESSION" => session.id }].each do |env|
      expect(run("--all", "-m", "x", env: env)).to eq(1)
    end
    expect(err.string.lines.uniq).to eq(["chi broadcast: chi broadcast is for your user, not an agent\n"])
    expect(notes_of(session)).to eq([])
    expect(run("--dry-run", "-m", "PAY-1", env: { "SAMAGOTCHI_PARENT_SESSION" => "" })).to eq(0)
  end

  it "says so and exits 1 when no session is active" do
    expect(run("-m", "x")).to eq(1)
    expect(err.string).to eq("chi broadcast: no sessions to send to: none runs now or ended a turn in the last 8 hours " \
                             "(chi sessions list --scope=all)\n")
  end

  it "refuses a note too long to take the line chi adds" do
    make("pay", owner: "worker")

    expect(run("--all", "-m", "x" * ((16 * 1024) - 100))).to eq(1)
    expect(err.string).to eq("chi broadcast: the note is 16284 bytes; a broadcast takes up to 15872 " \
                             "(16 KiB less room for the line chi adds)\n")
  end

  it "refuses an empty note, an id and an unknown flag" do
    expect(run("-m", " ")).to eq(1)
    expect(err.string).to include("chi broadcast: the note is empty")
    expect(run("-m", "x", "3f2a")).to eq(2)
    expect(run("--wake", "-m", "x")).to eq(2)
    expect(err.string).to include("chi broadcast: unknown option --wake")
  end

  it "keeps --source broadcast for itself: chi note refuses it" do
    session = make("pay", owner: "worker")
    code = Samagotchi::NoteCommand.new(["--source", "broadcast", "-m", "x", session.id], stdout: out, stderr: err,
                                                                                          state_dir: state_dir).run

    expect(code).to eq(2)
    expect(err.string).to start_with("chi note: --source broadcast is chi broadcast's own")
    expect(notes_of(session)).to eq([])
  end
end
