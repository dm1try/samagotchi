# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/session_row"
require "samagotchi/session_manager"
require "samagotchi/children_status"
require "samagotchi/verify_fresh"
require "samagotchi/tools/list_sessions"
require "samagotchi/web/session_summary"

# Every surface that shows a session's state reads the one SessionRow rule:
# the summaries row, the web's summary, /children (.of and .counts), the
# list_sessions tool, chi sessions list's line and Verify fresh's "child
# running". Each state below is built once and asked of each.
RSpec.describe "SessionRow parity" do
  let(:tmpdir) { Dir.mktmpdir("session-row-parity") }
  let(:locks) { [] }
  let(:old) { (Time.now - 600).iso8601(3) }
  let(:parent) { make_session(prompt: "the plan") }
  let(:peers) { Struct.new(:session_id, :state_dir, :cwd).new(parent.id, tmpdir, "/work/app") }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  # test_run: false pinned: under CI the default marks every new session a
  # test run, and list_sessions leaves test runs out.
  def make_session(prompt:, parent_id: nil, status: nil, pending: nil, scratch: false)
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app", test_run: false,
                                    parent_id: parent_id, delegate: !parent_id.nil?).tap do |s|
      s.last_prompt = prompt
      s.status = status if status
      s.pending_question = pending
      s.scratch = scratch
      s.save(state_dir: tmpdir)
      # Past the starting grace: a saved "running" with no worker is not one on its way.
      path = File.join(tmpdir, "#{s.id}.json")
      File.write(path, JSON.generate(JSON.parse(File.read(path)).merge("updated_at" => old)))
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir).tap { |d| FileUtils.mkdir_p(d) }

  def lock(session, kind) = locks << Samagotchi::OwnerLock.acquire(dir_of(session), kind: kind)

  def question(kind: "question", relayed: nil)
    { "id" => "q1", "kind" => kind, "question" => "which?", "created_at" => Time.now.iso8601,
      "relayed_to" => relayed }.compact
  end

  # The child in +state+, a delegate of parent (in its delegates.json).
  def child_in(state)
    running = Samagotchi::Session::STATUS_RUNNING
    child = case state
            when :live_idle, :kindless then make_session(prompt: "work", parent_id: parent.id)
            when :live_running, :dead_running, :tui then make_session(prompt: "work", parent_id: parent.id, status: running)
            when :question_live, :question_dead
              make_session(prompt: "work", parent_id: parent.id, pending: question)
            when :relayed
              make_session(prompt: "work", parent_id: parent.id, pending: question(kind: "approval",
                                                                                   relayed: { "parent_short" => "pppppppp" }))
            when :stopped then make_session(prompt: "work", parent_id: parent.id, status: Samagotchi::Session::STATUS_STOPPED)
            when :archived, :scratch then make_session(prompt: "work", parent_id: parent.id, scratch: state == :scratch)
            end
    case state
    when :live_idle, :live_running, :question_live, :relayed then lock(child, "worker")
    when :tui then lock(child, "tui")
    when :kindless then lock(child, nil)
    when :archived then Samagotchi::ArchiveStore.archive(child.id, state_dir: tmpdir)
    end
    Samagotchi::Tools::DelegateCursors.update(parent.id, child.id, state_dir: tmpdir) { |c| c }
    child
  end

  STATES = {
    live_idle: { status: "idle", live: true, busy: false, waiting: nil },
    live_running: { status: "running", live: true, busy: true, waiting: nil },
    dead_running: { status: "idle", live: false, busy: false, waiting: nil },
    question_live: { status: "idle", live: true, busy: false, waiting: "question" },
    question_dead: { status: "idle", live: false, busy: false, waiting: nil },
    relayed: { status: "idle", live: true, busy: false, waiting: "approval" },
    tui: { status: "running", live: false, busy: false, waiting: nil },
    kindless: { status: "idle", live: true, busy: false, waiting: nil },
    stopped: { status: "stopped", live: false, busy: false, waiting: nil },
    archived: { status: "idle", live: false, busy: false, waiting: nil },
    scratch: { status: "idle", live: false, busy: false, waiting: nil }
  }.freeze

  STATES.each do |state, want|
    it "reads #{state} the same everywhere" do
      child = child_in(state)
      dir = dir_of(child)
      owner = Samagotchi::OwnerLock.owner(dir)

      row = Samagotchi::SessionManager.session_summaries(state_dir: tmpdir, include_archived: true)
                                      .find { |r| r[:id] == child.id }
      expect(row.slice(:status, :live, :busy, :waiting)).to eq(want)

      web = Samagotchi::Web::SessionSummary.build(Samagotchi::Session.load(child.id, state_dir: tmpdir), owner: owner,
                                                                                                         session_dir: dir)
      expect([web[:status], web[:pending_question]&.dig(:kind)]).to eq([want[:status], want[:waiting]])

      kid = Samagotchi::ChildrenStatus.of(parent.id, state_dir: tmpdir, include_archived: true).find { |c| c.id == child.id }
      expect([kid.live, kid.waiting]).to eq([want[:live], want[:waiting]])
      shown = if want[:waiting] then "waiting"
              elsif want[:busy] then "running"
              end
      expect(kid.state).to eq(shown) if shown
      expect(kid.state).not_to eq("running") unless want[:busy]

      counts = Samagotchi::ChildrenStatus.counts(parent.id, state_dir: tmpdir)
      counted = state == :archived ? Samagotchi::ChildrenStatus::Counts.none.to_h.slice(:running, :waiting) : nil
      expect(counts.to_h.slice(:running, :waiting))
        .to eq(counted || { running: want[:busy] ? 1 : 0, waiting: want[:waiting] ? 1 : 0 })

      unless state == :archived
        text = Samagotchi::Tools::ListSessions.call("", peers: peers)
        listed = text.lines.find { |l| l.start_with?(child.id[0, 8]) }
        expect(listed).to start_with("#{child.id[0, 8]}  #{want[:live] ? "live" : "not live"}  #{want[:busy] ? "running" : "idle"}")
      end

      word = if state == :relayed then "waiting (in parent pppppppp)"
             elsif want[:waiting] then "waiting"
             else want[:status]
             end
      expect(Samagotchi::SessionRow.from_summary_h(row).cli_line).to start_with("#{child.id}  #{word.ljust(8)}  ")

      expect(Samagotchi::VerifyFresh.send(:child_running?, child.id, tmpdir)).to eq(want[:busy])
    end
  end
end
