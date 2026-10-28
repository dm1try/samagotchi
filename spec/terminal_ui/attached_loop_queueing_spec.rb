# frozen_string_literal: true

require "json"
require "samagotchi/worker_link"
require_relative "../support/worker_fixtures"
require_relative "../support/worker_links"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require_relative "../support/recording_surface"

# Edit: /unqueue puts the removed text back in the input, to change and send
# again, as a failed turn's prompt comes back.
RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "a removed queued prompt" do
  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:typed) { Queue.new }
  let(:reads) { Queue.new }
  let(:echoes) { Queue.new }

  before do
    allow(client).to receive(:post_turn)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e1","delivery":"queue"}'))
    allow(client).to receive(:dequeue)
      .and_return(Samagotchi::BridgeClient::Response.new(status: 200, body: '{"status":"removed","enqueued_id":"e1","prompt":"fix the tests"}'))
    allow(client).to receive(:follow) do |&block|
      block.call("type" => "snapshot", "snapshot" => { "messages" => [], "current_turn" => nil, "queued" => [], "event_seq" => 1 })
      double("stream", close: nil)
    end
    # Each read reports its prefill, then blocks until the spec types; what
    # its echo (RelineSeam.echo_as) leaves for the line goes to echoes.
    @thread = Thread.new do
      attached.run(input: lambda { |_prompt, prefill|
        reads << prefill
        line = typed.pop
        echoes << Thread.current[:samagotchi_reline_echo]&.call(line.to_s)
        line
      })
    end
    expect(reads.pop(timeout: 2)).to be_nil
  end

  after do
    typed << nil
    join!(@thread, "the attached loop")
  end

  it "puts the removed text into the next read" do
    typed << "/queue fix the tests"
    expect(reads.pop(timeout: 2)).to be_nil
    typed << "/unqueue"

    # The read after the line opens empty; the removal then restarts it with the text.
    expect([reads.pop(timeout: 2), reads.pop(timeout: 2)]).to eq([nil, "fix the tests"])
    expect(screen.lines).to include("removed: fix the tests")
  end

  it "runs a command typed after the removed text as the command, and puts the text back" do
    typed << "/queue fix the tests"
    reads.pop(timeout: 2)
    typed << "/unqueue"
    2.times { reads.pop(timeout: 2) }

    # What the read holds once /unqueue is typed again without clearing it.
    typed << "fix the tests/unqueue"
    expect([reads.pop(timeout: 2), reads.pop(timeout: 2)]).to eq([nil, "fix the tests"])
    expect(client).to have_received(:post_turn).once
    expect(screen.lines).to include("(nothing queued: /queue TEXT queues a message for after the running turn)")

    typed << "fix the tests/queue later"
    expect([reads.pop(timeout: 2), reads.pop(timeout: 2)]).to eq([nil, "fix the tests"])
    expect(client).to have_received(:post_turn).with(prompt: "later", client_id: "tui:1")
    # The echo shows the command that ran, as a plain /unqueue's does.
    expect(Array.new(4) { echoes.pop(timeout: 2) }).to eq([nil, nil, "/unqueue", "/queue later"])
  end

  it "sends the removed text with more typed after it as one prompt, when the rest is no command" do
    typed << "/queue fix the tests"
    reads.pop(timeout: 2)
    typed << "/unqueue"
    2.times { reads.pop(timeout: 2) }

    sent = []
    allow(client).to receive(:post_turn) do |**options|
      sent << options[:prompt]
      Samagotchi::BridgeClient::Response.new(status: 202, body: '{"enqueued_id":"e2"}')
    end
    typed << "fix the tests/lib/a.rb"
    expect(reads.pop(timeout: 2)).to be_nil
    wait_for("the prompt sent") { sent.any? }
    expect(sent).to eq(["fix the tests/lib/a.rb"])
    expect(Array.new(3) { echoes.pop(timeout: 2) }).to eq([nil, nil, nil])
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "a delivery while a turn runs" do
  include WorkerFixtures

  let(:screen) { RecordingSurface.new(columns: 80) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234", host: "127.0.0.1", port: 1) }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:running_turn) do
    { "prompt" => "go", "origin" => { "client_id" => "web:1" }, "parts" => [] }
  end
  let(:snapshot) do
    { "type" => "snapshot",
      "snapshot" => { "messages" => [], "current_turn" => running_turn, "queued" => [], "event_seq" => 1 },
      "session_state_snapshot" => { "status" => "running" } }
  end

  before { allow(client).to receive(:follow) { |&block| block.call(snapshot); double("stream", close: nil) } }

  def reply(body, status: 202) = Samagotchi::BridgeClient::Response.new(status: status, body: JSON.generate(body))

  # Runs one attached session reading +lines+ in order (then Ctrl-D), with
  # the worker's 202 for each prompt.
  def run_inputs(*lines, ack: { "enqueued_id" => "e1", "delivery" => "next_step" })
    allow(client).to receive(:post_turn).and_return(reply(ack))
    attached.run(input: ->(_prompt, _prefill) { lines.shift })
  end

  it "sends a plain line as the default delivery (no delivery field) and says it goes in at the next step" do
    run_inputs("hello")

    expect(client).to have_received(:post_turn).once.with(prompt: "hello", client_id: "tui:1")
    expect(screen.lines).to include("(goes in at the next step)")
  end

  it "posts /cut TEXT as delivery cut, and prints the ack's outcome" do
    run_inputs("/cut drop the tests", ack: { "enqueued_id" => "e1", "delivery" => "cut", "cut" => "now" })

    expect(client).to have_received(:post_turn).once.with(prompt: "drop the tests", client_id: "tui:1", delivery: "cut")
    expect(screen.lines).to include("(cut in now)")
  end

  it "says cutting is off when the worker's ack says so, and waits when it queues the cut" do
    run_inputs("hello")
    run_inputs("/cut one", ack: { "enqueued_id" => "e1", "delivery" => "cut", "cut" => "waits" })
    run_inputs("/cut two", ack: { "enqueued_id" => "e1", "delivery" => "cut", "cut" => "off" })

    expect(screen.lines).to include("(goes in at the next step)", "(cuts in once the thinking passes 20 s)",
                                    "(cutting is off; goes in at the next step)")
  end

  it "says the seconds the worker's ack gives when the model's cut wait differs from the global" do
    run_inputs("/cut one", ack: { "enqueued_id" => "e1", "delivery" => "cut", "cut" => "waits", "cut_after" => 60 })

    expect(screen.lines).to include("(cuts in once the thinking passes 60 s)")
  end

  it "posts /queue TEXT as delivery queue while a turn runs, and says it runs after this turn" do
    run_inputs("/queue later please", ack: { "enqueued_id" => "e1", "delivery" => "queue" })

    expect(client).to have_received(:post_turn).once.with(prompt: "later please", client_id: "tui:1", delivery: "queue")
    expect(screen.lines).to include("(queued: runs after this turn)")
    expect(screen.lines).not_to include("(goes in at the next step)")
  end

  it "says a /queue runs as the next turn when the ack says the turn had ended (next_step)" do
    run_inputs("/queue later please", ack: { "enqueued_id" => "e1", "delivery" => "next_step" })

    expect(screen.lines).to include("(the turn had ended: runs as the next turn)")
    expect(screen.lines).not_to include("(goes in at the next step)", "(queued: runs after this turn)")
  end

  describe "/unqueue" do
    let(:removed) { [] }

    # Each prompt's ack in turn (queue unless given), then the worker's answer to each removal.
    def run_unqueue(*lines, acks: nil, answers: {})
      acks ||= Array.new(lines.count { |l| !l.start_with?("/unqueue") }) { |i| { "enqueued_id" => "e#{i + 1}", "delivery" => "queue" } }
      allow(client).to receive(:post_turn).and_return(*acks.map { |ack| reply(ack) })
      allow(client).to receive(:dequeue) do |enqueued_id:, client_id:|
        removed << [enqueued_id, client_id]
        status, body = answers.fetch(enqueued_id, [200, { "status" => "removed", "enqueued_id" => enqueued_id, "prompt" => "text of #{enqueued_id}" }])
        reply(body, status: status)
      end
      attached.run(input: ->(_prompt, _prefill) { lines.shift })
    end

    it "removes this client's newest queued message, then the one before it" do
      run_unqueue("/queue first", "/queue second", "/unqueue", "/unqueue", "/unqueue")

      expect(removed).to eq([%w[e2 tui:1], %w[e1 tui:1]])
      expect(screen.lines).to include("removed: text of e2", "removed: text of e1",
                                      "(nothing queued: /queue TEXT queues a message for after the running turn)")
    end

    it "takes only queued messages: a plain line or a /queue that ran as the next turn is not one" do
      run_unqueue("hello", "/queue later", "/unqueue",
                  acks: [{ "enqueued_id" => "e1", "delivery" => "next_step" }, { "enqueued_id" => "e2", "delivery" => "next_step" }])

      expect(removed).to eq([])
      expect(screen.lines).to include("(nothing queued: /queue TEXT queues a message for after the running turn)")
    end

    it "says when it already started or is gone, and forgets it either way" do
      run_unqueue("/queue a", "/queue b", "/unqueue", "/unqueue", "/unqueue",
                  answers: { "e2" => [409, { "error" => "already_started" }], "e1" => [404, { "error" => "unknown_enqueued_id" }] })

      expect(removed.map(&:first)).to eq(%w[e2 e1])
      expect(screen.lines).to include("(not removed: it already started)", "(not removed: it is already gone)")
    end

    it "clips a long removed line to its first 60 characters" do
      long = "x" * 80
      run_unqueue("/queue #{long}", "/unqueue", answers: { "e1" => [200, { "status" => "removed", "prompt" => "#{long}\nmore" }] })

      expect(screen.lines).to include("removed: #{"x" * 60}…")
    end

    it "forgets a queued message once its turn starts or another client removes it" do
      allow(client).to receive(:follow) do |&block|
        block.call(snapshot)
        @push = block
        double("stream", close: nil)
      end
      lines = ["/queue a", "/queue b", :started, :dequeued, "/unqueue"]
      allow(client).to receive(:post_turn).and_return(reply({ "enqueued_id" => "e1", "delivery" => "queue" }),
                                                      reply({ "enqueued_id" => "e2", "delivery" => "queue" }))
      allow(client).to receive(:dequeue)
      attached.run(input: lambda { |_prompt, _prefill|
        line = lines.shift
        case line
        when :started then @push.call("type" => "turn_started", "prompt" => "a", "origin" => { "client_id" => "tui:1", "enqueued_id" => "e1" })
        when :dequeued then @push.call("type" => "turn_dequeued", "enqueued_id" => "e2", "client_id" => "web:2")
        else next line
        end
        # The event is queued before this empty line, so the loop takes it first.
        ""
      })

      expect(client).not_to have_received(:dequeue)
      expect(screen.lines).to include("(nothing queued: /queue TEXT queues a message for after the running turn)")
    end

    describe "to a worker without the route" do
      let(:state_dir) { Dir.mktmpdir }
      let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", state_dir: state_dir) }

      after { FileUtils.rm_rf(state_dir) }

      it "asks nothing of a worker whose sidecar lacks unqueue, and says it needs a newer one" do
        live_sidecar_fixture(Samagotchi::Session.session_dir("s-1234", state_dir: state_dir), port: 1, session_id: "s-1234",
                                                                                               features: %w[restart task_stop reparent delivery])
        run_unqueue("/queue later", "/unqueue")

        expect(removed).to eq([])
        expect(screen.lines).to include(a_string_including("/unqueue needs a newer worker"))
      end
    end
  end

  describe "to a worker that can't queue" do
    let(:state_dir) { Dir.mktmpdir }
    let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", state_dir: state_dir) }

    after { FileUtils.rm_rf(state_dir) }

    it "sends nothing when its sidecar names no delivery feature (it would steer), and says to restart it" do
      live_sidecar_fixture(Samagotchi::Session.session_dir("s-1234", state_dir: state_dir), port: 1, session_id: "s-1234",
                                                                                             features: %w[restart task_stop reparent])
      run_inputs("/queue later please", "/cut now please", ack: { "enqueued_id" => "e1", "delivery" => "cut", "cut" => "now" })

      expect(client).to have_received(:post_turn).once.with(prompt: "now please", client_id: "tui:1", delivery: "cut")
      expect(screen.lines).to include(a_string_including("/queue needs a newer worker"))
    end

    it "says the same when the worker refuses the queue (a P0-P2 worker's 400 delivery_unavailable)" do
      allow(client).to receive(:post_turn).and_return(reply({ "error" => "delivery_unavailable", "detail" => "x" }, status: 400))
      lines = ["/queue later please"]
      attached.run(input: ->(_prompt, _prefill) { lines.shift })

      expect(screen.lines).to include(a_string_including("/queue needs a newer worker"))
      expect(screen.lines.grep(/could not send/)).to be_empty
    end
  end

  it "notes another client's queued prompt as queued at its turn_enqueued" do
    allow(client).to receive(:follow) do |&block|
      block.call(snapshot)
      block.call("type" => "turn_enqueued", "enqueued_id" => "e9", "client_id" => "web:2", "prompt" => "after this",
                 "delivery" => "queue")
      double("stream", close: nil)
    end
    run_inputs

    expect(screen.lines.grep(/after this/)).to contain_exactly(a_string_ending_with("after this (queued: runs after this turn)"))
  end

  it "says when another client's queued prompt it showed is removed, and nothing for one it never showed" do
    allow(client).to receive(:follow) do |&block|
      block.call(snapshot)
      block.call("type" => "turn_enqueued", "enqueued_id" => "e9", "client_id" => "web:2", "prompt" => "after this",
                 "delivery" => "queue")
      block.call("type" => "turn_dequeued", "enqueued_id" => "e9", "client_id" => "web:2")
      block.call("type" => "turn_dequeued", "enqueued_id" => "e10", "client_id" => "web:2")
      double("stream", close: nil)
    end
    run_inputs

    expect(screen.lines.grep(/removed/)).to eq(["(a queued message was removed)"])
  end

  it "runs /queue TEXT and /cut TEXT at an idle prompt as plain turns (no delivery)" do
    snapshot["snapshot"]["current_turn"] = nil
    snapshot["session_state_snapshot"]["status"] = "idle"
    run_inputs("/queue later please", "/cut now please")

    expect(client).to have_received(:post_turn).with(prompt: "later please", client_id: "tui:1").ordered
    expect(client).to have_received(:post_turn).with(prompt: "now please", client_id: "tui:1").ordered
    expect(screen.lines).not_to include("(queued: runs after this turn)")
    expect(screen.lines.grep(/nothing is running/)).to eq(["(nothing is running: sent now)"] * 2)
  end

  it "says a /cut with no text is a usage error, and sends nothing" do
    run_inputs("/cut", "/queue")

    expect(client).not_to have_received(:post_turn)
    expect(screen.lines.grep(/need a message/).size).to eq(2)
  end
end
