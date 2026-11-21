# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/session_continue"
require "samagotchi/session_retention"
require "samagotchi/schedules"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"
require "samagotchi/tools/task_runtime"
require "support/task_dirs"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

  describe ".delete_session" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let(:session_file) { File.join(tmpdir, "#{session.id}.json") }

    def fill_session_dir
      %w[input output notes images].each { |sub| FileUtils.mkdir_p(File.join(session_dir, sub)) }
      File.write(File.join(session_dir, "notes", "1.json"), "{}")
      File.write(File.join(session_dir, "images", "ab.png"), "png")
      File.write(File.join(session_dir, "output", "1.txt"), "answer")
    end

    def new_session_in(state_dir, test_run: false, model_name: "gemma4", working_directory: "/tmp")
      Samagotchi::Session.new_session(mode: "assist", model_name: model_name, working_directory: working_directory,
                                      test_run: test_run).tap { |s| s.save(state_dir: state_dir) }
    end

    def populate_session_stores(session, state_dir)
      session_dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
      FileUtils.mkdir_p(session_dir)
      File.write(File.join(session_dir, "store-marker"), session.id)
      plugin_state = File.join(Samagotchi::Paths.state_dir, "plugins", "check-in", "sessions", "#{session.id}.json")
      FileUtils.mkdir_p(File.dirname(plugin_state))
      File.write(plugin_state, "{}")
      context = Samagotchi::ContextSources.session_location(session.id, state_dir: state_dir)
      context.mute("pr-1")
      grants = Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir))
      issued = Samagotchi::Participants.invite(grants, session_id: session.id, name: "Sam", state_dir: state_dir)
      runs_store = Samagotchi::SystemOne::RunsStore.new(File.dirname(state_dir))
      runs = Samagotchi::SystemOne::Runs.new(store: runs_store)
      question = Samagotchi::SystemOne::Question.new(id: "allow", type: :noul, instructions: "Allow?")
      runs.record(id: "approvals.allow/#{SecureRandom.uuid}", judgment: "approvals.allow", questions: [question],
                  state: "git push", session_id: session.id)
      Samagotchi::ContextCandidatesLog.event("proposed", session_id: session.id, name: "candidate", state_dir: state_dir)
      { issued: issued, runs_store: runs_store }
    end

    def expect_session_stores_removed(session_id, state_dir, stores)
      roots = [state_dir, File.dirname(state_dir), Samagotchi::Paths.state_home, Samagotchi::Paths.config_home]
      named_paths = roots.uniq.flat_map do |root|
        Dir.glob(File.join(root, "**", "*"), File::FNM_DOTMATCH).reject do |path|
          %w[. ..].include?(File.basename(path))
        end.select { |path| path.include?(session_id) }
      end
      expect(named_paths).to be_empty
      expect(Samagotchi::Grants.new(Samagotchi::Grants.path(state_dir: state_dir)).lookup(stores[:issued].token)
        .state(Time.now)).to eq(:revoked)
      expect(stores[:runs_store].lines("approvals.allow").none? { |line| line["session_id"] == session_id }).to be(true)
      expect(Samagotchi::ContextCandidatesLog.log_for(state_dir).records.none? do |line|
        line["session_id"] == session_id
      end).to be(true)
    end

    it "removes the session file and its whole directory, and says what it removed" do
      fill_session_dir

      result = described_class.delete_session(session.id, state_dir: tmpdir)

      expect(result).to eq(id: session.id, removed: [session_file, session_dir], stopped: false)
      expect(File.exist?(session_file)).to be false
      expect(Dir.exist?(session_dir)).to be false
    end

    it "removes every populated per-session store through delete, retention and failed-continue cleanup" do
      deleted = new_session_in(tmpdir)
      deleted_stores = populate_session_stores(deleted, tmpdir)

      described_class.delete_session(deleted.id, state_dir: tmpdir)
      expect_session_stores_removed(deleted.id, tmpdir, deleted_stores)

      pruned = new_session_in(tmpdir, test_run: true)
      pruned_stores = populate_session_stores(pruned, tmpdir)
      Samagotchi::SessionRetention.apply(state_dir: tmpdir, days: 0, max_count: 0, any_age: true)
      expect_session_stores_removed(pruned.id, tmpdir, pruned_stores)

      previous = new_session_in(tmpdir, model_name: "main:gemma-small")
      failed_stores = nil
      failed_id = nil
      allow(Process).to receive(:spawn) do
        successor_id = Samagotchi::SessionChain.next_of(previous.id, state_dir: tmpdir)
        failed_id = successor_id
        failed_stores = populate_session_stores(Samagotchi::Session.load(successor_id, state_dir: tmpdir), tmpdir)
        raise Errno::EAGAIN
      end
      expect do
        Samagotchi::SessionContinue.run(previous.id, state_dir: tmpdir, recap_wait: 0, archive_wait: 0)
      end.to raise_error(Errno::EAGAIN)
      expect_session_stores_removed(failed_id, tmpdir, failed_stores)
    ensure
      FileUtils.rm_rf(File.join(Samagotchi::Paths.state_dir, "plugins"))
    end

    it "refuses to delete an enabled schedule target, even with stop" do
      schedule_state_dir = File.join(tmpdir, "scheduled-sessions")
      FileUtils.mkdir_p(schedule_state_dir)
      scheduled_session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      scheduled_session.save(state_dir: schedule_state_dir)
      schedule = Samagotchi::Schedules.new(state_dir: schedule_state_dir).add(
        target: scheduled_session.id, prompt: "Audit", recurrence: Samagotchi::Schedules.recurrence(every: "1h")
      )

      expect { described_class.delete_session(scheduled_session.id, state_dir: schedule_state_dir, stop: true) }
        .to raise_error(described_class::DeleteRefused) { |error|
          expect(error.reason).to eq(:scheduled)
          expect(error.message).to eq("this session is the target of an enabled schedule; " \
                                      "cancel it with chi schedule cancel #{schedule.id}")
        }
      expect(File.exist?(File.join(schedule_state_dir, "#{scheduled_session.id}.json"))).to be true
    end

    it "removes the plugins' state for the session (plugins/<bundle>/sessions/<id>.json or <id>/), not another's" do
      plugins = File.join(Samagotchi::Paths.state_dir, "plugins")
      own = File.join(plugins, "check-in", "sessions", "#{session.id}.json")
      own_dir = File.join(plugins, "other", "sessions", session.id)
      kept = File.join(plugins, "check-in", "sessions", "someone-else.json")
      [own, kept].each { |f| FileUtils.mkdir_p(File.dirname(f)) && File.write(f, "{}") }
      FileUtils.mkdir_p(own_dir)

      described_class.delete_session(session.id, state_dir: tmpdir)

      expect([File.exist?(own), Dir.exist?(own_dir), File.exist?(kept)]).to eq([false, false, true])
    ensure
      FileUtils.rm_rf(plugins)
    end

    it "removes the session's attached context (context/sessions/<id>/), not another's" do
      require "samagotchi/context_sources"
      own = Samagotchi::ContextSources.session_location(session.id, state_dir: tmpdir)
      other = Samagotchi::ContextSources.session_location("11111111-2222-3333-4444-555555555555", state_dir: tmpdir)
      [own, other].each { |loc| loc.mute("pr-1") }

      result = described_class.delete_session(session.id, state_dir: tmpdir)

      expect(result[:removed]).to include(own.dir)
      expect([Dir.exist?(own.dir), Dir.exist?(other.dir)]).to eq([false, true])
    ensure
      # The root is next to tmpdir, shared with other spec processes: only ours goes.
      [own, other].each { |loc| FileUtils.rm_rf(loc.dir) }
    end

    it "takes a unique id prefix" do
      result = described_class.delete_session(session.id[0, 6], state_dir: tmpdir)

      expect(result[:id]).to eq(session.id)
      expect(File.exist?(session_file)).to be false
    end

    it "refuses an ambiguous prefix and removes nothing" do
      now = Time.now.utc.iso8601
      Samagotchi::Session.new(id: "#{session.id[0, 4]}-other", mode: "assist", model_name: "gemma4",
                              working_directory: "/tmp", messages: [], created_at: now, updated_at: now)
                         .save(state_dir: tmpdir)

      expect { described_class.delete_session(session.id[0, 4], state_dir: tmpdir) }
        .to raise_error(Samagotchi::Session::AmbiguousId)
      expect(File.exist?(session_file)).to be true
    end

    it "refuses an unknown id, and one that is not an id" do
      FileUtils.mkdir_p(File.join(tmpdir, "keep"))

      expect { described_class.delete_session("nope", state_dir: tmpdir) }
        .to raise_error(ArgumentError, "no session nope")
      expect { described_class.delete_session("../#{File.basename(tmpdir)}", state_dir: tmpdir) }
        .to raise_error(ArgumentError, /no session/)
      expect { described_class.delete_session("", state_dir: tmpdir) }.to raise_error(ArgumentError)
      expect(Dir.exist?(File.join(tmpdir, "keep"))).to be true
    end

    it "refuses while a worker owns the session, and removes nothing" do
      fill_session_dir
      spawn_owner

      expect { described_class.delete_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:worker_running) }
      expect(File.exist?(session_file)).to be true
      expect(described_class.session_owner(session.id, state_dir: tmpdir)).not_to be_nil
    end

    # A worker being started holds no lock yet: the delete refuses it as
    # it refuses an owned one, rather than pull the files from under it.
    it "refuses while a worker is being started for it (the starting marker), and removes nothing" do
      fill_session_dir
      Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)

      expect { described_class.delete_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:worker_running) }
      expect(File.exist?(session_file)).to be true
    end

    it "with stop: stops a worker being started, waits for it, then deletes" do
      Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)
      # The worker takes the lock, sees the stop and leaves (Worker#start
      # clears the marker as it takes the session).
      allow(described_class).to receive(:stop_session).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { Samagotchi::StartingMarker.clear(session.id, state_dir: tmpdir) }
      end

      result = described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 5)

      expect(result).to include(id: session.id, stopped: true)
      expect(File.exist?(session_file)).to be false
    end

    it "with stop: removes nothing while the start outlives the wait" do
      Samagotchi::StartingMarker.mark(session.id, state_dir: tmpdir)

      expect { described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 0.2) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:still_stopping) }
      expect(File.exist?(session_file)).to be true
    end

    # H10: the deleter holds the owner lock while the files go, so a worker
    # can't take the session in the middle of it.
    it "holds the owner lock (kind deleting, which a stop never signals) while it removes the files" do
      fill_session_dir
      seen = nil
      allow(FileUtils).to receive(:rm_rf).and_wrap_original do |original, path, *rest|
        seen ||= Samagotchi::OwnerLock.owner(session_dir) if path == session_dir
        original.call(path, *rest)
      end

      described_class.delete_session(session.id, state_dir: tmpdir)

      expect(seen).to have_attributes(kind: "deleting", pid: Process.pid)
      expect(Dir.exist?(session_dir)).to be false
    end

    it "refuses, removing nothing, when a worker took the lock after its check" do
      fill_session_dir
      allow(Samagotchi::OwnerLock).to receive(:acquire).and_call_original
      allow(Samagotchi::OwnerLock).to receive(:acquire)
        .with(session_dir, kind: "deleting", wait: Samagotchi::OwnerLock::PROBE_WAIT).and_return(nil)

      expect { described_class.delete_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:worker_running) }
      expect(File.exist?(session_file)).to be true
    end

    it "with stop: stops the worker first, then deletes" do
      fill_session_dir
      spawn_owner

      result = described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 5)

      expect(result).to include(id: session.id, stopped: true)
      expect(File.exist?(session_file)).to be false
      expect(Dir.exist?(session_dir)).to be false
    end

    it "with stop: removes nothing when the worker outlives the wait" do
      spawn_owner(ignore_term: true)

      expect { described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 0.3) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.reason).to eq(:still_stopping) }
      expect(Dir.exist?(session_dir)).to be true
      expect(File.exist?(session_file)).to be true
    end

    it "refuses a session a one-turn chi run owns, even with stop:" do
      lock = Samagotchi::OwnerLock.acquire(session_dir, kind: "tui")
      allow(Process).to receive(:kill)

      expect { described_class.delete_session(session.id, state_dir: tmpdir, stop: true) }
        .to raise_error(described_class::OwnedByTUI)
      expect(Process).not_to have_received(:kill)
      expect(File.exist?(session_file)).to be true
    ensure
      lock&.release
    end

    it "removes a directory left without its session file" do
      FileUtils.mkdir_p(session_dir)
      FileUtils.rm_f(session_file)

      expect(described_class.delete_session(session.id, state_dir: tmpdir)[:removed]).to eq([session_dir])
    end

    # The automatic deletes (scratch, the empty-session discard, the
    # failed-continue rollback, the prune) pass neither keyword: only a
    # user's delete takes stopped delegates (SessionManager::DELEGATES).
    it "leaves a stopped delegate without the user's keywords, and takes it with them" do
      child = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp",
                                              parent_id: session.id).tap { |s| s.save(state_dir: tmpdir) }
      other = new_session_in(tmpdir)
      other_child = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp",
                                                    parent_id: other.id).tap { |s| s.save(state_dir: tmpdir) }

      described_class.delete_session(session.id, state_dir: tmpdir)
      user = described_class.delete_session(other.id, state_dir: tmpdir, revive_previous: true, refuse_continuing: true)

      expect(Samagotchi::Session.exist?(child.id, state_dir: tmpdir)).to be(true)
      expect(user[:deleted]).to eq([other_child.id, other.id])
      expect(Samagotchi::Session.exist?(other_child.id, state_dir: tmpdir)).to be(false)
    end
  end

  describe ".delete_ids and .delete_tree_ids" do
    def saved(parent: nil)
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp",
                                      parent_id: parent&.id).tap { |s| s.save(state_dir: tmpdir) }
    end

    def file?(session) = File.exist?(Samagotchi::Session.session_file(session.id, state_dir: tmpdir))

    it "orders a tree deepest first, the id last" do
      link = saved
      child = saved(parent: link)
      grandchild = saved(parent: child)

      expect(described_class.delete_tree_ids(link.id, tmpdir)).to eq([grandchild.id, child.id, link.id])
      expect(described_class.delete_tree_ids(grandchild.id, tmpdir)).to eq([grandchild.id])
    end

    it "deletes the ids in order and purges the session logs once for the batch" do
      link = saved
      child = saved(parent: link)
      ids = described_class.delete_tree_ids(link.id, tmpdir)
      expect(Samagotchi::SystemOne::Runs).to receive(:purge_sessions).once.with(ids, sessions_dir: tmpdir)
      expect(Samagotchi::ContextCandidatesLog).to receive(:purge_sessions).once.with(ids, state_dir: tmpdir)

      results = described_class.delete_ids(ids, state_dir: tmpdir)

      expect(results.map { |r| r[:id] }).to eq([child.id, link.id])
      expect([file?(link), file?(child)]).to eq([false, false])
    end

    it "stops at the first refusal, keeping the rest, and still purges the ids it deleted" do
      first = saved
      held = saved
      last = saved
      Samagotchi::StartingMarker.mark(held.id, state_dir: tmpdir)
      expect(Samagotchi::SystemOne::Runs).to receive(:purge_sessions).once.with([first.id], sessions_dir: tmpdir)

      expect { described_class.delete_ids([first.id, held.id, last.id], state_dir: tmpdir) }
        .to raise_error(described_class::DeleteRefused) { |e| expect(e.session_id).to eq(held.id) }
      expect([file?(first), file?(held), file?(last)]).to eq([false, true, true])
    end
  end

  # The background tasks a deleted or archived session started
  # (RunningTasks): asked about, or stopped, or left (IGNORE).
  describe "running background tasks" do
    include TaskDirs

    let(:runtime) { Samagotchi::Tools::TaskRuntime }
    let(:policies) { described_class::RunningTasks::Policy }

    around { |example| with_task_dir { |root| @root = root and example.run } }

    before { @spawned = [] }

    after do
      @spawned.each do |pid|
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH, Errno::EPERM
        nil
      ensure
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
          nil
        end
      end
    end

    def task_session(parent: nil)
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: @root,
                                      parent_id: parent&.id).tap { |s| s.save(state_dir: tmpdir) }
    end

    # A task the session started (its id in a tool_response, as task_create's result has it).
    def started(session, record)
      session.messages << { role: "tool_response", content: "[task_create]\ntask_id: #{record.id}" }
      session.save(state_dir: tmpdir)
      record
    end

    def start_task(session, command = "sleep 30")
      record, error = runtime.create_task(command)
      raise error if error

      started(session, record)
    end

    # A record written by hand: +pid+, no pid_started unless given.
    def hand_record(session, pid:, pid_started: nil, command: "sleep 40")
      data = { "id" => runtime.generate_task_id, "command" => command, "status" => "running", "pid" => pid,
               "pid_started" => pid_started, "created_at" => "2026-10-01T00:00:00Z",
               "exit_code_path" => File.join(@root, "no-exit-code") }
      record = Samagotchi::Tools::TaskRecord.from_file(data)
      runtime.write_record(record)
      started(session, record)
    end

    # A group leader this spec started, recorded for the cleanup.
    def group_leader
      Process.spawn("sleep", "31.81", pgroup: true).tap { |pid| @spawned << pid }
    end

    def gone?(session) = !File.exist?(Samagotchi::Session.session_file(session.id, state_dir: tmpdir))
    def status_of(record) = runtime.load_record(record.id)&.status

    it "deletes a session with no running task as before" do
      session = task_session
      done, = runtime.create_task("true")
      started(session, done)
      wait_for("the task to finish") { !runtime.get_record(done.id).first.running? }

      result = described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policies::REFUSE)

      expect(result.keys).to eq(%i[id removed stopped])
      expect(gone?(session)).to be(true)
    end

    it "refuses with REFUSE while a task runs, naming it, and changes nothing" do
      session = task_session
      record = start_task(session, "sleep 30.11")

      expect { described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policies::REFUSE) }
        .to raise_error(described_class::DeleteRefused) { |e|
          expect(e.reason).to eq(:tasks_running)
          expect(e.tasks.running.map(&:id)).to eq([record.id])
          expect(e.worker_stopped).to be(false)
          expect(e.message).to eq("background tasks it started are still running: sleep 30.11")
        }
      expect(gone?(session)).to be(false)
      expect(Samagotchi::ProcessGroup.alive?(record.pid)).to be(true)
    end

    it "leaves the task running with IGNORE (today's delete)" do
      session = task_session
      record = start_task(session)

      described_class.delete_session(session.id, state_dir: tmpdir)

      expect(gone?(session)).to be(true)
      expect(Samagotchi::ProcessGroup.alive?(record.pid)).to be(true)
    end

    it "stops the task with a stop, then deletes, and the result names it" do
      session = task_session
      record = start_task(session)
      policy = policies.stop(by: "user")

      result = described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policy)

      expect(gone?(session)).to be(true)
      expect(runtime.load_record(record.id)).to have_attributes(status: "stopped", stop_reason: "stopped_by_user")
      expect(result[:tasks_stopped].map(&:id)).to eq([record.id])
      expect(result).to include(tasks_not_stopped: [], tasks_ended: [])
    end

    it "lists no record whose pid is gone (a crashed worker's leftover record)" do
      session = task_session
      pid = Process.spawn("true", pgroup: true)
      Process.wait(pid)
      hand_record(session, pid: pid, pid_started: "Thu Jan  1 00:00:00 2026")

      expect(described_class::RunningTasks.of([session.id], state_dir: tmpdir)).to be_empty
      described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policies::REFUSE)
      expect(gone?(session)).to be(true)
    end

    it "lists a record with no start time whose pid leads a group as unverified, and never signals it" do
      session = task_session
      pid = group_leader
      record = hand_record(session, pid: pid)
      listing = described_class::RunningTasks.of([session.id], state_dir: tmpdir)
      expect(listing.unverified.map(&:id)).to eq([record.id])
      expect { described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policies::REFUSE) }
        .to raise_error(described_class::DeleteRefused, /task #{record.id[-8..]} \(may still be running\)/)

      result = described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policies.stop(by: "user"))

      expect(gone?(session)).to be(true)
      expect(Process.wait2(pid, Process::WNOHANG)).to be_nil
      expect(result[:tasks_not_stopped].map(&:id)).to eq([record.id])
      expect(result[:tasks_stopped]).to eq([])
    end

    it "refuses on an unreadable record, and a stop deletes and reports it not stopped" do
      session = task_session
      id = runtime.generate_task_id
      FileUtils.mkdir_p(File.join(@root, "tmp", "tasks", id))
      File.write(File.join(@root, "tmp", "tasks", id, "task.json"), "{not json")
      started(session, Samagotchi::Tools::TaskRecord.from_file("id" => id))
      allow(Samagotchi::Log).to receive(:warn).and_call_original

      expect { described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policies::REFUSE) }
        .to raise_error(described_class::DeleteRefused, /task #{id[-8..]} \(record unreadable\)/)
      expect(Samagotchi::Log).to have_received(:warn)
        .with(:worker, "session_task_check_failed", hash_including(sid: session.id, task_id: id)).at_least(:once)

      result = described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policies.stop(by: "user"))
      expect(gone?(session)).to be(true)
      expect(result[:tasks_not_stopped].map(&:id)).to eq([id])
    end

    it "deletes a folder whose session file is gone under REFUSE" do
      session = task_session
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      FileUtils.mkdir_p(dir)
      FileUtils.rm_f(Samagotchi::Session.session_file(session.id, state_dir: tmpdir))

      result = described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policies::REFUSE)

      expect(result[:removed]).to eq([dir])
    end

    it "keeps the deleting lock through the stop: a worker can't take the session meanwhile" do
      session = task_session
      record = start_task(session)
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      FileUtils.mkdir_p(dir)
      taken = :not_tried
      allow(described_class::RunningTasks).to receive(:stop!).and_wrap_original do |original, *args, **kwargs|
        taken = Samagotchi::OwnerLock.acquire(dir, kind: "worker", wait: 0)
        original.call(*args, **kwargs)
      end

      described_class.delete_session(session.id, state_dir: tmpdir, running_tasks: policies.stop(by: "user"))

      expect(taken).to be_nil
      expect(gone?(session)).to be(true)
      expect(status_of(record)).to eq("stopped")
    end

    it "refuses a task started since the check, under the lock, with the worker stopped" do
      session = task_session
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      FileUtils.mkdir_p(dir)
      spawn_owner_for(dir)
      allow(described_class).to receive(:stop_session).and_wrap_original do |original, *args, **kwargs|
        start_task(session, "sleep 30.12")
        original.call(*args, **kwargs)
      end

      expect do
        described_class.delete_session(session.id, state_dir: tmpdir, stop: true, wait: 5, running_tasks: policies::REFUSE)
      end.to raise_error(described_class::DeleteRefused) { |e|
        expect(e).to have_attributes(reason: :tasks_running, worker_stopped: true)
        expect(e.message).to end_with("sleep 30.12; its worker was stopped")
      }
      expect(File.exist?(Samagotchi::Session.session_file(session.id, state_dir: tmpdir))).to be(true)
      expect(Dir.exist?(dir)).to be(true)
    end

    it "refuses a plain delete up front on a task the stop wasn't given, before its worker is stopped" do
      session = task_session
      named = start_task(session, "sleep 30.45")
      start_task(session, "sleep 30.46")
      allow(described_class).to receive(:release_for_delete!).and_call_original

      expect do
        described_class.delete_resolved(session.id, state_dir: tmpdir, stop: true,
                                                    running_tasks: policies.stop(by: "user", only: [named.id]))
      end.to raise_error(described_class::DeleteRefused) { |e| expect(e).to have_attributes(reason: :tasks_running, worker_stopped: false) }
      expect(described_class).not_to have_received(:release_for_delete!)
      expect(gone?(session)).to be(false)
      expect(status_of(named)).to eq("running")
    end

    it "refuses a plain delete on a task the stop wasn't given, under the lock, with the worker stopped" do
      session = task_session
      named = start_task(session, "sleep 30.43")
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      FileUtils.mkdir_p(dir)
      spawn_owner_for(dir)
      allow(described_class).to receive(:stop_session).and_wrap_original do |original, *args, **kwargs|
        start_task(session, "sleep 30.44")
        original.call(*args, **kwargs)
      end

      expect do
        described_class.delete_resolved(session.id, state_dir: tmpdir, stop: true, wait: 5,
                                                    running_tasks: policies.stop(by: "user", only: [named.id]))
      end.to raise_error(described_class::DeleteRefused) { |e|
        expect(e).to have_attributes(reason: :tasks_running, worker_stopped: true)
      }
      expect(Dir.exist?(dir)).to be(true)
      expect(status_of(named)).to eq("running")
    end

    it "names every worker an archive stopped before its last check refused" do
      listing = described_class::RunningTasks::Listing.new(
        running: [described_class::RunningTasks::RunningTask.new(session_id: "dddd1111-0", id: "t-1", command: "rspec")]
      )
      refusal = described_class::ArchiveRefused.new("dddd1111-0", :tasks_running, tasks: listing, worker_stopped: true,
                                                                                 stopped_workers: %w[dddd1111-0 eeee2222-0])

      expect(refusal.message).to end_with("rspec; 2 workers were stopped: its own, eeee2222")
      one = described_class::ArchiveRefused.new("dddd1111-0", :tasks_running, tasks: listing, worker_stopped: true,
                                                                             stopped_workers: %w[dddd1111-0])
      expect(one.message).to end_with("rspec; its worker was stopped")
    end

    it "names whose worker was stopped: the refused session's own, or the one the op stopped" do
      listing = described_class::RunningTasks::Listing.new(
        running: [described_class::RunningTasks::RunningTask.new(session_id: "dddd1111-0", id: "t-1", command: "rspec")]
      )
      refusal = described_class::DeleteRefused.new("dddd1111-0", :tasks_running, tasks: listing)

      expect(refusal.with_worker_stopped.message).to end_with("rspec; its worker was stopped")
      by_link = refusal.with_worker_stopped("bbbb2222-0")
      expect(by_link.message).to end_with("rspec; bbbb2222's worker was stopped")
      expect([by_link.worker_stopped, by_link.stopped_worker]).to eq([true, "bbbb2222-0"])
    end

    def spawn_owner_for(dir)
      @owner_pid = spawn_lock_holder(dir)
    end

    describe "archive" do
      it "refuses for a delegate's task, naming the delegate, and changes nothing" do
        session = task_session
        child = task_session(parent: session)
        start_task(child, "rspec spec/foo_spec.rb")

        expect { described_class.archive_session(session.id, state_dir: tmpdir, running_tasks: policies::REFUSE) }
          .to raise_error(described_class::ArchiveRefused) { |e|
            expect(e.reason).to eq(:tasks_running)
            expect(e.message).to eq("its delegate #{child.id[0, 8]}'s background tasks are still running: rspec spec/foo_spec.rb")
          }
        expect(Samagotchi::ArchiveStore.archived?(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir))).to be(false)
      end

      it "with a stop given the named tasks: stops them and archives; refuses on another up front, archiving nothing" do
        session = task_session
        child = task_session(parent: session)
        named = start_task(session, "sleep 30.41")
        unnamed = start_task(child, "sleep 30.42")
        dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
        FileUtils.mkdir_p(dir)
        spawn_owner_for(dir)
        allow(described_class).to receive(:stop_session).and_call_original

        expect do
          described_class.archive_session(session.id, state_dir: tmpdir, running_tasks: policies.stop(by: "user", only: [named.id]))
        end.to raise_error(described_class::ArchiveRefused) { |e|
          expect(e.reason).to eq(:tasks_running)
          expect(e.tasks.running.map(&:id)).to contain_exactly(named.id, unnamed.id)
        }
        expect(described_class).not_to have_received(:stop_session)
        expect(described_class.session_owner(session.id, state_dir: tmpdir)).not_to be_nil
        expect(Samagotchi::ArchiveStore.archived?(dir)).to be(false)
        expect([status_of(named), status_of(unnamed)]).to eq(%w[running running])

        result = described_class.archive_session(session.id, state_dir: tmpdir,
                                                             running_tasks: policies.stop(by: "user", only: [named.id, unnamed.id]))
        expect(result.archived).to contain_exactly(session.id, child.id)
        expect([status_of(named), status_of(unnamed)]).to eq(%w[stopped stopped])
      end

      it "with a stop: waits for the worker to let go, stops the tasks, then archives" do
        session = task_session
        record = start_task(session)
        dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
        FileUtils.mkdir_p(dir)
        spawn_owner_for(dir)
        owner_seen = :unread
        allow(described_class::RunningTasks).to receive(:stop!).and_wrap_original do |original, *args, **kwargs|
          owner_seen = described_class.session_owner(session.id, state_dir: tmpdir)
          original.call(*args, **kwargs)
        end

        result = described_class.archive_session(session.id, state_dir: tmpdir, running_tasks: policies.stop(by: "user"))

        expect(owner_seen).to be_nil
        expect(result.tasks_stopped.map(&:id)).to eq([record.id])
        expect(result.archived).to eq([session.id])
        expect(status_of(record)).to eq("stopped")
      end
    end
  end
end
