# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "net/http"
require "json"

require "samagotchi/engine"
require "samagotchi/bridge"
require "samagotchi/worker"

RSpec.describe Samagotchi::Worker do
  def mono
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def wait_until(timeout: 2)
    deadline = mono + timeout
    sleep(0.01) until yield || mono > deadline
    yield
  end

  describe Samagotchi::Worker::Waker do
    let(:waker) { described_class.new }

    it "returns at once when woken, and false after the timeout when not" do
      waker.wake
      expect(waker.wait(5)).to be(true)

      started = mono
      expect(waker.wait(0.05)).to be(false)
      expect(mono - started).to be >= 0.05
    end

    it "drains every wake at once, so the loop doesn't spin" do
      3.times { waker.wake }
      expect(waker.wait(1)).to be(true)
      expect(waker.wait(0.05)).to be(false)
    end

    it "keeps a wake that comes after the drain" do
      waker.wake
      waker.wait(1)
      waker.wake
      expect(waker.wait(0.05)).to be(true)
    end

    it "wakes a waiting thread" do
      woken = Thread.new { waker.wait(5) }
      sleep(0.05)
      started = mono
      waker.wake
      expect(woken.value).to be(true)
      expect(mono - started).to be < 0.3
    end
  end

  describe "#run" do
    around do |example|
      original_model = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
      WebMock.allow_net_connect! if defined?(WebMock)
      example.run
    ensure
      WebMock.disable_net_connect! if defined?(WebMock)
      ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original_model
    end

    let(:tmpdir) { Dir.mktmpdir("worker-spec") }
    let!(:session) do
      Samagotchi::Session.new_session(mode: "assist", model_name: "Gemma-4B-it", working_directory: tmpdir).tap do |s|
        s.save(state_dir: tmpdir)
      end
    end
    let(:session_dir) { Samagotchi::Session.session_dir(session.id, state_dir: tmpdir) }
    let!(:engine) do
      Samagotchi::Engine.new(mode: :assist, client: instance_double(Samagotchi::Client),
                             kernel: instance_double(Samagotchi::KernelLoop))
    end
    let(:turns) { Queue.new }
    let(:result) { instance_double(Samagotchi::KernelLoop::Result, output: "") }

    before do
      FileUtils.mkdir_p(File.join(session_dir, Samagotchi::SessionManager::INPUT_DIR))
      allow(Samagotchi::Engine).to receive(:new) do |**kwargs|
        @reminder_callback = kwargs.dig(:reminders, :callback)
        engine
      end
      allow(engine).to receive(:start_idle)
      allow(engine).to receive(:stop_idle)
      allow(engine).to receive(:run_turn) do |_session, prompt, **|
        turns << [prompt, mono]
        result
      end
    end

    after do
      @thread&.kill
      begin
        @thread&.join(2)
      rescue SystemExit
        nil # the worker's exit(0) on a stop; re-raised by every join
      end
      FileUtils.rm_rf(tmpdir)
    end

    # Runs the worker on a thread; its exit(0) on a stop ends only the thread.
    def start_worker(poll_interval: 5, idle_exit_minutes: 0)
      worker = described_class.new(session_id: session.id, state_dir: tmpdir, session_dir: session_dir,
                                   idle_exit_minutes: idle_exit_minutes, poll_interval: poll_interval)
      @thread = Thread.new { worker.run }
      @thread.report_on_exception = false
      expect(wait_until { File.exist?(sidecar) }).to be(true)
      # Let the loop reach its wait.
      sleep(0.1)
    end

    def sidecar
      File.join(session_dir, Samagotchi::Bridge::SIDECAR_FILE)
    end

    def post_turn(prompt)
      port = JSON.parse(File.read(sidecar))["port"]
      Net::HTTP.post(URI("http://127.0.0.1:#{port}/session/#{session.id}/turn"),
                     JSON.generate(session_id: session.id, prompt: prompt),
                     "Content-Type" => "application/json")
    end

    def next_turn(timeout: 2)
      turns.pop(timeout: timeout)
    end

    it "starts a turn posted to its Bridge at once, not on the next tick" do
      start_worker(poll_interval: 5)

      posted_at = mono
      expect(post_turn("PING").code).to eq("202")

      prompt, started_at = next_turn
      expect(prompt).to eq("PING")
      expect(started_at - posted_at).to be < 0.3
    end

    it "picks up an input file written without a wake on the fallback tick" do
      start_worker(poll_interval: 0.2)

      Samagotchi::SessionManager.write_turn_input(session.id, prompt: "from another process", state_dir: tmpdir)

      expect(next_turn&.first).to eq("from another process")
    end

    it "starts a reminder turn as soon as the reminder callback runs" do
      start_worker(poll_interval: 5)

      called_at = mono
      @reminder_callback.call(["stretch"])

      prompt, started_at = next_turn
      expect(prompt).to include("scheduled reminders are due")
      expect(started_at - called_at).to be < 0.3
    end

    it "runs a turn posted while another runs right after it" do
      release = Queue.new
      allow(engine).to receive(:run_turn) do |_session, prompt, **|
        turns << [prompt, mono]
        release.pop if prompt == "one"
        result
      end
      start_worker(poll_interval: 5)

      post_turn("one")
      expect(next_turn&.first).to eq("one")
      post_turn("two")
      released_at = mono
      release << true

      prompt, started_at = next_turn
      expect(prompt).to eq("two")
      expect(started_at - released_at).to be < 0.3
    end

    it "still exits on a stop marked on disk" do
      start_worker(poll_interval: 0.05)

      Samagotchi::Session.mark_stopped(session.id, state_dir: tmpdir)

      expect { @thread.join(2) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(0) }
    end

    it "still leaves when idle" do
      start_worker(poll_interval: 0.05, idle_exit_minutes: 0.002)

      expect(@thread.join(2)&.value).to eq(:idle_exit)
      expect(File.exist?(sidecar)).to be(false)
    end
  end
end
