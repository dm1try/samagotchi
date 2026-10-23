# frozen_string_literal: true

require "samagotchi/engine"
require "samagotchi/session"
require "samagotchi/client"
require "samagotchi/kernel_loop"
require "samagotchi/session_commands"
require "samagotchi/turn_flow"
require "tmpdir"
require_relative "support/fake_provider_server"

# The working set's :working_set_updated event (WorkingSet), through the real
# Engine and KernelLoop over HTTP: at each request after a tool ran and at
# turn end, only when the set changed, never while it is empty — except one
# empty event when the set was emptied (a rollback removed the tool calls).
RSpec.describe Samagotchi::Engine, "working set event" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "gemma-4-e4b"
    Dir.mktmpdir("ws-engine") do |dir|
      @dir = dir
      FakeProviderServer.without_webmock { example.run }
    end
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:server) { FakeProviderServer.start }
  let(:client) { Samagotchi::Client.new(host: "127.0.0.1", port: server.port, sleeper: ->(_s) {}) }
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "gemma-4-e4b", working_directory: @dir) }
  let(:kernel) { Samagotchi::KernelLoop.new(client: client, profile: Samagotchi::ModelProfile.normalize("gemma4")) }
  let(:engine) { described_class.new(client: client, kernel: kernel, profile: "gemma4") }
  let(:events) { [] }
  let(:path) { File.join(@dir, "notes.txt") }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    File.write(path, "one\ntwo\n")
  end

  after { server.stop }

  def stream(*pieces)
    server.enqueue("/completion", sse: pieces.map { |piece| "data: #{JSON.generate(content: piece)}\n\n" } +
                                       ["data: #{JSON.generate(content: "", stop: true)}\n\n"])
  end

  def run_turn(prompt = "hi") = engine.run_turn(session, prompt, on_event: ->(e) { events << e })

  def updates = events.select { |e| e[:type] == :working_set_updated }

  it "emits the set at the request after a tool ran, and not again at turn end when it didn't change" do
    stream(%(<|tool_call>call:read{path:<|"|>#{path}<|"|>}<tool_call|>))
    stream("Read it.")

    run_turn

    expect(updates.size).to eq(1)
    expect(updates.first[:items]).to match([include(kind: "file", key: path, state: "live", ops: %w[read], count: 1)])
    expect(updates.first[:at]).to be_a(Integer)
    started = events.index { |e| e[:type] == :generation_started && e[:iteration] == 2 }
    expect(events.index(updates.first)).to be > started
  end

  it "emits it again when it changed: the file changed outside chi since the model read it" do
    stream(%(<|tool_call>call:read{path:<|"|>#{path}<|"|>}<tool_call|>))
    stream("Read it.")
    run_turn
    File.write(path, "one\ntwo\nthree\n")
    stream("Still here.")

    run_turn("again")

    expect(updates.map { |u| u[:items].first[:state] }).to eq(%w[live stale])
  end

  it "emits it at turn end when the turn's last step ran a tool no request followed (out of iterations)" do
    stream(%(<|tool_call>call:read{path:<|"|>#{path}<|"|>}<tool_call|>))

    engine.run_turn(session, "hi", on_event: ->(e) { events << e }, max_iterations: 1)

    expect(updates.size).to eq(1)
    expect(events.index(updates.first)).to be > events.rindex { |e| e[:type] == :tool_call_completed }
    expect(events.index(updates.first)).to be < events.index { |e| e[:type] == :turn_completed }
  end

  it "emits nothing for a tool-free turn" do
    stream("Hello.")

    run_turn

    expect(updates).to be_empty
  end

  describe "a set that was non-empty and is emptied (a rollback removed the tool calls)" do
    before do
      stream(%(<|tool_call>call:read{path:<|"|>#{path}<|"|>}<tool_call|>))
      stream("Read it.")
      engine.session = session
      @checkpoint = engine.messages_checkpoint
      run_turn
      expect(updates.size).to eq(1)
      expect(updates.first[:items]).not_to be_empty
    end

    it "sends exactly one empty event, at the next request" do
      engine.rollback_to(@checkpoint)
      stream("Hello.")

      run_turn("again")

      empties = updates.select { |u| u[:items].empty? }
      expect(updates.size).to eq(2)
      expect(empties.size).to eq(1)
      expect(empties.first[:items]).to eq([])
      expect(empties.first[:at]).to be_a(Integer)
    end

    it "sends nothing for a second empty request after the empty one" do
      engine.rollback_to(@checkpoint)
      stream("Hello.")
      run_turn("again")

      stream("Hi again.")
      run_turn("and again")

      empties = updates.select { |u| u[:items].empty? }
      expect(updates.size).to eq(2)
      expect(empties.size).to eq(1)
    end
  end

  describe "between turns (#announce_working_set)" do
    let(:announced) { [] }

    before do
      stream(%(<|tool_call>call:read{path:<|"|>#{path}<|"|>}<tool_call|>))
      stream("Read it.")
      engine.session = session
      run_turn
      engine.subscribe(observer: ->(e) { announced << e if e[:type] == :working_set_updated })
    end

    def forget_the_read!
      entry = session.messages.find { |m| m[:role].to_s == "tool_response" }
      now = "2026-10-23T10:00:00.000Z"
      entry[:edits] = { entry[:tool_ids].first => { "kind" => "forget", "note" => "notes", "by" => "model",
                                                    "staged_at" => now, "applied_at" => now } }
    end

    it "announces nothing when the set didn't change since the last one emitted" do
      engine.announce_working_set

      expect(announced).to be_empty
    end

    it "announces the set under the next turn's strategy, not the last turn's, outside any turn's sink" do
      forget_the_read!
      engine.announce_working_set
      expect(announced).to be_empty # the last turn's strategy is none: still live, no change

      session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:forget])
      engine.announce_working_set

      expect(kernel.turn_settings.llm_context.strategy).to eq(:none)
      expect(announced.size).to eq(1)
      expect(announced.first[:items]).to match([include(key: path, state: "forgotten")])
      expect(announced.first[:event_seq]).to be_a(Integer)
      expect(updates.size).to eq(1)
    end

    it "is announceable" do
      expect(described_class::ANNOUNCEABLE_EVENTS).to include(:working_set_updated)
    end
  end

  # /working-set drop between turns (WorkingSetSteer): the native loop's
  # next request is the first with the stub and the turn-start note, the
  # set is announced dropped, and undrop sends the output whole again.
  describe "a /working-set drop between turns" do
    let(:announced) { [] }
    let(:commands) do
      Samagotchi::SessionCommands.new(engine: engine, turn_flow: Samagotchi::TurnFlow.new(engine: engine), default_model: nil,
                                      save: ->(_session) {})
    end
    let(:stub) { Samagotchi::LLMContextEdit::DROP_STUB }

    before do
      File.write(path, "the original text\n")
      stream(%(<|tool_call>call:read{path:<|"|>#{path}<|"|>}<tool_call|>))
      stream("Read it.")
      engine.session = session
      run_turn
      engine.subscribe(observer: ->(e) { announced << e if e[:type] == :working_set_updated })
    end

    def prompt_of(request) = request.json["prompt"].to_s

    it "sends the stub and one note from the next turn's first request; undrop brings the output back" do
      expect(prompt_of(server.requests.last)).to include("the original text")

      result = commands.run("/working-set drop notes.txt")

      expect(result).to have_attributes(status: :ok, changed: [:messages])
      expect(result.output).to match(/\Adropped notes\.txt \(t\d+\): the next turn's first request sends the stubs/)
      expect(announced.last[:items]).to match([include(key: path, state: "dropped")])

      stream("Ok.")
      run_turn("go on")
      sent = prompt_of(server.requests.last)
      expect(sent).to include(stub)
      expect(sent).not_to include("the original text")
      expect(sent.scan("[WORKING SET: since your last turn the user dropped notes.txt").size).to eq(1)

      commands.run("/working-set undrop notes.txt")
      stream("Back.")
      run_turn("and now")
      back = prompt_of(server.requests.last)
      expect(back).to include("the original text")
      expect(back).not_to include(stub)
      expect(back).to include("the user brought back notes.txt")

      stream("Quiet.")
      run_turn("no ops")
      expect(prompt_of(server.requests.last).scan("[WORKING SET:").size).to eq(2)
    end

    it "nets to nothing when undone before a request: no note, the conversation as it was" do
      before = session.messages.map(&:dup)

      commands.run("/working-set drop notes.txt")
      result = commands.run("/working-set undrop notes.txt")

      expect(result.output).to end_with("its drop was never sent; nothing changes")
      expect(session.messages).to eq(before)
    end

    it "pins under forget: announced pinned, noted once, and the model's forget_outputs is refused" do
      session.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:forget])

      result = commands.run("/working-set pin notes.txt")

      expect(result).to have_attributes(status: :ok, changed: %i[messages working_set_pins])
      expect(announced.last[:items]).to match([include(key: path, pinned: true)])
      id = result.output[/\(t\d+\)/][1..-2]
      stream(%(<|tool_call>call:forget_outputs{ids:<|"|>["#{id}"]<|"|>,note:<|"|>notes holds one line<|"|>}<tool_call|>))
      stream("Kept.")
      run_turn("tidy up")

      first = prompt_of(server.requests[-2])
      expect(first.scan("the user pinned notes.txt: forget_outputs won't forget it").size).to eq(1)
      last = prompt_of(server.requests.last)
      expect(last).to include("the original text")
      expect(last).to include("- #{id}: #{Samagotchi::WorkingSetSteer::Refused.text(:pinned_by_user)}")
    end

    it "a pin takes a pending drop off, free: no note, the output whole" do
      before = session.messages.map(&:dup)
      commands.run("/working-set drop notes.txt")

      result = commands.run("/working-set pin notes.txt")

      expect(result.output.lines.first).to end_with("its drop was never sent; nothing changes\n")
      expect(session.messages).to eq(before)
      expect(session.working_set_pins.map(&:key)).to eq([path])
    end

    it "an add is announced pending, asked in the next turn's first request once, and gone from the set's adds then" do
      extra = File.join(@dir, "extra.txt")
      File.write(extra, "the added text\n")

      result = commands.run("/working-set add extra.txt")

      expect(result).to have_attributes(status: :ok, changed: [:messages])
      expect(announced.last[:adds]).to eq([{ kind: "file", key: extra, label: "extra.txt" }])
      expect(announced.last[:items]).to match([include(key: path)])

      stream(%(<|tool_call>call:read{path:<|"|>#{extra}<|"|>}<tool_call|>))
      stream("Read it.")
      run_turn("go on")

      first = prompt_of(server.requests[-2])
      expect(first.scan(%(the user added extra.txt to your context: before anything else, load it with read "#{extra}")).size).to eq(1)
      expect(prompt_of(server.requests.last)).to include("the added text")
      expect(updates.last).not_to have_key(:adds)
      expect(updates.last[:items]).to match([include(key: path), include(key: extra, state: "live")])
    end

    it "refuses a key not in the set in the exception's words, changing nothing" do
      result = commands.run("/working-set drop other.txt")

      expect(result).to have_attributes(status: :error, changed: [],
                                        output: "drop other.txt: #{Samagotchi::WorkingSetSteer::Refused.text(:not_in_set)}")
    end
  end
end
