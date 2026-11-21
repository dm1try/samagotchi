# frozen_string_literal: true

require "open3"
require "rbconfig"
require "stringio"
require "tmpdir"
require "spec_helper"
require "samagotchi/session_delete_command"
require "samagotchi/owner_lock"
require "samagotchi/schedules"
require "samagotchi/tools/task_runtime"
require "support/task_dirs"
require_relative "support/remote_backend"

RSpec.describe Samagotchi::SessionDeleteCommand do
  let(:tmpdir) { Dir.mktmpdir("session-delete-command") }
  let(:state_dir) { File.join(tmpdir, "sessions") }
  let(:locks) { [] }
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
  end

  def make(owner: nil, id: nil, prompt: "fix the bug in the parser")
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app").tap do |s|
      s.id = id if id
      s.first_preview = prompt
      s.save(state_dir: state_dir)
      locks << Samagotchi::OwnerLock.acquire(dir_of(s), kind: owner) if owner
    end
  end

  def dir_of(session) = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)

  def gone?(session) = !File.exist?(File.join(state_dir, "#{session.id}.json")) && !Dir.exist?(dir_of(session))

  def run(*argv)
    described_class.new(argv, stdout: out, stderr: err, state_dir: state_dir, access: backend_access(state_dir)).run
  end

  # A chain first -> last, the first archived as a continue leaves it.
  def chain_of_two
    first = make(id: "aaaa1111-0000", prompt: "first")
    Samagotchi::ArchiveStore.archive(first.id, state_dir: state_dir)
    last = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app",
                                           continues: first.id).tap do |s|
      s.id = "bbbb2222-0000"
      s.first_preview = "last"
      s.save(state_dir: state_dir)
    end
    [first, last]
  end

  RemoteBackend.both(self) do
    it "brings the previous link back when it deletes a chain's newest link, and says so" do
      first, last = chain_of_two

      expect(run(last.id)).to eq(0)

      expect(out.string).to eq("bbbb2222  deleted; the previous link aaaa1111 is back in the lists  last\n")
      expect(gone?(last)).to be true
      expect(Samagotchi::ArchiveStore.archived?(dir_of(first))).to be false
    end

    it "says how many of the link's own delegates went with it" do
      _first, last = chain_of_two
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app", parent_id: last.id)
                         .tap { |s| s.id = "cccc3333-0000" }.save(state_dir: state_dir)

      expect(run(last.id)).to eq(0)

      expect(out.string).to eq("bbbb2222  deleted; the previous link aaaa1111 is back in the lists; 1 delegate deleted with it  last\n")
    end

    it "takes a plain session's stopped delegate with it and says so" do
      plain = make(id: "aaaa1111-0000")
      child = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app",
                                              parent_id: plain.id).tap { |s| s.id = "cccc3333-0000" }
      child.save(state_dir: state_dir)

      expect(run(plain.id)).to eq(0)

      expect(out.string).to eq("aaaa1111  deleted; 1 delegate deleted with it  fix the bug in the parser\n")
      expect(gone?(plain) && gone?(child)).to be true
    end

    it "deletes every link with --chain, one line each and a summary" do
      first, last = chain_of_two

      expect(run("--chain", first.id)).to eq(0)

      expect(out.string).to eq("bbbb2222  deleted\naaaa1111  deleted\nchain: 2 deleted\n")
      expect(gone?(first) && gone?(last)).to be true
    end

    it "refuses --chain with a schedule on the chain, in its own words, deleting nothing" do
      first, last = chain_of_two
      entry = Samagotchi::Schedules.new(state_dir: state_dir).add(target: last.id, prompt: "Audit",
                                                                  recurrence: { "every" => "1h" })

      expect(run("--chain", last.id)).to eq(1)

      expect(out.string).to eq("bbbb2222  refused: an enabled schedule runs on this chain; " \
                               "cancel it with chi schedule cancel #{entry.id}\n")
      expect(gone?(first) || gone?(last)).to be false
    end

    it "deletes each session by id or prefix, one line each, and exits 0" do
      first = make(id: "aaaa1111-0000")
      second = make(id: "bbbb2222-0000", prompt: "second")
      FileUtils.mkdir_p(File.join(dir_of(first), "notes"))

      expect(run("aaaa", second.id)).to eq(0)

      expect(out.string).to eq("aaaa1111  deleted  fix the bug in the parser\nbbbb2222  deleted  second\n")
      expect(gone?(first) && gone?(second)).to be true
    end

    it "names a titled session by its title" do
      titled = make(id: "aaaa1111-0000").tap { |s| s.title = "Parser fix" }
      titled.save(state_dir: state_dir)

      expect(run("aaaa")).to eq(0)
      expect(out.string).to eq("aaaa1111  deleted  Parser fix\n")
    end

    it "refuses a live worker without --force, deletes the others, and exits 1" do
      live = make(owner: "worker", id: "aaaa1111-0000")
      idle = make(id: "bbbb2222-0000")

      expect(run(live.id, idle.id)).to eq(1)

      expect(out.string).to include("aaaa1111  refused: its worker is running (--force stops it first)")
      expect(out.string).to include("bbbb2222  deleted")
      expect(gone?(live)).to be false
      expect(gone?(idle)).to be true
    end

    it "with --force stops a live worker first" do
      live = make(owner: "worker", id: "aaaa1111-0000")
      allow(Samagotchi::SessionManager).to receive(:stop_session) do
        locks.each(&:release)
        true
      end

      expect(run("--force", "aaaa")).to eq(0)

      expect(out.string).to eq("aaaa1111  deleted (stopped its worker)  fix the bug in the parser\n")
      expect(gone?(live)).to be true
    end

    it "names an enabled schedule that protects the session from deletion" do
      scheduled = make(id: "aaaa1111-0000")
      schedule = Samagotchi::Schedules.new(state_dir: state_dir).add(
        target: scheduled.id, prompt: "Audit", recurrence: Samagotchi::Schedules.recurrence(every: "1h")
      )

      expect(run("--force", scheduled.id)).to eq(1)

      expect(out.string).to include("aaaa1111  refused: this session is the target of an enabled schedule; " \
                                    "cancel it with chi schedule cancel #{schedule.id}")
      expect(gone?(scheduled)).to be false
    end

    it "says so when the worker is still shutting down after --force" do
      live = make(owner: "worker", id: "aaaa1111-0000")
      allow(Samagotchi::SessionManager).to receive(:stop_session).and_return(false)

      expect(run(live.id, "-f")).to eq(1)

      expect(out.string).to include("aaaa1111  refused: its worker is still shutting down; try again in a moment")
      expect(gone?(live)).to be false
    end

    it "never deletes a session a one-turn chi run has open, --force or not" do
      open = make(owner: "tui", id: "aaaa1111-0000")

      expect(run("--force", open.id)).to eq(1)

      expect(out.string).to include("aaaa1111  refused: it is in use by a one-turn chi --non-interactive run or an older chi's terminal; let it finish first")
      expect(gone?(open)).to be false
    end

    it "reports an unknown id and an ambiguous prefix on stderr and exits 1" do
      make(id: "aaaa1111-0000")
      make(id: "aaaa2222-0000")

      expect(run("nope", "aaaa")).to eq(1)

      expect(err.string).to include("chi sessions delete: no session nope")
      expect(err.string).to include("session id aaaa matches 2 sessions")
      expect(out.string).to eq("")
    end

    it "exits 2 on usage errors" do
      expect(run).to eq(2)
      expect(err.string).to include("give session ids")
      expect(run("--everything", "x")).to eq(2)
      expect(err.string).to include("unknown option --everything")
    end

    describe "a session whose background task still runs" do
      include TaskDirs

      let(:runtime) { Samagotchi::Tools::TaskRuntime }

      around { |example| with_task_dir { |root| @root = root and example.run } }

      def with_task(command)
        session = make(id: "aaaa1111-0000")
        record, error = runtime.create_task(command)
        raise error if error

        session.working_directory = @root
        session.messages = [{ role: "tool_response", content: "[task_create]\ntask_id: #{record.id}" }]
        session.save(state_dir: state_dir)
        [session, record]
      end

      it "refuses, naming it, and exits 1" do
        session, record = with_task("sleep 30.42")

        expect(run(session.id)).to eq(1)

        expect(out.string).to eq("aaaa1111  refused: background tasks it started are still running: sleep 30.42 " \
                                 "(--stop-tasks stops them first)\n")
        expect(gone?(session)).to be(false)
        expect(runtime.load_record(record.id)).to be_running
      end

      it "with --stop-tasks stops it, then deletes, and says so" do
        session, record = with_task("sleep 30.43")

        expect(run("--stop-tasks", session.id)).to eq(0)

        expect(out.string).to eq("aaaa1111  deleted (stopped 1 background task)  fix the bug in the parser\n")
        expect(gone?(session)).to be(true)
        expect(runtime.load_record(record.id)).to have_attributes(status: "stopped", stop_reason: "stopped_by_user")
      end

      it "with --dry-run names it under stopped first and says --stop-tasks, stopping nothing" do
        session, record = with_task("sleep 30.45")

        expect(run("--dry-run", session.id)).to eq(0)

        expect(out.string).to eq(%(aaaa1111  would delete  "fix the bug in the parser"\n) +
                                 "          stopped first: 1 background task (sleep 30.45) — needs --stop-tasks\n")
        expect(gone?(session)).to be(false)
        expect(runtime.load_record(record.id)).to be_running
      end

      it "with --stop-tasks still refuses a live worker without --force" do
        session, = with_task("sleep 30.44")
        locks << Samagotchi::OwnerLock.acquire(dir_of(session), kind: "worker")

        expect(run("--stop-tasks", session.id)).to eq(1)
        expect(out.string).to eq("aaaa1111  refused: its worker is running (--force stops it first)\n")
      end
    end

    describe "--dry-run" do
      def delegate_of(parent, id, owner: nil)
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/work/app",
                                        parent_id: parent.id).tap do |s|
          s.id = id
          s.save(state_dir: state_dir)
          locks << Samagotchi::OwnerLock.acquire(dir_of(s), kind: owner) if owner
        end
      end

      it "leaves no session folder behind" do
        plain = make(id: "aaaa1111-0000")

        expect(Dir.exist?(dir_of(plain))).to be false
        expect(run("--dry-run", plain.id)).to eq(0)

        expect(Dir.exist?(dir_of(plain))).to be false
      end

      it "prints what goes, what is stopped first and what stays, and the flags it needs, deleting nothing" do
        plain = make(owner: "worker", id: "aaaa1111-0000", prompt: "fix the flaky spec")
        stopped = [delegate_of(plain, "bbbb2222-0000"), delegate_of(plain, "cccc3333-0000")]
        running = delegate_of(plain, "dddd4444-0000", owner: "worker")
        under = delegate_of(running, "eeee5555-0000")

        expect(run("--dry-run", "aaaa")).to eq(0)

        # The delegates newest first, as the listing gives them.
        expect(out.string.sub("(bbbb2222, cccc3333)", "(cccc3333, bbbb2222)")).to eq(<<~TEXT)
          aaaa1111  would delete  "fix the flaky spec"
                    goes:          2 stopped delegates (cccc3333, bbbb2222)
                    stopped first: its worker — needs --force
                    stays:         1 running delegate (dddd4444) with its 1 delegate, without a parent
        TEXT
        expect([plain, *stopped, running, under].map { |s| gone?(s) }).to all(be(false))
      end

      it "prints one line for a session with nothing else to it" do
        plain = make(id: "aaaa1111-0000")

        expect(run("--dry-run", plain.id)).to eq(0)
        expect(out.string).to eq(%(aaaa1111  would delete  "fix the bug in the parser"\n))
        expect(gone?(plain)).to be(false)
      end

      it "says a refusal the plan carries and exits 1" do
        scheduled = make(id: "aaaa1111-0000")
        schedule = Samagotchi::Schedules.new(state_dir: state_dir).add(
          target: scheduled.id, prompt: "Audit", recurrence: Samagotchi::Schedules.recurrence(every: "1h")
        )
        idle = make(id: "bbbb2222-0000", prompt: "second")

        expect(run("--dry-run", scheduled.id, idle.id)).to eq(1)

        expect(out.string).to eq("aaaa1111  would be refused: this session is the target of an enabled schedule; " \
                                 "cancel it with chi schedule cancel #{schedule.id}  \"fix the bug in the parser\"\n" \
                                 "bbbb2222  would delete  \"second\"\n")
        expect(gone?(scheduled) || gone?(idle)).to be(false)
      end

      it "says the one-turn run that has it open" do
        make(owner: "tui", id: "aaaa1111-0000")

        expect(run("--dry-run", "aaaa")).to eq(1)
        expect(out.string).to start_with("aaaa1111  would be refused: it is #{Samagotchi::OwnerLock::TUI_BUSY}; let it finish first")
      end

      it "names the undo of a chain's newest link, and with --chain the chain's choice" do
        first, last = chain_of_two
        delegate_of(first, "cccc3333-0000")

        expect(run("--dry-run", last.id)).to eq(0)
        expect(run("--dry-run", "--chain", last.id)).to eq(0)

        expect(out.string).to eq(<<~TEXT)
          bbbb2222  would delete link 2 of 2  "last"
                    back:          the previous link aaaa1111 comes back to the lists (not started)
          bbbb2222  would delete its chain (2 links)  "last"
                    goes:          all 2 links; 1 stopped delegate (cccc3333)
        TEXT
        expect(gone?(first) || gone?(last)).to be(false)
      end

      it "reports an unknown id on stderr and exits 1" do
        expect(run("--dry-run", "nope")).to eq(1)
        expect(err.string).to include("chi sessions delete: no session nope")
      end
    end

    it "prints its usage for --help and exits 0" do
      expect(run("--help")).to eq(0)
      expect(out.string).to include("Usage: chi sessions delete [--force] [--chain] [--stop-tasks] [--dry-run] (ID|PREFIX)...")
    end
  end

  describe "--dry-run's rows for a plan" do
    let(:plan_module) { Samagotchi::SessionAccess::DeletePlan }

    def dry_run(plan, *flags)
      access = instance_double(Samagotchi::SessionAccess::Local, resolve_id: "aaaa1111-0000", delete_plan: plan_module.read(plan))
      allow(access).to receive(:show).and_raise(ArgumentError)
      described_class.new([*flags, "--dry-run", "aaaa"], stdout: out, stderr: err, access: access).run
    end

    it "puts a task chi can't verify under stays, never stopped, and still says --stop-tasks" do
      tasks = { running: [], unverified: [{ session_id: "aaaa1111-0000", id: "20261001120000-3f9a2c1d", command: "x" }],
                unreadable: [{ session_id: "bbbb2222-0000", id: "20261001120000-0badf00d" }] }

      expect(dry_run({ chained: false, session_id: "aaaa1111-0000", link: { tasks: tasks } })).to eq(0)

      expect(out.string).to eq("aaaa1111  would delete\n          stays:         2 tasks chi can't verify " \
                               "(task 3f9a2c1d, bbbb2222: task 0badf00d), left as it is — needs --stop-tasks\n")
    end

    it "counts a chain's workers and turns, and names another link's task by its id" do
      chain = { links: 3, worker: { idle: 1, turn: 1 }, delegates: { delete: [], leave: [] },
                tasks: { running: [{ session_id: "cccc3333-0000", id: "t-1", command: "tail -f log" }] } }
      plan = { chained: true, session_id: "aaaa1111-0000", position: 3, size: 3, link: { worker: "turn" }, chain: chain }

      expect(dry_run(plan, "--chain")).to eq(0)

      expect(out.string).to eq(<<~TEXT)
        aaaa1111  would delete its chain (3 links)
                  goes:          all 3 links
                  stopped first: 2 workers (1 running a turn); 1 background task (cccc3333: tail -f log) — needs --force, --stop-tasks
      TEXT
    end

    it "says a running turn for a link" do
      expect(dry_run({ chained: false, session_id: "aaaa1111-0000", link: { worker: "turn" } })).to eq(0)
      expect(out.string).to end_with("stopped first: its running turn — needs --force\n")
    end
  end

  describe "bin/chi sessions delete" do
    let(:chi) { File.expand_path("../bin/chi", __dir__) }
    let(:xdg_state) { Dir.mktmpdir("chi-sessions-delete") }
    let(:state_dir) { Samagotchi::Session.default_state_dir(env: { "XDG_STATE_HOME" => xdg_state }) }

    after { FileUtils.rm_rf(xdg_state) }

    def run_chi(*args)
      super("sessions", *args, env: { "XDG_STATE_HOME" => xdg_state })
    end

    it "keeps the order of the ids given when stdout and stderr share a pipe" do
      a, b = Array.new(2) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap { |s| s.save(state_dir: state_dir) }
      end

      output, _status = Open3.capture2e({ "XDG_STATE_HOME" => xdg_state }, RbConfig.ruby, chi, "sessions", "delete",
                                        a.id[0, 8], "nope1", b.id[0, 8], "nope2", stdin_data: "")

      expect(output.lines.map { |line| line[/deleted|nope\d/] }).to eq(%w[deleted nope1 deleted nope2])
    end

    it "deletes a session and lists delete in the help" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: state_dir)

      out, err, status = run_chi("delete", session.id[0, 8])

      expect(status.exitstatus).to eq(0), err
      expect(out).to start_with("#{session.id[0, 8]}  deleted")
      expect(File.exist?(File.join(state_dir, "#{session.id}.json"))).to be false
      expect(run_chi("--help").first).to include("delete [--force] ID...")
    end

    it "exits 2 with no ids" do
      _out, err, status = run_chi("delete")

      expect(status.exitstatus).to eq(2)
      expect(err).to include("give session ids")
    end
  end
end
