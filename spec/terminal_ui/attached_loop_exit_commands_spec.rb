# frozen_string_literal: true

require "json"
require "samagotchi/worker_link"
require_relative "../support/worker_fixtures"
require_relative "../support/worker_links"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "/exit and /detach" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:stream) { double("stream", close: nil) }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:idle) { { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 } }

  def response(status, body = "{}") = Samagotchi::BridgeClient::Response.new(status: status, body: body)

  # With +at+, the lines are typed once a read opens at that prompt (a
  # continue offer or a question restarts the first read).
  def run_lines(*lines, snapshot: idle, at: nil)
    allow(client).to receive(:follow) do |**, &block|
      block.call("type" => "snapshot", "snapshot" => snapshot)
      stream
    end
    return attached.run(input: ->(_prompt, _prefill) { lines.shift }) unless at

    typed = Queue.new
    prompts = Queue.new
    thread = Thread.new { attached.run(input: ->(prompt, _prefill) { prompts << prompt; typed.pop }) }
    wait_for("the prompt #{at.inspect}", timeout: 2) { prompts.pop(timeout: 0.05)&.include?(at) }
    lines.each { |line| typed << line }
    thread.value
  end

  it "follows the stream under its client id, so the worker doesn't count its own stream as another UI" do
    run_lines(nil)

    expect(client).to have_received(:follow)
      .with(client_id: "tui:1", rediscover: anything,
            reconnect_delays: Samagotchi::BridgeClient::EventStream::REDISCOVER_DELAYS)
  end

  %w[/exit /quit /QUIT exit].each do |line|
    it "detaches on #{line} and asks the worker to exit, which it will" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))

      expect(run_lines(line)).to eq(:detached)

      expect(client).to have_received(:request_exit).with(client_id: "tui:1")
      expect(screen.lines.last).to eq("Detached; the session's worker is stopping. Resume with: chi --resume s-1234")
      expect(stream).to have_received(:close)
    end
  end

  # The worker checks again once it has let go: a note arriving first keeps it.
  it "says an empty session will be discarded instead of how to resume it" do
    allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting","discard":true}'))

    run_lines("/exit")

    expect(screen.lines.last).to eq("Detached; the session is empty: it will be discarded if nothing arrives before its worker stops.")
  end

  it "says how to resume a session the worker keeps" do
    allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting","discard":false}'))

    run_lines("/exit")

    expect(screen.lines.last).to eq("Detached; the session's worker is stopping. Resume with: chi --resume s-1234")
  end

  {
    "turn_running" => "a turn is running", "input_queued" => "prompts are queued",
    "continue_offered" => "a continue offer is pending", "client_connected" => "another UI is attached",
    "reminders" => "reminders are set", "starting" => "the worker is still starting", "something_new" => "something_new"
  }.each do |reason, words|
    it "says what keeps the worker up when it holds (#{reason})" do
      allow(client).to receive(:request_exit).and_return(response(409, %({"status":"held","reason":"#{reason}"})))

      expect(run_lines("/exit")).to eq(:detached)

      expect(screen.lines.last).to eq("Detached; the session keeps running (#{words}). Re-attach with: chi --attach s-1234")
    end
  end

  it "names the background tasks that keep the worker up" do
    body = '{"status":"held","reason":"background_tasks","tasks":[{"id":"3f9a2c1d-77","command":"rails s"},' \
           '{"id":"aa11bb22-0","command":"sleep 99"}]}'
    allow(client).to receive(:request_exit).and_return(response(409, body))

    expect(run_lines("/exit")).to eq(:detached)

    expect(screen.lines.last).to eq("Detached; the session keeps running (background tasks it started are still running: " \
                                    "3f9a2c1d (rails s), aa11bb22 (sleep 99); stop one with the web's stop-task button " \
                                    "or by asking for task_stop). Re-attach with: chi --attach s-1234")
  end

  it "says how to stop an older worker that has no exit route" do
    allow(client).to receive(:request_exit).and_return(response(404, '{"error":"not_found"}'))

    run_lines("/exit")

    expect(screen.lines.last).to eq("Detached; this worker runs an older chi and can't be stopped from here: chi sessions stop s-1234")
  end

  [
    [404, '{"error":"unknown_session"}', "404 unknown_session"],
    [0, nil, "no reply"],
    [500, '{"error":"bridge_error","detail":"boom"}', "500 boom"]
  ].each do |status, body, why|
    it "detaches and says the request didn't go through (#{why})" do
      allow(client).to receive(:request_exit).and_return(response(status, body))

      expect(run_lines("/exit")).to eq(:detached)

      expect(screen.lines.last).to eq("Detached (could not ask the worker to stop: #{why}). Re-attach with: chi --attach s-1234")
    end
  end

  describe "the exit ask (what still runs, and what to do with it)" do
    def holds(kind, items) = { "kind" => kind, "items" => items }
    def held(reason, holds) = response(409, JSON.generate(status: "held", reason: reason, holds: holds))

    let(:ask) do
      held("reminders", [
        holds("reminders", [{ "id" => "api_health", "label" => "api_health", "detail" => "every 20m" },
                            { "id" => "git push", "label" => "git push", "detail" => "every 5m" }]),
        holds("background_tasks", [{ "id" => "3f9a2c1d-77", "label" => "rails s", "detail" => "2m" }]),
        holds("delegates", [{ "id" => "c1c1c1c1-1111", "label" => "Fix the composer", "detail" => "running a turn" }])
      ])
    end

    it "asks what to do, listing each thing that still runs" do
      allow(client).to receive(:request_exit).and_return(ask, response(200, '{"status":"exiting"}'))

      run_lines("/exit", "3", "/exit")

      expect(screen.lines).to include(<<~ASK.strip)
        This session still has:
          • 2 reminders: api_health (every 20m), git push (every 5m)
          • 1 background task: rails s (2m)
          • 1 delegate: c1c1c1c1 "Fix the composer" (running a turn)
          1. Keep running in the background (detach)
          2. Stop them and exit
          3. Back to the session
      ASK
    end

    it "1 detaches and leaves everything running" do
      allow(client).to receive(:request_exit).and_return(ask)

      expect(run_lines("/exit", "1")).to eq(:detached)

      expect(screen.lines.last).to eq("Detached; the session keeps running (2 reminders, 1 background task, " \
                                      "1 delegate). Re-attach with: chi --attach s-1234")
      expect(stream).to have_received(:close)
    end

    it "2 asks the worker to stop them all and exit, saying what it stopped" do
      allow(client).to receive(:request_exit).and_return(
        ask,
        response(200, JSON.generate(status: "exiting", session_id: "s-1234",
                                    stopped: { "reminders" => ["api_health", "git push"],
                                               "tasks" => ["rails s"], "delegates" => ["c1c1c1c1"] }))
      )

      expect(run_lines("/exit", "2")).to eq(:detached)

      expect(client).to have_received(:request_exit).with(client_id: "tui:1", stop: true)
      expect(screen.lines.last).to eq("Detached; stopped 2 reminders (api_health, git push), 1 background task " \
                                      "(rails s), 1 delegate (c1c1c1c1). Resume with: chi --resume s-1234")
    end

    it "3 stays in the session: nothing stops, and the next /exit asks again" do
      allow(client).to receive(:request_exit).and_return(ask, ask)

      expect(run_lines("/exit", "3", "/detach")).to eq(:detached)

      expect(screen.lines).to include("(nothing stopped; the worker keeps running)")
      expect(screen.lines.last).to eq("Detached; the session keeps running. Re-attach with: chi --attach s-1234")
      expect(client).to have_received(:request_exit).with(client_id: "tui:1").once
    end

    it "refuses to answer anything else and keeps asking" do
      allow(client).to receive(:request_exit).and_return(ask)

      expect(run_lines("/exit", "stop the dev server first", "1")).to eq(:detached)

      expect(screen.lines).to include("Say 1 (keep running), 2 (stop them and exit) or 3 (back to the session).")
      expect(client).to have_received(:request_exit).with(client_id: "tui:1").once
    end

    it "detaches when the input ends without an answer" do
      allow(client).to receive(:request_exit).and_return(ask)

      expect(run_lines("/exit", nil)).to eq(:detached)

      expect(screen.lines.last).to eq("Detached; the session keeps running (2 reminders, 1 background task, " \
                                      "1 delegate). Re-attach with: chi --attach s-1234")
    end

    it "asks for delegates alone, and 1 leaves them running" do
      only = held("delegates", [holds("delegates", [{ "id" => "c1c1c1c1-1111", "label" => "Fix the composer",
                                                      "detail" => "running a turn" }])])
      allow(client).to receive(:request_exit).and_return(only)

      expect(run_lines("/exit", "1")).to eq(:detached)

      expect(screen.lines).to include(<<~ASK.strip)
        This session still has:
          • 1 delegate: c1c1c1c1 "Fix the composer" (running a turn)
          1. Keep running in the background (detach)
          2. Stop them and exit
          3. Back to the session
      ASK
      expect(screen.lines.last).to eq("Detached; the session keeps running (1 delegate). " \
                                      "Re-attach with: chi --attach s-1234")
    end

    it "refuses as before when a hold the user can't stop is there too" do
      allow(client).to receive(:request_exit).and_return(held("turn_running", []))

      expect(run_lines("/exit")).to eq(:detached)

      expect(screen.lines.last).to eq("Detached; the session keeps running (a turn is running). " \
                                      "Re-attach with: chi --attach s-1234")
    end

    it "says what the worker stopped even in a session it discards" do
      allow(client).to receive(:request_exit).and_return(
        held("background_tasks", [holds("background_tasks", [{ "id" => "t1", "label" => "rails s", "detail" => "1m" }])]),
        response(200, JSON.generate(status: "exiting", session_id: "s-1234", discard: true,
                                    stopped: { "reminders" => [], "tasks" => ["rails s"], "delegates" => [] }))
      )

      expect(run_lines("/exit", "2")).to eq(:detached)

      expect(screen.lines.last).to eq("Detached; stopped 1 background task (rails s). The session is empty: it " \
                                      "will be discarded if nothing arrives before its worker stops.")
    end
  end

  it "says the worker didn't answer in time when the Bridge read the exit too late" do
    allow(client).to receive(:request_exit).and_return(response(408, '{"error":"deadline_passed"}'))

    expect(run_lines("/exit")).to eq(:detached)

    expect(screen.lines.last)
      .to eq("Detached (could not ask the worker to stop: worker not answering in time). Re-attach with: chi --attach s-1234")
  end

  it "detaches when the Bridge is gone" do
    allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)

    expect(run_lines("/exit")).to eq(:detached)

    expect(screen.lines.last).to start_with("Detached (could not ask the worker to stop: Connection refused")
    expect(screen.lines.last).to end_with("Re-attach with: chi --attach s-1234")
  end

  describe "/exit --delete" do
    let(:deleted) { [] }
    let(:delete_session) { ->(id) { deleted << id } }
    let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", delete_session: delete_session) }

    ["/exit --delete", "/quit --delete", "exit --delete", "EXIT --DELETE"].each do |line|
      it "asks the worker to exit, then deletes the session (#{line})" do
        allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))

        expect(run_lines(line)).to eq(:detached)

        expect(client).to have_received(:request_exit).with(client_id: "tui:1", delete: true)
        expect(deleted).to eq(["s-1234"])
        expect(screen.lines.last).to eq("Detached; deleted session s-1234.")
      end
    end

    it "leaves an empty session to the worker, which deletes it as it leaves" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting","discard":true}'))

      run_lines("/exit --delete")

      expect(deleted).to be_empty
      expect(screen.lines.last).to eq("Detached; the session is empty: it will be discarded if nothing arrives before its worker stops.")
    end

    it "deletes nothing when the worker stays up, and says why" do
      allow(client).to receive(:request_exit).and_return(response(409, '{"status":"held","reason":"client_connected"}'))

      run_lines("/exit --delete")

      expect(deleted).to be_empty
      expect(screen.lines.last).to eq("Detached; not deleted: the session keeps running (another UI is attached). " \
                                      "Re-attach with: chi --attach s-1234")
    end

    it "deletes nothing when the exit request fails" do
      allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)

      run_lines("/exit --delete")

      expect(deleted).to be_empty
      expect(screen.lines.last).to start_with("Detached (could not ask the worker to stop: Connection refused")
      expect(screen.lines.last).to end_with("Not deleted.")
    end

    it "says how to finish when the delete is refused after the exit" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))
      refusing = ->(id) { raise Samagotchi::SessionManager::DeleteRefused.new(id, :still_stopping) }
      loop_ui = described_class.new(client: client, screen: screen, client_id: "tui:1", delete_session: refusing)
      allow(client).to receive(:follow) do |**, &block|
        block.call("type" => "snapshot", "snapshot" => idle)
        stream
      end
      inputs = ["/exit --delete"]

      loop_ui.run(input: ->(_prompt, _prefill) { inputs.shift })

      expect(screen.lines.last).to eq("Detached; the worker is stopping, but session s-1234 was not deleted " \
                                      "(session s-1234's worker is still shutting down): chi sessions delete s-1234")
    end

    it "takes any other /exit argument as a prompt, not an exit" do
      allow(client).to receive(:request_exit)
      allow(client).to receive(:post_turn).and_return(response(202, '{"status":"accepted","enqueued_id":"e1"}'))

      run_lines("/exit --now", nil)

      expect(client).not_to have_received(:request_exit)
      expect(deleted).to be_empty
    end
  end

  describe "/archive" do
    let(:archived) { [] }
    let(:archive_session) do
      lambda do |id|
        archived << id
        { id: id, archived: [id], stopped: [], discarded: [] }
      end
    end
    let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", archive_session: archive_session) }

    it "asks the worker to exit, then archives the session" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))

      expect(run_lines("/archive")).to eq(:detached)

      expect(client).to have_received(:request_exit).with(client_id: "tui:1", ask: false)
      expect(archived).to eq(["s-1234"])
      expect(screen.lines.last).to eq("Detached; archived session s-1234. chi sessions list --archived finds it.")
    end

    it "leaves an empty session to the worker, which discards it as it leaves" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting","discard":true}'))

      run_lines("/archive")

      expect(archived).to be_empty
      expect(screen.lines.last).to eq("Detached; the session is empty: it will be discarded if nothing arrives before its worker stops.")
    end

    it "archives when the worker stays up for another UI: the archive stops it, as the web's does" do
      allow(client).to receive(:request_exit).and_return(response(409, '{"status":"held","reason":"client_connected"}'))

      run_lines("/archive")

      expect(archived).to eq(["s-1234"])
      expect(screen.lines.last).to start_with("Detached; archived session s-1234.")
    end

    # D2: it waits for the running turn and the commands queued behind it.
    it "archives after the turn when typed during it, once the commands queued behind it ran" do
      allow(client).to receive(:request_exit).and_return(response(200, '{"status":"exiting"}'))
      running = idle.merge("current_turn" => { "prompt" => "work", "parts" => [] },
                           "queued_commands" => [{ "command_id" => "c1", "client_id" => "web:tab", "line" => "/model x" }])
      push = nil
      allow(client).to receive(:follow) do |**, &block|
        push = block
        block.call("type" => "snapshot", "snapshot" => running)
        stream
      end
      reads = ["/archive"]
      ended = attached.run(input: lambda { |_prompt, _prefill|
        next reads.shift unless reads.empty?

        push.call("type" => "turn_completed", "result" => "done")
        expect(client).not_to have_received(:request_exit)
        push.call("type" => "command_ran", "command_id" => "c1", "client_id" => "web:tab", "line" => "/model x",
                  "status" => "ok", "output" => "runtime model set to x", "changed" => ["model"], "queued" => true)
        sleep 30 # sleep-ok: no more input: the read stays open until the archive's stop ends it
        nil
      })

      expect(ended).to eq(:detached)
      expect(screen.lines).to include("(archives after this turn)")
      expect(client).to have_received(:request_exit).once.with(client_id: "tui:1", ask: false)
      expect(archived).to eq(["s-1234"])
      expect(screen.lines.last).to eq("Detached; archived session s-1234. chi sessions list --archived finds it.")
    end

    it "says so when the archive is refused (a turn running)" do
      allow(client).to receive(:request_exit).and_return(response(409, '{"status":"held","reason":"turn_running"}'))
      refusing = ->(id) { raise Samagotchi::SessionManager::ArchiveRefused.new(id, :busy) }
      loop_ui = described_class.new(client: client, screen: screen, client_id: "tui:1", archive_session: refusing)
      allow(client).to receive(:follow) do |**, &block|
        block.call("type" => "snapshot", "snapshot" => idle)
        stream
      end
      inputs = ["/archive"]

      loop_ui.run(input: ->(_prompt, _prefill) { inputs.shift })

      expect(screen.lines.last).to eq("Detached; session s-1234 was not archived (a turn is running; wait for it or " \
                                      "cancel it first). Re-attach with: chi --attach s-1234")
    end

    it "archives nothing when the exit request fails" do
      allow(client).to receive(:request_exit).and_raise(Errno::ECONNREFUSED)

      run_lines("/archive")

      expect(archived).to be_empty
      expect(screen.lines.last).to end_with("Not archived.")
    end
  end

  it "only detaches on /detach (any case) and Ctrl-D, leaving the worker up" do
    allow(client).to receive(:request_exit)
    allow(client).to receive(:post_turn)

    expect(run_lines("/detach")).to eq(:detached)
    expect(run_lines("/DETACH")).to eq(:detached)
    expect(run_lines(nil)).to eq(:detached)

    expect(client).not_to have_received(:request_exit)
    expect(client).not_to have_received(:post_turn)
    expect(screen.lines.last).to eq("Detached; the session keeps running. Re-attach with: chi --attach s-1234")
  end

  it "detaches on /detach at a continue offer instead of answering it" do
    allow(client).to receive(:post_command)

    expect(run_lines("/detach", snapshot: idle.merge("continue_offer" => { "context" => {}, "no_interrupt" => false }),
                               at: "? ")).to eq(:detached)

    expect(client).not_to have_received(:post_command)
  end

  it "runs /stats and /recap at a continue offer, the offer staying open" do
    allow(client).to receive(:post_command)
    allow(client).to receive(:get_json).with("stats")
      .and_return(JSON.parse(JSON.generate(metrics: { turns: 3 })))
    allow(client).to receive(:request_recap)
      .and_return(response(200, JSON.generate(enabled: false)))
    offered = idle.merge("continue_offer" => { "context" => {}, "no_interrupt" => false })

    expect(run_lines("/stats", "/recap", nil, snapshot: offered, at: "? ")).to eq(:detached)

    expect(client).not_to have_received(:post_command)
    expect(screen.lines).to include(a_string_including("turns:            3"),
                                    a_string_starting_with("recap is off"))
    expect(attached.instance_variable_get(:@continue_offer)).not_to be_nil
  end

  it "asks the worker on /exit at a continue offer, which then holds" do
    allow(client).to receive(:post_command)
    allow(client).to receive(:request_exit).and_return(response(409, '{"status":"held","reason":"continue_offered"}'))

    run_lines("/exit", snapshot: idle.merge("continue_offer" => { "context" => {}, "no_interrupt" => false }),
                       at: "? ")

    expect(client).not_to have_received(:post_command)
    expect(screen.lines.last).to include("(a continue offer is pending)")
  end

  it "reads /exit at an open question as an answer to it" do
    allow(client).to receive(:request_exit)
    question = { "id" => "q1", "question" => "Pick", "options" => %w[a b] }
    turn = { "prompt" => "p", "parts" => [], "pending_question" => question }

    run_lines("/exit", nil, snapshot: idle.merge("current_turn" => turn), at: "? ")

    expect(screen.lines).to include("Unknown option '/exit'. Use numbers 1-2 or exact labels.")
    expect(client).not_to have_received(:request_exit)
  end

  it "detaches on /detach at an open question, as Ctrl-D does; the question stays open for another UI" do
    allow(client).to receive(:answer)
    allow(client).to receive(:dismiss_question)
    question = { "id" => "q1", "question" => "Pick", "options" => %w[a b] }
    turn = { "prompt" => "p", "parts" => [], "pending_question" => question }

    expect(run_lines("/detach", snapshot: idle.merge("current_turn" => turn), at: "? ")).to eq(:detached)

    expect(screen.lines.last).to eq("Detached; the session keeps running. Re-attach with: chi --attach s-1234")
    expect(client).not_to have_received(:answer)
    expect(client).not_to have_received(:dismiss_question)
  end

  it "offers /detach and /quit on Tab" do
    expect(attached.send(:assist_path_completion_candidates, "/d")).to eq(["/detach"])
    expect(attached.send(:assist_path_completion_candidates, "/qui")).to eq(["/quit"])
  end
end
