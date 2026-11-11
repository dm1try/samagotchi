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
  let(:non_event_types) { %i[bool choice enum float integer noul object question string user] }
  # Context notes reload from the session messages. Turn completion is the
  # JoinReplay fallback branch (all ends except cancel/failure), not a case.
  let(:join_replay_not_explicit) { %i[context_added turn_completed] }
  # Synthetic merged input exists only while rebuilding a running turn.
  let(:tui_live_not_explicit) { %i[merged_input] }
  let(:web_handlers) do
    body = section(read.call("lib/samagotchi/web/public/stream_handlers.js"), "export function createStreamHandlers", /^  };$/)
    body.scan(/^    ([a-z_]+):/).flatten.map(&:to_sym)
  end
  let(:attached_cases) do
    body = section(read.call("lib/samagotchi/terminal_ui/attached_loop.rb"), "def handle_event(event)", /^      end$/)
    labels = body.scan(/^\s+when (.+?)(?: then|$)/).flatten.flat_map { |line| line.scan(/:([a-z_]+)/).flatten }
    labels.map(&:to_sym).uniq
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
    # TurnAccumulator#fold and CardStore#fold handle turn ends via Events::TURN_END.
    (labels.map(&:to_sym) + Samagotchi::Events::TURN_END).uniq
  end
  # Every type some Ruby code emits: `type: :x` and `"type" => "x"`.
  let(:emitted_types) do
    Dir[File.join(root, "lib/**/*.rb")].flat_map do |path|
      text = File.read(path)
      text.scan(/type: :([a-z_]+)/).flatten + text.scan(/"type" => "([a-z_]+)"/).flatten
    end.map(&:to_sym).uniq - non_event_types
  end
  let(:classified_types) do
    Samagotchi::Events::CLASSIFICATION.keys + Samagotchi::Events::STREAM_FRAMES + Samagotchi::Events::SYNTHETIC
  end

  # The source between +start+ and the first line matching +stop+.
  def section(source, start, stop)
    from = source.index(start) or raise "#{start.inspect} not found"
    rest = source[from..]
    rest[0, rest.index(stop) || rest.length]
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
    live_ui_rows = rows - tui_live_not_explicit
    reload = reload_events - [:context_added]
    reload_rows = rows - [:context_added]
    replay = join_replay_events - join_replay_not_explicit
    replay_rows = rows - join_replay_not_explicit

    expect(web_handlers).to include(*rows)
    expect(attached_cases + renderer_cases).to include(*live_ui_rows)
    expect(reload).to include(*reload_rows)
    expect(replay).to include(*replay_rows)
  end

  it "has each row event synthesized into a turn drawing made from messages, or declared lost" do
    require "samagotchi/bridge/turn_drawings/synth"
    synth = Samagotchi::Bridge::TurnDrawings::Synth
    rows = Samagotchi::Events::CLASSIFICATION.filter_map { |type, kind| type if kind == :row }
    emitted = read.call("lib/samagotchi/bridge/turn_drawings/synth.rb").scan(/type: :([a-z_]+)/).flatten.map(&:to_sym)

    expect(rows - synth::SYNTHESIZED - synth::LOSSES.keys).to eq([])
    expect(synth::SYNTHESIZED & synth::LOSSES.keys).to eq([])
    # What it says it synthesizes, it emits: a turn end by its END_TYPES, a
    # CardStore row by the entry's own type, a merged line as the input part
    # TurnAccumulator replays as merged_input.
    indirect = Samagotchi::Events::TURN_END + %i[hook_notice empty_answer_retry steer_cut llm_context_edited merged_input]
    expect(synth::SYNTHESIZED - emitted - indirect).to eq([])
  end

  # One replay for both UIs: the TUI's replay_events, which the web's
  # join_events (chi web's `replay`) unfolds too.
  it "replays every turn part kind TurnAccumulator writes" do
    accumulator = read.call("lib/samagotchi/bridge/turn_accumulator.rb")
    written = accumulator.scan(/kind: "([a-z]+)"/).flatten + accumulator.scan(/append_text\([^,]+, "([a-z]+)"/).flatten
    replay = section(accumulator, "def self.replay_events", /^      end$/)
    replayed = replay.scan(/^ *when "([a-z]+)"/).flatten

    expected = Samagotchi::Events::PART_KINDS.sort
    expect(written.uniq.sort).to eq(expected)
    expect(replayed.uniq.sort).to eq(expected)
  end
end
