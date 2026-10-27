# frozen_string_literal: true

require "json"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require "samagotchi/terminal_ui/remote_link"
require_relative "../support/recording_surface"

# AttachedLoop on a RemoteLink (chi --remote studio --attach ID): the same
# TUI, every printed command spelled with --remote studio, the terminal's
# own commands (/exit, /archive, /stats, /recap) through chi web's routes,
# and a failure to reach chi web a line, never a crash. The Remote and its client are
# doubles; RemoteLink is real.
RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "through a remote" do
  let(:screen) { RecordingSurface.new(columns: 100) }
  let(:entry) { Samagotchi::Remotes::Entry.new(name: "studio", url: "http://192.0.2.10:4567", token: "t") }
  let(:client) { instance_double(Samagotchi::SessionAccess::WebBridgeClient, session_id: "s-1234", worker_key: "e1") }
  let(:stream) { instance_double(Samagotchi::BridgeClient::EventStream, close: nil) }
  let(:remote) do
    instance_double(Samagotchi::SessionAccess::Remote, name: "studio", entry: entry, attach_client: client,
                                                       invocation: Samagotchi::ChiInvocation.new(remote: "studio"))
  end
  let(:woke) do
    Samagotchi::SessionAccess::WakeReply.new(woke: false, worker: { "epoch" => "e1", "features" => %w[delivery unqueue] },
                                             default_model: "studio-default",
                                             strategy: Samagotchi::Guardrails::ParentPolicy.strategy("soft"), installed: nil)
  end
  let(:link) { Samagotchi::TerminalUI::RemoteLink.new(remote: remote, session_id: "s-1234", woke: woke) }
  let(:attached) { described_class.new(link: link, screen: screen, client_id: "tui:1@mac") }
  let(:joined) do
    JSON.parse(JSON.generate(type: :snapshot, snapshot: { messages: [], queued: [], event_seq: 1 },
                             session_state_snapshot: { status: "idle", message_count: 0 }))
  end
  let(:refused_token) do
    "remote studio (http://192.0.2.10:4567): the token was refused (chi web's LAN link carries the current one: " \
      "chi remote add studio http://192.0.2.10:4567 --token-file FILE)"
  end

  # The join's children segment (GET …/children/counts): none by default.
  before { allow(client).to receive(:children_counts).and_return({ "running" => 0, "waiting" => 0, "unreported" => 0 }) }

  def run_with(inputs, events: [])
    allow(client).to receive(:follow) do |&block|
      block.call(joined)
      events.each { |event| block.call(event) }
      stream
    end
    attached.run(input: ->(_prompt, _prefill) { inputs.shift })
  end

  it "follows the stream with about a minute of reconnects, and spells the detach line with --remote" do
    expect(run_with([nil])).to eq(:detached)

    expect(client).to have_received(:follow)
      .with(client_id: "tui:1@mac", rediscover: anything, reconnect_delays: Samagotchi::TerminalUI::RemoteLink::RECONNECT_DELAYS)
    expect(screen.lines.last).to eq("Detached; the session keeps running. Re-attach with: chi --remote studio --attach s-1234")
  end

  def response(status, body) = Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(body))

  describe "the terminal's own commands through chi web" do
    it "/exit: asks the worker to exit with this TUI's client id, and spells the resume with --remote" do
      allow(client).to receive(:request_exit).and_return(response(200, { status: "exiting", session_id: "s-1234" }))

      expect(run_with(["/exit"])).to eq(:detached)

      expect(client).to have_received(:request_exit).with(client_id: "tui:1@mac")
      expect(screen.lines.last).to eq("Detached; the session's worker is stopping. Resume with: chi --remote studio --resume s-1234")
    end

    it "/exit: a worker held up says why, and how to re-attach there" do
      allow(client).to receive(:request_exit)
        .and_return(response(409, { error: "held", status: "held", reason: "other_ui", session_id: "s-1234" }))

      run_with(["/exit"])

      expect(screen.lines.last).to match(/\ADetached; the session keeps running \(.+\)\. Re-attach with: chi --remote studio --attach s-1234\z/)
    end

    it "/exit through a chi web without the route: one line in Remote.too_old_message's words" do
      too_old = Samagotchi::SessionAccess::Remote.too_old_message(entry, "0.1.0")
      allow(client).to receive(:request_exit).and_raise(Samagotchi::SessionAccess::WebBridgeClient::Unreachable, too_old)

      run_with(["/exit"])

      expect(screen.lines.last).to eq("Detached (could not ask the worker to stop: #{too_old}). Re-attach with: chi --remote studio --attach s-1234")
    end

    it "/exit --delete: the worker exits, then the session is deleted there (force)" do
      allow(client).to receive(:request_exit).and_return(response(200, { status: "exiting", session_id: "s-1234" }))
      allow(remote).to receive(:delete).and_return({ id: "s-1234", stopped: true })

      run_with(["/exit --delete"])

      expect(client).to have_received(:request_exit).with(client_id: "tui:1@mac", delete: true)
      expect(remote).to have_received(:delete).with("s-1234", force: true)
      expect(screen.lines.last).to eq("Detached; deleted session s-1234.")
    end

    it "/exit --delete refused there: not deleted, and the remote's command to do it" do
      allow(client).to receive(:request_exit).and_return(response(200, { status: "exiting", session_id: "s-1234" }))
      allow(remote).to receive(:delete).and_raise(Samagotchi::SessionManager::DeleteRefused.new("s-1234", :still_stopping))

      run_with(["/exit --delete"])

      expect(screen.lines.last).to eq("Detached; the worker is stopping, but session s-1234 was not deleted " \
                                      "(session s-1234's worker is still shutting down): chi --remote studio sessions delete s-1234")
    end

    it "/archive: the worker exits, then the session is archived there" do
      allow(client).to receive(:request_exit).and_return(response(200, { status: "exiting", session_id: "s-1234" }))
      allow(remote).to receive(:archive).and_return({ id: "s-1234", archived: ["s-1234"], stopped: [], discarded: [] })

      run_with(["/archive"])

      expect(remote).to have_received(:archive).with("s-1234")
      expect(screen.lines.last).to eq("Detached; archived session s-1234. chi --remote studio sessions list --archived finds it.")
    end

    it "/stats: that worker's metrics as here, and why when chi web couldn't give them" do
      allow(client).to receive(:stats).and_return({ "turns" => 2 })
      down = "no live worker for session s-1234 on studio"
      run_with(["/stats", nil])
      expect(screen.lines).to include(attached.send(:format_session_metrics, { turns: 2 }))

      allow(client).to receive(:stats).and_raise(Samagotchi::SessionAccess::WebBridgeClient::Unreachable, down)
      attached.send(:show_stats)
      expect(screen.lines.last).to eq("(no metrics: #{down})")
    end

    it "/recap: the saved recap in the REPL's words, and why when chi web couldn't give it" do
      allow(client).to receive(:request_recap)
        .and_return(response(200, { enabled: true, saved: { text: "Fixed the spec.", turns_since: 0 }, request: "started", min_user_turns: 1 }))

      run_with(["/recap", nil])

      expect(client).to have_received(:request_recap)
      expect(screen.lines.join("\n")).to include("Fixed the spec.")

      allow(client).to receive(:request_recap).and_raise(Samagotchi::SessionAccess::WebBridgeClient::Unreachable, "remote studio: timed out")
      attached.send(:show_recap)
      expect(screen.lines.last).to eq("(no recap: remote studio: timed out)")
    end
  end

  it "joins with that machine's saved records: the steps' durations, a failed turn's line" do
    allow(client).to receive(:turn_records).with("t1").and_return(
      { "tool_records" => [{ "turn_id" => "t1", "tool" => "execute", "duration_ms" => 1234 }],
        "turn_record" => { "id" => "t1", "status" => "failed", "duration_ms" => 2000, "failure" => { "summary" => "HTTP 500: boom" } } }
    )
    messages = [{ role: "user", content: "find it", turn_id: "t1" },
                { role: "model", content: "Searching.", tool_calls: [{ id: "c1", name: "execute", arguments: { command: "true" } }] },
                { role: "tool_response", tool_call_id: "c1", content: "exit: 0" },
                { role: "model", content: "Still searching." }]
    attached.handle_event(JSON.parse(JSON.generate(type: :snapshot, snapshot: { messages: messages, queued: [], event_seq: 1 },
                                                   session_state_snapshot: { status: "idle", message_count: 4 })))

    expect(screen.lines.map { |line| line.gsub(/\e\[[\d;]*m/, "") })
      .to eq(["user> find it", 'tool> running command (execute command="true"): ok (1.2s)', "✕ turn failed: HTTP 500: boom · 2.0s"])
    expect(client).to have_received(:turn_records).once
  end

  it "says a mid-session refused token or a too-old chi web in its own words, and goes on" do
    allow(client).to receive(:post_turn).and_raise(Samagotchi::SessionAccess::WebBridgeClient::Unreachable, refused_token)
    too_old = "remote studio runs chi 0.1.0, too old for this command through --remote: update chi there (chi update)"
    allow(client).to receive(:post_command).and_raise(Samagotchi::SessionAccess::WebBridgeClient::Unreachable, too_old)
    allow(client).to receive(:dequeue)

    expect(run_with(["hello", "/title x", nil])).to eq(:detached)

    expect(screen.lines).to include("could not send the prompt (#{refused_token})", "could not run the command (#{too_old})")
  end

  it "queues and takes back through chi web, as the worker's features say" do
    allow(client).to receive(:post_turn).and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: JSON.generate(
      { enqueued_id: "q1", delivery: "queue" }
    )))
    allow(client).to receive(:dequeue).and_return(Samagotchi::BridgeClient::Response.new(status: 200, body: JSON.generate(
      { prompt: "later" }
    )))
    running = JSON.parse(JSON.generate(type: :turn_started, origin: { enqueued_id: "x", client_id: "web:1" }, prompt: "go"))

    run_with(["/queue later", "/unqueue", nil], events: [running])

    expect(client).to have_received(:post_turn).with(hash_including(prompt: "later", delivery: "queue"))
    expect(client).to have_received(:dequeue).with(enqueued_id: "q1", client_id: "tui:1@mac")
    expect(screen.lines).to include("removed: later")
  end

  describe "the stream's lines" do
    def closed(reason)
      attached.handle_event({ "type" => "stream_closed", "reason" => reason })
      screen.lines.last
    end

    it "says a reconnect once, and that it came back" do
      attached.handle_event({ "type" => "stream_retrying" })
      attached.handle_event({ "type" => "stream_resumed" })
      expect(screen.lines).to eq(["(lost the connection to studio; reconnecting…)", "(reconnected)"])
    end

    it "words a stream's refused Bridge secret with the remote chi invocation" do
      attached.handle_event({ "type" => "stream_closed", "reason" => "bridge_secret" })

      expect(screen.lines.last).to eq(
        "Lost the session's worker: #{Samagotchi::BridgeSecret.refused(client.session_id, via: remote.invocation)}"
      )
    end

    it "words each reason the stream ended for, naming the remote and what brings the session back" do
      expect(closed("stopped")).to eq("The session was stopped on studio. Resume it with: chi --remote studio --resume s-1234")
      expect(closed("worker_gone"))
        .to eq("The session's worker on studio is gone. Resume it with: chi --remote studio --resume s-1234")
      expect(closed("unknown_session")).to eq("The session is gone from studio (deleted).")
      expect(closed("unreachable")).to eq("Lost the connection to studio. Re-attach with: chi --remote studio --attach s-1234")

      allow(remote).to receive(:attach_worker)
        .and_raise(Samagotchi::SessionAccess::RemoteFailed, "remote studio (http://192.0.2.10:4567): connection refused")
      expect(attached.send(:live_worker)).to eq([nil, "unreachable"])
      expect(closed("unreachable"))
        .to eq("Lost the connection to studio (connection refused). Re-attach with: chi --remote studio --attach s-1234")

      allow(remote).to receive(:attach_worker).and_raise(Samagotchi::SessionAccess::AuthRefused, refused_token)
      expect(attached.send(:live_worker)).to eq([:gone, "auth_failed"])
      expect(closed("auth_failed")).to eq("Lost the session: #{refused_token}")
    end

    it "shows one restarted line when the worker changes, epoch first, then its reset" do
      allow(remote).to receive(:attach_worker).and_return(
        Samagotchi::SessionAccess::WorkerReply.new(live: true, stopped: false, worker: { "epoch" => "e2", "features" => [] },
                                                   strategy: nil)
      )
      allow(client).to receive(:worker_key=)
      attached.handle_event(joined)
      attached.handle_event({ "type" => "worker_changed", "port" => nil, "epoch" => "e2" })
      reset = JSON.parse(JSON.generate(type: :reset, snapshot: { messages: [], queued: [], event_seq: 1, chi_version: "1.2.3" },
                                       session_state_snapshot: { status: "idle", message_count: 0 }))
      attached.handle_event(reset)

      expect(screen.lines).to eq(["chi> the session's worker restarted on chi 1.2.3"])
      expect(client).to have_received(:worker_key=).with("e2")
    end
  end

  it "takes the status row's default model from that machine's config (the wake's)" do
    expect(attached.send(:default_model_name)).to eq("studio-default")
  end
end
