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

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "/share and /participants" do
  let(:screen) { RecordingSurface.new(columns: 100) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", state_dir: "/state") }

  it "runs chi share for this session through the link's access, mid-turn too, and sends no prompt" do
    commands = instance_double(Samagotchi::TerminalUI::ParticipantCommands)
    allow(Samagotchi::TerminalUI::ParticipantCommands).to receive(:new).and_return(commands)
    allow(commands).to receive(:run) { |line| "ran #{line}" }
    attached.instance_variable_set(:@running, true)

    attached.send(:submit_line, "/share Alex")
    attached.send(:submit_line, "/participants revoke p_aaaa1111")

    expect(screen.lines).to eq(["ran /share Alex", "ran /participants revoke p_aaaa1111"])
    expect(Samagotchi::TerminalUI::ParticipantCommands).to have_received(:new).once
      .with(access: an_instance_of(Samagotchi::SessionAccess::Local), session_id: "s-1234", tty: anything)
  end
end

RSpec.describe Samagotchi::TerminalUI::AttachedLoop, "its own /share and /participants revoke" do
  let(:screen) { RecordingSurface.new(columns: 100) }
  let(:client) { instance_double(Samagotchi::BridgeClient, session_id: "s-1234") }
  let(:attached) { described_class.new(client: client, screen: screen, client_id: "tui:1", state_dir: "/state") }
  let(:access) { instance_double(Samagotchi::SessionAccess::Local) }
  let(:alex) { { id: "p_aaaa1111", name: "Alex", kind: "human" } }
  let(:grant) do
    Samagotchi::SessionAccess::ParticipantView.new(
      id: "p_aaaa1111", session_id: "s-1234", kind: "human", name: "Alex", role: "reviewer",
      created_at: "2026-10-23T10:00:00Z", expires_at: "2026-10-30T10:00:00Z", revoked_at: nil, revoked_by: nil,
      last_used_at: nil, state: "active", cap: 2.0, queue: 3
    )
  end

  before do
    allow(Samagotchi::ChildrenStatus).to receive(:counts).and_return(nil)
    allow(Samagotchi::TerminalUI::ParticipantCommands).to(receive(:new)
      .and_wrap_original { |original, **kwargs| original.call(**kwargs, access: access) })
    allow(access).to receive(:resolve) { |id| id }
    allow(access).to receive_messages(
      invite: Samagotchi::SessionAccess::Invitation.new(participant: grant, token: "chp_x", link: "http://10.0.0.2:4567/?token=chp_x#s=s-1234", lan: true),
      revoke_participants: [grant]
    )
  end

  def changed(joined: [], left: [])
    attached.handle_event(JSON.parse(JSON.generate({ type: :participants_changed, participants: joined, joined: joined, left: left })))
  end

  it "isn't announced again when the worker says it, once; another's change still is" do
    attached.send(:submit_line, "/share Alex")
    shown = screen.lines.size
    changed(joined: [alex])
    expect(screen.lines.size).to eq(shown)

    attached.send(:submit_line, "/participants revoke p_aaaa1111")
    shown = screen.lines.size
    changed(left: [alex.merge(reason: "revoked")])
    expect(screen.lines.size).to eq(shown)

    # Invited again elsewhere (the web, chi share): said.
    changed(joined: [alex])
    expect(screen.lines.last).to eq("participants> Alex joined (p_aaaa1111)")
  end
end

RSpec.describe Samagotchi::TerminalUI::ParticipantCommands do
  let(:access) { instance_double(Samagotchi::SessionAccess::Local) }
  let(:commands) { described_class.new(access: access, session_id: "abcdef12-0000", tty: false) }
  let(:grant) do
    Samagotchi::SessionAccess::ParticipantView.new(
      id: "p_aaaa1111", session_id: "abcdef12-0000", kind: "human", name: "Alex Smith", role: "reviewer",
      created_at: "2026-10-23T10:00:00Z", expires_at: "2026-10-30T10:00:00Z", revoked_at: nil, revoked_by: nil,
      last_used_at: nil, state: "active", cap: 2.0, queue: 3
    )
  end

  before { allow(access).to receive(:resolve) { |id| id } }

  it "/share NAME invites through chi share's access and words: the link once" do
    allow(access).to receive(:invite).and_return(
      Samagotchi::SessionAccess::Invitation.new(participant: grant, token: "chp_x", link: "http://10.0.0.2:8080/?token=chp_x#s=abcdef12", lan: true)
    )
    out = commands.run("/share Alex Smith --cap 5 --expires 3d")

    expect(access).to have_received(:invite).with("abcdef12-0000", name: "Alex Smith", kind: "human", ttl: 3 * 86_400, cap: 5.0)
    expect(out.lines.map(&:chomp)).to eq(["p_aaaa1111  Alex Smith (human, reviewer) · session abcdef12 · expires " \
                                          "#{Time.iso8601(grant.expires_at).localtime.strftime("%Y-%m-%d %H:%M")} · cap $2.00",
                                          "http://10.0.0.2:8080/?token=chp_x#s=abcdef12",
                                          "(shown once: chi keeps only its digest; chi share revoke abcdef12 p_aaaa1111 ends it)"])
  end

  it "says how to use /share and /participants, and leads chi share's refusals with the command typed" do
    expect(commands.run("/share")).to eq(described_class::SHARE_USAGE)
    expect(commands.run("/share --agent")).to eq(described_class::SHARE_USAGE)
    expect(commands.run("/participants list")).to eq(described_class::PARTICIPANTS_USAGE)
    expect(commands.run("/share Alex --expires 90d")).to eq("/share: --expires takes Nh or Nd, 1h to 30d (e.g. 3d) (see /share --help)")
    expect(commands.run("/participants revoke bob")).to start_with("/participants revoke: not a participant: bob")
  end

  it "/participants lists, revokes and caps this session's" do
    allow(access).to receive_messages(participants: [grant], revoke_participants: [grant], set_participant_cap: grant)

    expect(commands.run("/participants")).to include("PARTICIPANT", "p_aaaa1111   Alex Smith  human")
    expect(access).to have_received(:participants).with("abcdef12-0000")
    expect(commands.run("/participants revoke p_aaaa1111")).to eq("p_aaaa1111  Alex Smith  revoked")
    expect(access).to have_received(:revoke_participants).with("abcdef12-0000", participant: "p_aaaa1111")
    expect(commands.run("/participants cap p_aaaa1111 5")).to eq("p_aaaa1111  Alex Smith  cap $2.00")
  end

  it "words a remote's refusal as chi --remote share does, led by the command" do
    allow(access).to receive(:participants).and_raise(Samagotchi::SessionAccess::RemoteFailed, "remote studio: unreachable")
    expect(commands.run("/participants")).to eq("/participants: remote studio: unreachable")
  end
end
