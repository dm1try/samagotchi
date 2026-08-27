# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "securerandom"
require "samagotchi/dashboard"
require "samagotchi/session_manager"

RSpec.describe Samagotchi::Dashboard do
  # A fake manager + session so specs never fork a process. The dashboard only
  # needs a duck-typed object responding to list_sessions / spawn_session.
  FakeSession = Struct.new(:id, :status, :last_prompt)

  class FakeManager
    attr_reader :spawned

    def initialize(sessions:)
      @sessions = sessions
      @spawned = []
    end

    def list_sessions
      @sessions
    end

    def spawn_session(prompt:)
      @spawned << prompt
      # Simulate the new session appearing in the refreshed list.
      FakeSession.new("spawned-#{@spawned.size}", "running", prompt)
    end
  end

  # A session row that carries a working directory (needed by the attach
  # header) as well as the fields the menu list row uses.
  FakeRow = Struct.new(:id, :status, :last_prompt, :working_directory)

  # A fake manager that implements the full file-IPC surface Step 2 builds on
  # (resume_session / read_responses / write_turn_input / stop_session /
  # wait_for_session). Records every call so specs can assert on routing and
  # state_dir without ever forking a process.
  class AttachFakeManager
    attr_reader :resumed, :sent, :stopped, :poll, :read_calls

    # +responses+ and +terminals+ are per-poll queues (0-indexed); a missing
    # index means "no output" / "not terminal" for that poll.
    def initialize(sessions:, resume_status: "running", resume_workdir: "/workdir",
                   history: [], responses: [], terminals: [])
      @sessions = sessions
      @resume_status = resume_status
      @resume_workdir = resume_workdir
      @history = history
      @responses = responses
      @terminals = terminals
      @resumed = []
      @sent = []
      @stopped = []
      @read_calls = []
      @poll = 0
    end

    def list_sessions
      @sessions
    end

    def spawn_session(prompt:)
      FakeRow.new("spawned-#{@sent.size}", "running", prompt, "/spawned")
    end

    def resume_session(id, state_dir: nil)
      @resumed << { id: id, state_dir: state_dir }
      FakeRow.new(id, @resume_status, "", @resume_workdir)
    end

    def read_responses(id, since_time: nil, state_dir: nil)
      @read_calls << { id: id, since_time: since_time, state_dir: state_dir }
      since_time.nil? ? @history : (@responses[@poll] || [])
    end

    def write_turn_input(id, prompt:, state_dir: nil)
      @sent << { id: id, prompt: prompt, state_dir: state_dir }
      true
    end

    def stop_session(id, state_dir: nil)
      @stopped << { id: id, state_dir: state_dir }
      :stopped
    end

    def wait_for_session(id, timeout: 30, state_dir: nil)
      result = @terminals[@poll] || false
      @poll += 1
      result
    end
  end

  # Build a dashboard with a fake manager and a scripted input sequence (ending
  # with nil for EOF), run the loop, and capture everything it prints. Records
  # attach routing.
  def with_dashboard(sessions:, script:)
    manager = FakeManager.new(sessions: sessions)
    dashboard = described_class.new(manager: manager)
    attached = []

    output = +""
    original_stdout = $stdout
    $stdout = StringIO.new(output)
    allow(dashboard).to receive(:read_input).and_return(*script)
    allow(dashboard).to receive(:attach_to) { |id| attached << id }

    dashboard.run

    yield manager, output, attached
  ensure
    $stdout = original_stdout
  end

  def session(id:, status:, last_prompt: "")
    FakeSession.new(id, status, last_prompt)
  end

  # Drive the full menu -> attach -> detach cycle. Builds a Dashboard with the
  # given fake manager, scripts read_input, runs the loop, and captures output.
  # Returns [manager, output] so specs can assert on both routing and rendering.
  def run_menu_with(manager:, script:)
    dashboard = described_class.new(manager: manager)
    output = +""
    original_stdout = $stdout
    $stdout = StringIO.new(output)
    allow(dashboard).to receive(:read_input).and_return(*script)

    dashboard.run

    yield manager, output
  ensure
    $stdout = original_stdout
  end

  def row(id:, status:, last_prompt: "", working_directory: "/workdir")
    FakeRow.new(id, status, last_prompt, working_directory)
  end

  describe "#run" do
    it "renders the banner and a numbered list, with short ids and status labels" do
      a = session(id: "a1b2c3d4-1111-4222-8333-111111111111", status: "running", last_prompt: "hello there")
      b = session(id: "b2c3d4e5-2222-4333-9444-222222222222", status: "idle", last_prompt: "")

      with_dashboard(sessions: [a, b], script: [nil]) do |_mgr, output, _attached|
        expect(output).to include("Chi Dashboard")
        expect(output).to include("a1b2c3d4")
        expect(output).to include("b2c3d4e5")
        expect(output).to include("running")
        expect(output).to include("idle")
      end
    end

    it "shows a '—' placeholder for an empty last_prompt" do
      s = session(id: "c3d4e5f6-3333-4444-a555-333333333333", status: "completed", last_prompt: "")

      with_dashboard(sessions: [s], script: [nil]) do |_mgr, output, _attached|
        expect(output).to include("—")
      end
    end

    it "caps a long last_prompt preview with an ellipsis" do
      long = "x" * 200
      s = session(id: "dddd-4444", status: "idle", last_prompt: long)

      with_dashboard(sessions: [s], script: [nil]) do |_mgr, output, _attached|
        expect(output).to include("#{long[0, 40]}…")
        expect(output).not_to include(long)
      end
    end

    it "renders the help hint with no sessions (empty list), no session rows" do
      with_dashboard(sessions: [], script: [nil]) do |_mgr, output, _attached|
        expect(output).to include("Chi Dashboard")
        expect(output).to include(/no sessions/i)
        expect(output).not_to include("—")
      end
    end

    it "spawns a session from a text line, prints its id, and refreshes the list" do
      with_dashboard(sessions: [], script: ["hello there, start a session", nil]) do |_mgr, output, _attached|
        expect(output).to match(/Started session/)
        expect(output).to include("spawned-1")
      end
    end

    it "spawns with exactly the typed prompt" do
      with_dashboard(sessions: [], script: ["hello there, start a session", nil]) do |mgr, _output, _attached|
        expect(mgr.spawned).to eq(["hello there, start a session"])
      end
    end

    it "ends the loop on /quit and never spawns" do
      with_dashboard(sessions: [], script: ["/quit", nil]) do |_mgr, output, _attached|
        expect(output).to include("Chi Dashboard")
        expect(output).not_to match(/Started session/)
      end
    end

    it "ends the loop on /QUIT (uppercase) the same way, without spawning" do
      with_dashboard(sessions: [], script: ["/QUIT", nil]) do |_mgr, output, _attached|
        expect(output).not_to match(/Started session/)
      end
    end

    it "ends the loop on EOF (nil input) cleanly, without spawning" do
      with_dashboard(sessions: [], script: [nil]) do |_mgr, output, _attached|
        expect(output).not_to match(/Started session/)
      end
    end

    it "routes a numeric line to attach_to with the correct session id" do
      one = session(id: "id-one", status: "running", last_prompt: "one")
      two = session(id: "id-two", status: "idle", last_prompt: "two")
      three = session(id: "id-three", status: "completed", last_prompt: "three")

      with_dashboard(sessions: [one, two, three], script: ["2", nil]) do |_mgr, _output, attached|
        expect(attached).to eq(["id-two"])
      end
    end

    it "prints an out-of-range error for a number beyond the list and stays in the loop" do
      one = session(id: "id-one", status: "running", last_prompt: "")
      two = session(id: "id-two", status: "idle", last_prompt: "")
      three = session(id: "id-three", status: "completed", last_prompt: "")

      with_dashboard(sessions: [one, two, three], script: ["99", "1", nil]) do |_mgr, output, attached|
        expect(output).to include("No session at #99")
        # After the error, the next line (1) still routes to attach.
        expect(attached).to eq(["id-one"])
      end
    end

    it "treats an empty line as a no-op, then processes the next line" do
      with_dashboard(sessions: [], script: ["", "spawn me", nil]) do |_mgr, output, attached|
        expect(output).not_to match(/Started session 0/)
        expect(attached).to be_empty
      end
    end
  end

  describe "defaults" do
    it "uses the real SessionManager class when no manager is given" do
      dashboard = described_class.new
      expect(dashboard.instance_variable_get(:@manager)).to be(Samagotchi::SessionManager)
      expect(Samagotchi::SessionManager).to respond_to(:list_sessions)
      expect(Samagotchi::SessionManager).to respond_to(:spawn_session)
    end
  end

  describe "#attach_to (Step 2)" do
    # Two listed sessions so the menu numeric route resolves.
    let(:sessions) do
      [
        row(id: "sess-running", status: "running", last_prompt: "first prompt", working_directory: "/proj/a"),
        row(id: "sess-idle", status: "idle", last_prompt: "again", working_directory: "/proj/b")
      ]
    end

    context "attach header and history on entry" do
      it "prints a session header with id, status, and working directory" do
        manager = AttachFakeManager.new(sessions:, resume_status: "running", resume_workdir: "/proj/a")
        run_menu_with(manager:, script: ["1", "/detach", nil]) do |mgr, output|
          expect(output).to include("Session sess-running")
          expect(output).to include("status:  running")
          expect(output).to include("workdir: /proj/a")
          expect(mgr.resumed.map { |h| h[:id] }).to eq(["sess-running"])
        end
      end

      it "displays existing conversation history read from output/ on entry" do
        manager = AttachFakeManager.new(sessions:, history: ["<user line>", "<agent line>"])
        run_menu_with(manager:, script: ["1", "/detach", nil]) do |mgr, output|
          expect(output).to include("Conversation history (from output/):")
          expect(output).to include("<user line>")
          expect(output).to include("<agent line>")
          # History is rebuilt from read_responses(since_time: nil), not from a
          # Session.messages field.
          expect(mgr.read_calls).to include(including(id: "sess-running", since_time: nil))
        end
      end

      it "prints no history section when there is no on-disk output" do
        manager = AttachFakeManager.new(sessions:, history: [])
        run_menu_with(manager:, script: ["1", "/detach", nil]) do |_mgr, output|
          expect(output).not_to include("Conversation history")
        end
      end
    end

    context "sending a message and displaying new output" do
      it "writes the message via file IPC and renders the new output" do
        manager = AttachFakeManager.new(sessions:, responses: [["<the response>"]])
        run_menu_with(manager:, script: ["1", "hello there", "/detach", nil]) do |mgr, output|
          expect(mgr.sent).to eq([{ id: "sess-running", prompt: "hello there", state_dir: nil }])
          expect(output).to include("<the response>")
        end
      end

      it "skips blank output chunks when rendering new output" do
        manager = AttachFakeManager.new(sessions:, responses: [["   ", "<real chunk>"]])
        run_menu_with(manager:, script: ["1", "hi", "/detach", nil]) do |_mgr, output|
          expect(output).to include("<real chunk>")
          # The blank chunk was skipped, so no standalone 3-space line is emitted
          # (the header's own blank lines are zero-width, not 3 spaces).
          expect(output).not_to include("   \n")
        end
      end

      it "treats an empty line as a no-op and sends the next non-empty line only" do
        manager = AttachFakeManager.new(sessions:, responses: [["the response"]])
        run_menu_with(manager:, script: ["1", "", "   ", "only this", "/detach", nil]) do |mgr, _output|
          expect(mgr.sent).to eq([{ id: "sess-running", prompt: "only this", state_dir: nil }])
        end
      end

      it "auto-detaches when the session finishes with no new output" do
        manager = AttachFakeManager.new(sessions:, responses: [[]], terminals: [true])
        run_menu_with(manager:, script: ["1", "go", "/detach", nil]) do |mgr, output|
          expect(mgr.poll).to be >= 1
          expect(output).to include("Session finished")
        end
      end

      it "returns to the menu after a bounded poll timeout with no output" do
        manager = AttachFakeManager.new(sessions:, responses: [[]], terminals: [false])
        run_menu_with(manager:, script: ["1", "go", "/detach", nil]) do |_mgr, output|
          # Polls exhaust to the iteration cap quickly (stubs return instantly),
          # then the dashboard detaches with a timeout notice.
          expect(output).to include("Detaching to menu")
        end
      end

      it "strips wire-format protocol/literal tokens from displayed output" do
        # Regression: raw <|...> control tokens and [[SAMAGOTCHI_LITERAL_*]] call
        # literals in an output file must be stripped before display, not shown
        # verbatim. The Qwen literal is built via concatenation so the tool/shell
        # layer does not mask it into a <|...> token before the interpreter sees it.
        qwen = "[[SAMAGOTCHI_LITERAL_" + "TOOL_CALL_OPEN" + "]]"
        manager = AttachFakeManager.new(sessions:, responses: [["before #{qwen} <|turn>| after"]])
        run_menu_with(manager:, script: ["1", "hi", "/detach", nil]) do |_mgr, output|
          expect(output).to include("before")
          expect(output).to include("after")
          expect(output).not_to include("<|")
          expect(output).not_to include(qwen)
        end
      end
    end

    context "leave commands" do
      it "/detach detaches to the menu while the worker keeps running" do
        manager = AttachFakeManager.new(sessions:)
        run_menu_with(manager:, script: ["1", "/detach", nil]) do |mgr, output|
          expect(mgr.resumed.map { |h| h[:id] }).to eq(["sess-running"])
          expect(mgr.stopped).to be_empty # worker NOT stopped
          expect(output).to include("Detached from session")
        end
      end

      it "/DETACH (case-insensitive) detaches to the menu" do
        manager = AttachFakeManager.new(sessions:)
        run_menu_with(manager:, script: ["1", "/DETACH", nil]) do |mgr, _output|
          expect(mgr.stopped).to be_empty
          expect(mgr.resumed.map { |h| h[:id] }).to eq(["sess-running"])
        end
      end

      it "/quit detaches to the menu (not process exit) and reminds to /quit again" do
        manager = AttachFakeManager.new(sessions:)
        run_menu_with(manager:, script: ["1", "/quit", nil]) do |mgr, output|
          expect(mgr.stopped).to be_empty
          expect(output).to include("type /quit again from the menu")
        end
      end

      it "/stop stops the worker, confirms it stopped, then detaches" do
        manager = AttachFakeManager.new(sessions:, terminals: [true])
        run_menu_with(manager:, script: ["1", "/stop", nil]) do |mgr, output|
          expect(mgr.stopped.map { |h| h[:id] }).to eq(["sess-running"])
          expect(mgr.poll).to be >= 1 # wait_for_session confirmed terminal
          expect(output).to include("Session stopped")
        end
      end

      it "/STOP (case-insensitive) stops the worker" do
        manager = AttachFakeManager.new(sessions:, terminals: [true])
        run_menu_with(manager:, script: ["1", "/STOP", nil]) do |mgr, _output|
          expect(mgr.stopped.map { |h| h[:id] }).to eq(["sess-running"])
        end
      end

      it "EOF (nil input) detaches cleanly without error or process exit" do
        manager = AttachFakeManager.new(sessions:)
        expect {
          run_menu_with(manager:, script: ["1", nil]) { |_mgr, _output| }
        }.not_to raise_error
      end

      it "resumes the worker when attaching to an idle session" do
        manager = AttachFakeManager.new(sessions:, resume_status: "running", history: [], responses: [["the response"]])
        run_menu_with(manager:, script: ["2", "hello", "/detach", nil]) do |mgr, output|
          expect(mgr.resumed.map { |h| h[:id] }).to eq(["sess-idle"])
          expect(mgr.sent.map { |h| h[:id] }).to eq(["sess-idle"])
          expect(output).to include("the response")
        end
      end
    end

    context "integration and hygiene" do
      it "drives a full menu -> attach -> message -> detach -> menu cycle and returns" do
        manager = AttachFakeManager.new(sessions:, responses: [["the response"]])
        expect {
          run_menu_with(manager:, script: ["1", "hello", "/detach", nil]) do |_mgr, output|
            expect(output).to include("Session sess-running")
            expect(output).to include("the response")
          end
        }.not_to raise_error(SystemExit)
      end

      it "uses only the injected fake manager — never the real SessionManager" do
        manager = AttachFakeManager.new(sessions:)
        expect(Samagotchi::SessionManager).not_to receive(:resume_session)
        expect(Samagotchi::SessionManager).not_to receive(:write_turn_input)
        expect(Samagotchi::SessionManager).not_to receive(:stop_session)
        run_menu_with(manager:, script: ["1", "/stop", nil]) { |_mgr, _output| }
      end

      it "threads state_dir from the dashboard into every attach call" do
        manager = AttachFakeManager.new(sessions:)
        dashboard = described_class.new(manager: manager, state_dir: "/custom/state")
        output = +""
        original_stdout = $stdout
        $stdout = StringIO.new(output)
        allow(dashboard).to receive(:read_input).and_return("1", "/detach", nil)
        dashboard.run
        $stdout = original_stdout

        expect(manager.resumed.map { |h| h[:state_dir] }).to eq(["/custom/state"])
        expect(manager.read_calls.map { |h| h[:state_dir] }).to eq(["/custom/state"])
        # No messages were sent on this script ("/detach" before any input).
        expect(manager.sent).to be_empty
      end
    end
  end
end
