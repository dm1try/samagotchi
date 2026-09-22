# frozen_string_literal: true

require "samagotchi/engine"

# Engine#announce: transport-level facts (a turn was queued, queued input was
# merged into a running turn) that every live UI must see in the one ordered
# event log, but that are not part of a turn's own event stream.
RSpec.describe Samagotchi::Engine, "#announce" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Gemma-4B-it"
    example.run
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:engine) do
    described_class.new(mode: :assist, client: instance_double(Samagotchi::Client),
                        kernel: instance_double(Samagotchi::KernelLoop), profile: "gemma4")
  end

  it "numbers the event and fans it out to persistent observers" do
    seen = []
    engine.subscribe(observer: ->(e) { seen << e })
    before = engine.event_count

    engine.announce(type: :turn_enqueued, enqueued_id: "e1", client_id: "web:1", prompt: "hi")

    expect(seen).to eq([{ type: :turn_enqueued, enqueued_id: "e1", client_id: "web:1", prompt: "hi", event_seq: before + 1 }])
  end

  it "accepts only the listed event types" do
    expect { engine.announce(type: :turn_completed, result: nil) }.to raise_error(ArgumentError, /turn_completed/)
    expect(engine.event_count).to eq(0)
  end

  it "holds other emitters off while a block runs under #synchronize_events" do
    order = []
    engine.subscribe(observer: ->(e) { order << e[:type] })
    inside = Queue.new
    release = Queue.new

    holder = Thread.new do
      engine.synchronize_events do
        inside << true
        release.pop
        engine.announce(type: :turn_enqueued, enqueued_id: "e1")
      end
    ensure
      inside << false
    end
    expect(inside.pop).to be true
    other = Thread.new { engine.announce(type: :input_merged, origins: []) }
    sleep 0.05
    release << true
    [holder, other].each(&:join)

    expect(order).to eq(%i[turn_enqueued input_merged])
  end
end
