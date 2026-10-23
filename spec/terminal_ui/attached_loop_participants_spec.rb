# frozen_string_literal: true

require "json"
require "samagotchi/terminal_ui"
require "samagotchi/terminal_ui/attached_loop"
require "samagotchi/terminal_ui/status_row"
require_relative "../support/recording_surface"

# The owner's attached TUI on a reviewed session: a participant's prompts
# led by their name, a line when one is invited, revoked or expires, and
# the status row's count.
RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "participants" do
  let(:screen) { RecordingSurface.new(columns: 100) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1") }
  let(:alex) { { id: "p_aaaa1111", name: "Alex", kind: "human" } }

  before { allow(Samagotchi::ChildrenStatus).to receive(:counts).and_return(nil) }

  def feed(*events)
    events.map { |e| attached.handle_event(JSON.parse(JSON.generate(e))) }
  end

  def snapshot(messages: [], queued: [], current_turn: nil, participants: [alex])
    { type: :snapshot, snapshot: { messages: messages, current_turn: current_turn, queued: queued, event_seq: 9 },
      session_state_snapshot: { status: "idle", message_count: messages.size, participants: participants } }
  end

  it "leads a participant's queued and started prompts with their name; the owner's lines stay as they were" do
    feed(snapshot,
         { type: :turn_enqueued, enqueued_id: "e1", client_id: "review:p_aaaa1111", prompt: "is step 3 right?",
           delivery: "queue", author: "p:p_aaaa1111" },
         { type: :turn_enqueued, enqueued_id: "e2", client_id: "web:tab", prompt: "mine", delivery: "queue" },
         { type: :turn_started, prompt: "unseen", turn_id: "t1",
           origin: { client_id: "review:p_bbbb2222", enqueued_id: "e3", author: "p:p_bbbb2222" } })

    expect(screen.lines).to include("Alex ▸ review> is step 3 right? (queued: runs after this turn)",
                                    "web> mine (queued: runs after this turn)",
                                    "p_bbbb2222 ▸ review> unseen")
  end

  it "names the participant in the join's last exchange, its queued rows and its running turn" do
    feed(snapshot(messages: [{ role: "user", content: "older", author: "p:p_aaaa1111", author_name: "Alex" },
                             { role: "model", content: "an answer" }],
                  queued: [{ enqueued_id: "e1", client_id: "review:p_aaaa1111", prompt: "next", author: "p:p_aaaa1111" }],
                  current_turn: { prompt: "now", origin: { client_id: "review:p_aaaa1111", author: "p:p_aaaa1111" },
                                  events: [] }))

    expect(screen.lines).to include("Alex ▸ review> older", "Alex ▸ review> now", "queued Alex ▸ review> next")
  end

  it "says who joined and who left, and why, and counts them on the status row" do
    allow_any_instance_of(Samagotchi::TerminalUI::StatusRow).to receive(:status_line_enabled?).and_return(true)
    feed(snapshot)
    expect(screen.slots[:status].first).to include("1 participant")

    feed({ type: :participants_changed, participants: [alex, { id: "p_cccc3333", name: "Bot", kind: "agent" }],
           joined: [{ id: "p_cccc3333", name: "Bot", kind: "agent" }], left: [] },
         { type: :participants_changed, participants: [],
           joined: [], left: [alex.merge(reason: "revoked"), { id: "p_cccc3333", name: "Bot", kind: "agent", reason: "expired" }] })

    expect(screen.lines).to eq(["participants> Bot joined (p_cccc3333, an agent)",
                                "participants> Alex left: their link was revoked",
                                "participants> Bot left: their link expired"])
    expect(screen.slots[:status]).to be_nil
    # One who left is still named on a line of theirs.
    feed({ type: :turn_enqueued, enqueued_id: "e1", client_id: "review:p_cccc3333", prompt: "late", author: "p:p_cccc3333" })
    expect(screen.lines.last).to eq("Bot ▸ review> late")
  end

  it "cleans a name before it reaches the terminal" do
    feed(snapshot(participants: [{ id: "p_aaaa1111", name: "Al\e[31mex\n[x]", kind: "human" }]),
         { type: :turn_enqueued, enqueued_id: "e1", client_id: "review:p_aaaa1111", prompt: "hi", author: "p:p_aaaa1111" })
    expect(screen.lines.last).to eq("Al 31mex x ▸ review> hi")
  end
end
