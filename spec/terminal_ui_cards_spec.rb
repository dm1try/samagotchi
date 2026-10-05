# frozen_string_literal: true

require "tmpdir"
require "json"
require "samagotchi/terminal_ui"
require_relative "support/recording_surface"

# A plain (--no-shared) REPL keeps the session's cards.json as a worker's
# Bridge does: its turns count on from the saved count, so a card an
# earlier worker showed stays that many turns back.
RSpec.describe "TerminalUI cards.json" do
  let(:state_home) { Dir.mktmpdir("tui-cards-state") }
  let(:client) { instance_double(Samagotchi::Client) }
  let(:surface) { RecordingSurface.new }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd).tap(&:save)
  end
  let(:cards_path) { File.join(Samagotchi::Session.session_dir(session.id), "cards.json") }

  around do |example|
    saved = ENV.to_h.slice("SAMAGOTCHI_DEFAULT_MODEL", "XDG_STATE_HOME")
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "gemma4"
    ENV["XDG_STATE_HOME"] = state_home
    example.run
  ensure
    %w[SAMAGOTCHI_DEFAULT_MODEL XDG_STATE_HOME].each { |k| ENV.delete(k) }
    saved.each { |k, v| ENV[k] = v }
    FileUtils.remove_entry(state_home)
  end

  it "counts the REPL's kept turns on from the saved count; a failed one doesn't count" do
    FileUtils.mkdir_p(File.dirname(cards_path))
    card = { type: "card", id: "c1", source: "x", title: "t", body: "b", in_turn: false, turns: 1 }
    File.write(cards_path, JSON.generate({ version: 1, turns: 2, entries: [card] }))
    ui = Samagotchi::TerminalUI.new(client: client, session_id: session.id, surface: surface)
    observer = ui.engine.instance_variable_get(:@session_observer)
    allow(ui).to receive(:poll_input_with_reminder_check) do
      [%i[turn_started turn_completed], %i[turn_started turn_failed], %i[turn_started turn_canceled]].each do |pair|
        pair.each { |type| observer.notify({ type: type }) }
      end
      "/exit"
    end
    allow(ui).to receive(:keep_after_exit)

    ui.run

    saved = JSON.parse(File.read(cards_path))
    expect(saved["turns"]).to eq(4)
    expect(Samagotchi::Bridge::CardStore.saved(File.dirname(cards_path)).first).to include(id: "c1", turns_since: 3)
  end

  it "writes no cards.json for a session that never showed a card" do
    ui = Samagotchi::TerminalUI.new(client: client, session_id: session.id, surface: surface)
    observer = ui.engine.instance_variable_get(:@session_observer)
    written = nil
    allow(ui).to receive(:poll_input_with_reminder_check) do
      %i[turn_started turn_completed].each { |type| observer.notify({ type: type }) }
      written = File.exist?(cards_path)
      "/exit"
    end
    allow(ui).to receive(:keep_after_exit)

    ui.run

    expect(written).to be false
  end

  # The web hub reads pending_card.json to mark a session as waiting on an
  # open card with actions (a worker's Bridge writes it); the REPL keeps the
  # same file, so a card it shows is on disk too.
  it "keeps the running turn's open card in pending_card.json, and the card's resolution removes it" do
    dir = Samagotchi::Session.session_dir(session.id)
    pending_path = File.join(dir, Samagotchi::Bridge::PendingCard::FILE)
    ui = Samagotchi::TerminalUI.new(client: client, session_id: session.id, surface: surface)
    observer = ui.engine.instance_variable_get(:@session_observer)
    open_card = { type: :card, id: "check-in-1", source: "check-in", title: "3 tool calls", body: "", in_turn: true,
                  actions: [{ label: "Nudge", command: "/checkin nudge" }] }
    seen = {}
    allow(ui).to receive(:poll_input_with_reminder_check) do
      observer.notify({ type: :turn_started })
      observer.notify(open_card)
      seen[:open] = Samagotchi::Bridge::PendingCard.read(dir)
      observer.notify(open_card.merge(actions: []))
      seen[:resolved] = File.exist?(pending_path)
      "/exit"
    end
    allow(ui).to receive(:keep_after_exit)

    ui.run

    expect(seen[:open]).to eq(id: "check-in-1", bundle: "check-in")
    expect(seen[:resolved]).to be false
    expect(Samagotchi::Bridge::PendingCard.read(dir)).to be_nil
  end

  # A Bridge and the REPL never run one session at once (the OwnerLock), but
  # the REPL's own Engine may already carry a PendingCard: subscribing one
  # more for the same folder would fold every card twice (and clear the file
  # on one turn's end while the other still holds it).
  it "subscribes one PendingCard per session folder" do
    ui = Samagotchi::TerminalUI.new(client: client, session_id: session.id, surface: surface)
    created = 0
    allow(Samagotchi::Bridge::PendingCard).to receive(:new).and_wrap_original do |original, *args|
      created += 1
      original.call(*args)
    end

    ui.send(:keep_cards, session)
    second = ui.send(:keep_pending_card, session)

    expect(second).to be_nil
    expect(created).to eq(1)
  end
end
