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

  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "gemma4", working_directory: Dir.pwd).tap(&:save)
  end
  let(:cards_path) { File.join(Samagotchi::Session.session_dir(session.id), "cards.json") }

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
end
