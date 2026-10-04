# frozen_string_literal: true

require "samagotchi/events"

# The event type sets in Samagotchi::Events against the places that spell
# them out on their own: the web's stream handlers (app.js) and snapshot
# replay (turn_events.js), the TUI's handle_event, the Bridge's
# TurnAccumulator. Reads the sources; a rename on one side fails here.
RSpec.describe "Events drift" do
  root = File.expand_path("..", __dir__)
  read = ->(path) { File.read(File.join(root, path)) }

  # The source between +start+ and the first line matching +stop+.
  def section(source, start, stop)
    from = source.index(start) or raise "#{start.inspect} not found"
    rest = source[from..]
    rest[0, rest.index(stop) || rest.length]
  end

  let(:web_handlers) do
    body = section(read.call("lib/samagotchi/web/public/app.js"), "const streamHandlers = {", /^};$/)
    body.scan(/^  ([a-z_]+):/).flatten.map(&:to_sym)
  end

  let(:attached_cases) do
    body = section(read.call("lib/samagotchi/terminal_ui/attached_loop.rb"), "def handle_event(event)", /^      end$/)
    body.scan(/^\s+when (.+?)(?: then|$)/).flatten.flat_map { |labels| labels.scan(/:([a-z_]+)/).flatten }.map(&:to_sym)
  end

  # Every type some Ruby code emits: `type: :x` and `"type" => "x"`.
  let(:emitted_types) do
    Dir[File.join(root, "lib/**/*.rb")].flat_map do |path|
      text = File.read(path)
      text.scan(/type: :([a-z_]+)/).flatten + text.scan(/"type" => "([a-z_]+)"/).flatten
    end.map(&:to_sym).uniq
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
