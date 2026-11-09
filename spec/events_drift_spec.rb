# frozen_string_literal: true

require "samagotchi/events"

# The event type sets in Samagotchi::Events against the places that spell
# them out on their own: the web's stream handlers (stream_handlers.js) and snapshot
# replay (turn_events.js), the TUI's handle_event, the Bridge's
# TurnAccumulator. Reads the sources; a rename on one side fails here.
RSpec.describe "Events drift" do
  root = File.expand_path("..", __dir__)
  read = ->(path) { File.read(File.join(root, path)) }
  # Other Ruby structs also use `type:` for schemas, message roles and
  # CardStore's question entry; these are not emitted event types.
  NON_EVENT_TYPES = %i[bool choice enum float integer noul object question string user].freeze
  # Context notes reload from the session messages. Turn completion is the
  # JoinReplay fallback branch (all ends except cancel/failure), not a case.
  JOIN_REPLAY_NOT_EXPLICIT = %i[context_added turn_completed].freeze
  # Synthetic merged input exists only while rebuilding a running turn.
  TUI_LIVE_NOT_EXPLICIT = %i[merged_input].freeze

  # The source between +start+ and the first line matching +stop+.
  def section(source, start, stop)
    from = source.index(start) or raise "#{start.inspect} not found"
    rest = source[from..]
    rest[0, rest.index(stop) || rest.length]
  end

  let(:web_handlers) do
    body = section(read.call("lib/samagotchi/web/public/stream_handlers.js"), "export function createStreamHandlers", /^  };$/)
    body.scan(/^    ([a-z_]+):/).flatten.map(&:to_sym)
  end

  let(:attached_cases) do
    body = section(read.call("lib/samagotchi/terminal_ui/attached_loop.rb"), "def handle_event(event)", /^      end$/)
    labels = body.scan(/^\s+when (.+?)(?: then|$)/).flatten.flat_map { |line| line.scan(/:([a-z_]+)/).flatten }
    (labels.map(&:to_sym) + Samagotchi::Events::TURN_END).uniq
  end

  let(:renderer_cases) do
    body = section(read.call("lib/samagotchi/terminal_ui/event_renderer.rb"), "def call(event)", /^      end$/)
    body.scan(/^\s+when (.+?)(?: then|$)/).flatten.flat_map { |line| line.scan(/:([a-z_]+)/).flatten }.map(&:to_sym)
  end

  let(:join_replay_events) do
    source = read.call("lib/samagotchi/terminal_ui/join_replay.rb")
    labels = source.scan(/^\s+when (.+?)(?: then|$)/).flatten.flat_map do |line|
      line.scan(/(?::|")([a-z_]+)/).flatten
    end
    (labels + source.scan(/event\[:type\] == :([a-z_]+)/).flatten).map(&:to_sym).uniq
  end

  let(:reload_events) do
    accumulator = read.call("lib/samagotchi/bridge/turn_accumulator.rb")
    cards = read.call("lib/samagotchi/bridge/card_store.rb")
    sources = [accumulator, cards]
    labels = sources.flat_map do |source|
      cases = source.scan(/^\s+when (.+?)(?: then|$)/).flatten.flat_map { |line| line.scan(/:([a-z_]+)/).flatten }
      cases + source.scan(/type: :([a-z_]+)/).flatten
    end
    (labels.map(&:to_sym) + Samagotchi::Events::TURN_END).uniq
  end

  # Every type some Ruby code emits: `type: :x` and `"type" => "x"`.
  let(:emitted_types) do
    Dir[File.join(root, "lib/**/*.rb")].flat_map do |path|
      text = File.read(path)
      text.scan(/type: :([a-z_]+)/).flatten + text.scan(/"type" => "([a-z_]+)"/).flatten
    end.map(&:to_sym).uniq - NON_EVENT_TYPES
  end

  let(:classified_types) do
    Samagotchi::Events::CLASSIFICATION.keys + Samagotchi::Events::STREAM_FRAMES + Samagotchi::Events::SYNTHETIC
  end

  it "classifies every emitted type, with no stale classifications" do
    expected = (emitted_types + Samagotchi::Events::STREAM_FRAMES + Samagotchi::Events::SYNTHETIC).uniq.sort
    expect(classified_types.uniq.sort).to eq(expected)
    expect(Samagotchi::Events::CLASSIFICATION.values.uniq - %i[row state transient internal]).to eq([])
  end

  it "has a web stream handler and a TUI case for each turn end" do
    expect(web_handlers).to include(*Samagotchi::Events::TURN_END)
    expect(attached_cases).to include(*Samagotchi::Events::TURN_END)
  end

  it "names only known event types in the web's stream handlers" do
    known = emitted_types + Samagotchi::Events::STREAM_FRAMES + Samagotchi::Events::SYNTHETIC
    expect(web_handlers - known).to eq([])
  end

  it "names only known event types in the TUI's handle_event" do
    known = emitted_types + Samagotchi::Events::STREAM_FRAMES
    expect(attached_cases - known).to eq([])
  end

  it "handles every row in the live UIs, reload stores and join replay" do
    rows = Samagotchi::Events::CLASSIFICATION.filter_map { |type, kind| type if kind == :row }
    live_ui_rows = rows - TUI_LIVE_NOT_EXPLICIT
    reload = reload_events - [:context_added]
    reload_rows = rows - [:context_added]
    replay = join_replay_events - JOIN_REPLAY_NOT_EXPLICIT
    replay_rows = rows - JOIN_REPLAY_NOT_EXPLICIT

    expect(web_handlers).to include(*rows)
    expect(attached_cases + renderer_cases).to include(*live_ui_rows)
    expect(reload).to include(*reload_rows)
    expect(replay).to include(*replay_rows)
  end

  it "replays the same turn part kinds in the web and the TUI as TurnAccumulator writes" do
    accumulator = read.call("lib/samagotchi/bridge/turn_accumulator.rb")
    written = accumulator.scan(/kind: "([a-z]+)"/).flatten + accumulator.scan(/append_text\([^,]+, "([a-z]+)"/).flatten
    replay = section(read.call("lib/samagotchi/web/public/turn_events.js"), "export function snapshotEvents", /^}$/)
    web_kinds = replay.scan(/^        case "([a-z]+)":/).flatten

    expected = Samagotchi::Events::PART_KINDS.sort
    expect(written.uniq.sort).to eq(expected)
    expect(web_kinds.uniq.sort).to eq(expected)
  end
end
