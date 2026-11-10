# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/engine"
require "samagotchi/session_manager"
require "samagotchi/bridge"
require "samagotchi/reminder_store"
require_relative "../support/session_manager_context"

RSpec.describe Samagotchi::SessionManager do
  include_context "session manager files"

  describe ".stop_session" do
    it "marks a session as stopped even when pid file does not exist" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)

      described_class.stop_session(session.id, state_dir: tmpdir)
      loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
      expect(loaded.status).to eq(Samagotchi::Session::STATUS_STOPPED)
    end

    # A delete holds owner.lock as kind deleting (the deleter: chi web, the
    # CLI) while the files go: a stop at that moment signals nobody.
    it "signals no deleter holding the lock" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      lock = Samagotchi::OwnerLock.acquire(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), kind: "deleting")
      allow(Process).to receive(:kill)

      described_class.stop_session(session.id, state_dir: tmpdir)

      expect(Process).not_to have_received(:kill).with("TERM", Process.pid)
      expect(Process).not_to have_received(:kill).with("CONT", Process.pid)
    ensure
      lock&.release
    end

    it "removes a restart's reminders hand-off, so a later resume doesn't bring them back" do
      session = Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
      session.save(state_dir: tmpdir)
      dir = Samagotchi::Session.session_dir(session.id, state_dir: tmpdir)
      FileUtils.mkdir_p(dir)
      carry = File.join(dir, Samagotchi::ReminderCarry::FILE)
      File.write(carry, "{}")

      described_class.stop_session(session.id, state_dir: tmpdir)
      expect(File.exist?(carry)).to be(false)
    end

    context "with wait:" do
      let(:session) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
          s.save(state_dir: tmpdir)
        end
      end
      let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }

      it "returns true once the owner has let go of the session" do
        spawn_owner

        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 5)).to be true
        expect(described_class.session_owner(session.id, state_dir: tmpdir)).to be_nil
      end

      it "returns false when the owner outlives the wait" do
        spawn_owner(ignore_term: true)

        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 0.3)).to be false
        expect(described_class.session_owner(session.id, state_dir: tmpdir)).not_to be_nil
      end

      it "stops a stopped (SIGSTOPped) owner with its TERM, within the wait, and not by outliving it" do
        spawn_owner
        Process.kill("STOP", @owner_pid)
        wait_for("the owner to be stopped") { Samagotchi::ProcessGroup.stopped?(@owner_pid) }
        started = SpecWaiting.mono

        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 5)).to be true
        expect(SpecWaiting.mono - started).to be < time_bound(2.5, below: 5)
        expect(Process.wait2(@owner_pid).last.termsig).to eq(Signal.list["TERM"])
        @owner_pid = nil
      end

      it "returns true at once when nothing owns the session" do
        expect(described_class.stop_session(session.id, state_dir: tmpdir, wait: 5)).to be true
      end
    end

    context "mid-turn" do
      let(:session) do
        Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp").tap do |s|
          s.status = Samagotchi::Session::STATUS_RUNNING
          s.save(state_dir: tmpdir)
        end
      end
      let(:bridge) { instance_double(Samagotchi::BridgeClient) }
      let(:calls) { [] }

      before do
        allow(Samagotchi::WorkerLink).to receive(:client).and_return(bridge)
        allow(Process).to receive(:kill).and_call_original
      end

      it "cancels the running turn first, so its prompt is saved as a Cancel saves it, then stops" do
        allow(bridge).to receive(:cancel) do |reason:|
          calls << [:cancel, reason, Samagotchi::Session.load(session.id, state_dir: tmpdir).status]
          # The worker's Engine ends the turn and saves the session.
          @saver = Thread.new do
            sleep 0.2 # sleep-ok: the save comes a moment after the cancel (the stop waits for it)
            loaded = Samagotchi::Session.load(session.id, state_dir: tmpdir)
            loaded.status = Samagotchi::Session::STATUS_IDLE
            loaded.save(state_dir: tmpdir)
          end
          Samagotchi::BridgeClient::Response.new(status: 202, body: nil)
        end

        described_class.stop_session(session.id, state_dir: tmpdir, wait: 1)
        join!(@saver, "the worker's save")

        expect(calls).to eq([[:cancel, "session_stopped", Samagotchi::Session::STATUS_RUNNING]])
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq(Samagotchi::Session::STATUS_STOPPED)
      end

      it "stops at once when there is no turn to cancel" do
        allow(bridge).to receive(:cancel).and_return(Samagotchi::BridgeClient::Response.new(status: 409, body: nil))

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        described_class.stop_session(session.id, state_dir: tmpdir, wait: 5)

        # Not the 3 s cancel wait (STOP_CANCEL_WAIT), nor the 5 s one for the owner.
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < time_bound(2.5, below: described_class::STOP_CANCEL_WAIT)
        expect(Samagotchi::Session.load(session.id, state_dir: tmpdir).status).to eq(Samagotchi::Session::STATUS_STOPPED)
      end
    end
  end

  describe Samagotchi::SessionManager::RestartRefused do
    it "spells the stop hint for the invocation's machine" do
      via = Samagotchi::ChiInvocation.new(remote: "studio")

      words = described_class.words("s-1234", :fallback_held, nil, [:turn_running], via: via)

      expect(words).to include("run `#{via.command("sessions stop s-1234")}`, then any prompt")
    end
  end

  describe ".restart_session" do
    let(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: "/tmp")
                         .tap { |s| s.save(state_dir: tmpdir) }
    end
    let(:worker) { Samagotchi::OwnerLock::Owner.new(kind: "worker", pid: 1, started_at: nil) }
    let(:old_sidecar) do
      Samagotchi::WorkerSidecar.new(port: 4100, started_at: "t1", version: "0.18.1", features: ["restart"], secret: "5e" * 32)
    end
    let(:client) { instance_double(Samagotchi::BridgeClient) }

    def response(status, body)
      Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(body))
    end

    before do
      allow(described_class).to receive(:session_owner).and_return(worker)
      # The worker's secret goes with its port, from the same sidecar.
      allow(Samagotchi::BridgeClient).to receive(:new).with(hash_including(session_id: session.id, port: 4100, secret: "5e" * 32,
                                                                           host: "127.0.0.1", read_timeout: 30)).and_return(client)
    end

    it "asks the worker for a restart and waits for its successor's Bridge" do
      fresh = old_sidecar.with(port: 4200, started_at: "t2", version: "0.19.0")
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar), live_link(old_sidecar), none_link, live_link(fresh))
      allow(client).to receive(:request_exit).and_return(response(200, status: "restarting"))

      result = described_class.restart_session(session.id, state_dir: tmpdir, wait: 2, client_id: "web:restart")

      expect(client).to have_received(:request_exit).with(client_id: "web:restart", restart: true)
      expect(result.to_h).to eq(session_id: session.id, from_version: "0.18.1", version: "0.19.0")
    end

    it "falls back to TERM and resume when the live Bridge refuses connections, without a stop marker" do
      fresh = old_sidecar.with(port: 4200, started_at: "t2", version: "0.19.0")
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)
      allow(Process).to receive(:kill)
      allow(described_class).to receive(:wait_for_owner_release).and_return(true)
      allow(described_class).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(fresh))

      result = described_class.restart_session(session.id, state_dir: tmpdir, wait: 0.1)

      expect(result.to_h).to eq(session_id: session.id, from_version: "0.18.1", version: "0.19.0")
      expect(Process).to have_received(:kill).with("TERM", worker.pid)
      expect(described_class).to have_received(:resume_session).with(session.id, state_dir: tmpdir)
      expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)).to be(false)
    end

    it "falls back when the live Bridge refuses the secret" do
      fresh = old_sidecar.with(port: 4200, epoch: "e2", started_at: "t2", version: "0.19.0")
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_return(
        response(403, error: "bridge_secret", detail: Samagotchi::BridgeSecret.refused(session.id))
      )
      allow(Process).to receive(:kill)
      allow(described_class).to receive(:wait_for_owner_release).and_return(true)
      allow(described_class).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(fresh))

      result = described_class.restart_session(session.id, state_dir: tmpdir, wait: 0.1)

      expect(result.to_h).to eq(session_id: session.id, from_version: "0.18.1", version: "0.19.0")
      expect(Process).to have_received(:kill).with("TERM", worker.pid)
      expect(described_class).to have_received(:resume_session).with(session.id, state_dir: tmpdir)
      expect(Samagotchi::Session.stopped_marker?(session.id, state_dir: tmpdir)).to be(false)
    end

    it "falls back for Skew and stuck Starting links, but refuses an ordinary Starting link" do
      skew = Samagotchi::WorkerLink::Skew.new(sidecar: old_sidecar.with(protocol: 2), owner: worker, reason: :protocol)
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(skew)
      allow(Process).to receive(:kill)
      allow(described_class).to receive(:wait_for_owner_release).and_return(true)
      allow(described_class).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)

      expect(described_class.restart_session(session.id, state_dir: tmpdir, wait: 0)).to have_attributes(from_version: "0.18.1")
      expect(Process).to have_received(:kill).with("TERM", worker.pid).once

      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(Samagotchi::WorkerLink::Starting.new(owner: worker, stuck: true))
      expect(described_class.restart_session(session.id, state_dir: tmpdir, wait: 0)).to have_attributes(from_version: nil)
      expect(Process).to have_received(:kill).with("TERM", worker.pid).twice

      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(Samagotchi::WorkerLink::Starting.new(owner: worker))
      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused, "not now: its worker is still starting") { |error|
          expect(error.reason).to eq(:starting)
        }
      expect(Process).to have_received(:kill).twice
    end

    it "gives no version when the successor didn't come up within the wait" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_return(response(200, status: "restarting"))

      expect(described_class.restart_session(session.id, state_dir: tmpdir, wait: 0.2).version).to be_nil
    end

    it "is refused with the worker's reason" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_return(response(409, status: "held", reason: "reminders"))
      expect(Process).not_to receive(:kill)

      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused, "not now: it has reminders, which its worker's older chi can't carry over a restart") { |e|
          expect(e.reason).to eq(:reminders)
        }
    end

    it "is refused, not reported restarted, when the worker already leaves as a plain exit" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_return(response(409, status: "held", reason: "leaving_exit"))
      expect(Process).not_to receive(:kill)

      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused, "not now: the worker is already leaving as a plain exit") { |e|
          expect(e.reason).to eq(:leaving_exit)
        }
    end

    it "refuses the fallback when disk shows a running turn, question, queued input or running task" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)
      allow(Process).to receive(:kill)
      cases = {
        turn_running: -> { session.status = Samagotchi::Session::STATUS_RUNNING },
        question_pending: -> { session.pending_question = { id: "q1", kind: "approval", question: "Run it?" } },
        input_queued: lambda do
          Samagotchi::SessionInbox.write_input(Samagotchi::Session.session_dir(session.id, state_dir: tmpdir), prompt: "queued")
        end,
        background_tasks: lambda do
          task_id = "20261027123456-abcdef01"
          session.working_directory = tmpdir
          session.messages = [{ role: "tool_response", content: "[task_create]\ntask_id: #{task_id}" }]
          task_dir = File.join(tmpdir, Samagotchi::Tools::TaskRuntime::TASKS_DIR, task_id)
          FileUtils.mkdir_p(task_dir)
          File.write(File.join(task_dir, Samagotchi::Tools::TaskRuntime::METADATA_FILENAME), JSON.generate(status: "running"))
        end
      }

      cases.each do |reason, setup|
        session.status = Samagotchi::Session::STATUS_IDLE
        session.pending_question = nil
        session.messages = []
        setup.call
        session.save(state_dir: tmpdir)

        expect { described_class.restart_session(session.id, state_dir: tmpdir) }
          .to raise_error(described_class::RestartRefused) { |error|
            expect(error.reason).to eq(:fallback_held), reason.to_s
            expect(error.holds).to include(reason), reason.to_s
            expect(error.message).to include("`chi sessions stop #{session.id}`, then any prompt"), reason.to_s
          }
      end
      expect(Process).not_to have_received(:kill)
    end

    it "waits FALLBACK_STOP_WAIT for the TERMed owner, long enough for its recap on leave" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)
      allow(Process).to receive(:kill)
      allow(described_class).to receive(:wait_for_owner_release).and_return(true)
      allow(described_class).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)

      described_class.restart_session(session.id, state_dir: tmpdir, wait: 0)

      expect(described_class).to have_received(:wait_for_owner_release)
        .with(session.id, timeout: described_class::FALLBACK_STOP_WAIT, state_dir: tmpdir)
      expect(described_class::FALLBACK_STOP_WAIT).to be >= Samagotchi::SessionManager::STOP_WAIT + 30
    end

    it "leaves a successor that took the lock while the ask timed out: no TERM, no resume" do
      successor = Samagotchi::OwnerLock::Owner.new(kind: "worker", pid: 2, started_at: "t2")
      fresh = old_sidecar.with(port: 4200, started_at: "t2", version: "0.19.0")
      allow(described_class).to receive(:session_owner).and_return(worker, successor)
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_raise(Errno::ETIMEDOUT)
      allow(Process).to receive(:kill)
      allow(described_class).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(live_link(fresh))

      result = described_class.restart_session(session.id, state_dir: tmpdir, wait: 0.1)

      expect(result.version).to eq("0.19.0")
      expect(Process).not_to have_received(:kill)
      expect(described_class).not_to have_received(:resume_session)
    end

    it "resumes without a TERM when the owner already let go" do
      allow(described_class).to receive(:session_owner).and_return(worker, nil)
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)
      allow(Process).to receive(:kill)
      allow(described_class).to receive(:resume_session)
      allow(Samagotchi::WorkerLink).to receive(:await).and_return(none_link)

      described_class.restart_session(session.id, state_dir: tmpdir, wait: 0)

      expect(Process).not_to have_received(:kill)
      expect(described_class).to have_received(:resume_session).with(session.id, state_dir: tmpdir)
    end

    it "reports a failed fallback when the owner does not release, without resuming" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)
      allow(Process).to receive(:kill)
      allow(described_class).to receive(:wait_for_owner_release).and_return(false)
      allow(described_class).to receive(:resume_session)

      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused) { |error| expect(error.reason).to eq(:failed) }
      expect(described_class).not_to have_received(:resume_session)
    end

    it "refuses a stopped worker before asking it or TERMing it" do
      allow(Samagotchi::ProcessGroup).to receive(:stopped?).with(worker.pid).and_return(true)
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar))
      allow(client).to receive(:request_exit)
      allow(Process).to receive(:kill)

      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused) { |error|
          expect(error.reason).to eq(:stopped)
          expect(error.pid).to eq(worker.pid)
          expect(error.message).to include("is stopped (SIGSTOP or Ctrl-Z)", "`kill -CONT #{worker.pid}`")
        }
      expect(client).not_to have_received(:request_exit)
      expect(Process).not_to have_received(:kill)
    end

    it "is refused for a worker from before restarts, which it never asks" do
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_return(live_link(old_sidecar.with(features: [])))
      allow(client).to receive(:request_exit)

      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused, /runs chi 0.18.1, which can't restart: chi sessions stop/)
      expect(client).not_to have_received(:request_exit)
    end

    it "is refused with no live worker, and raises OwnedByTUI for a one-shot's session" do
      allow(described_class).to receive(:session_owner).and_return(nil)
      expect { described_class.restart_session(session.id, state_dir: tmpdir) }
        .to raise_error(described_class::RestartRefused) { |e| expect(e.reason).to eq(:not_running) }

      allow(described_class).to receive(:session_owner).and_return(Samagotchi::OwnerLock::Owner.new(kind: "tui", pid: 1, started_at: nil))
      expect { described_class.restart_session(session.id, state_dir: tmpdir) }.to raise_error(described_class::OwnedByTUI)
    end
  end
end
