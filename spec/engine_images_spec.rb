# frozen_string_literal: true

require "tmpdir"
require "samagotchi/engine"
require "samagotchi/session"

RSpec.describe Samagotchi::Engine, "#run_turn with images" do
  around do |example|
    original = ENV["SAMAGOTCHI_DEFAULT_MODEL"]
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = "Ornith"
    Dir.mktmpdir("chi-state") do |dir|
      @state_dir = dir
      example.run
    end
  ensure
    ENV["SAMAGOTCHI_DEFAULT_MODEL"] = original
  end

  let(:client) { instance_double(Samagotchi::Client) }
  let(:kernel) { instance_double(Samagotchi::KernelLoop) }
  let(:engine) do
    described_class.new(mode: :assist, client: client, kernel: kernel, profile: "qwen36").tap do |e|
      e.session_state_dir = @state_dir
    end
  end
  let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "Ornith", working_directory: Dir.pwd) }
  let(:shot) { File.expand_path("fixtures/images/tiny.png", __dir__) }
  let(:events) { [] }
  let(:vision_set) { [] }

  before do
    allow(Samagotchi::Tools::MemoryRead).to receive(:call).and_return("")
    allow(kernel).to receive(:vision=) { |value| vision_set << value }
    session.messages = [{ role: "system", content: "sys" }, { role: "user", content: "earlier" }, { role: "model", content: "ok" }]
  end

  def result_for(messages)
    Samagotchi::KernelLoop::Result.new(output: "a red square", conversation: messages + [{ role: "model", content: "a red square" }],
                                       exhausted: false, pending_tool_calls: false, tool_activity: [], canceled: false)
  end

  def turn(prompt = "what's this?", **options)
    engine.run_turn(session, prompt, on_event: ->(e) { events << e }, **options)
  end

  def answer(value, reason = nil) = Samagotchi::VisionSupport::Answer.new(value: value, reason: reason)

  it "stores a {path:} image, announces its ref and sends it on the user message" do
    allow(Samagotchi::VisionSupport).to receive(:for).and_return(answer(true))
    sent = nil
    allow(kernel).to receive(:run) { |messages, **| sent = messages; result_for(messages) }

    turn(images: [{ path: shot }])

    started = events.find { |e| e[:type] == :turn_started }
    ref = started[:images].first
    expect(ref).to include(name: "tiny.png", width: 3, height: 2, mime: "image/png", source: "user")
    expect(File.binread(File.join(@state_dir, session.id, ref[:file]))).to eq(File.binread(shot))
    expect(sent.last).to eq({ role: "user", content: "what's this?", images: [ref] })
    expect(session.messages[-2]).to include(images: [ref])
    expect(vision_set.last.session_dir).to eq(File.join(@state_dir, session.id))
  end

  it "accepts a {file:} ref already in the session, rebuilt from the file" do
    stored = Samagotchi::ImageStore.ingest(File.join(@state_dir, session.id), path: shot, resizer: Samagotchi::ImageResizer.new(nil))
    allow(Samagotchi::VisionSupport).to receive(:for).and_return(answer(true))
    sent = nil
    allow(kernel).to receive(:run) { |messages, **| sent = messages; result_for(messages) }

    turn(images: [{ "file" => stored[:file], "name" => "paste.png", "width" => 9999 }])

    expect(sent.last[:images]).to eq([stored.merge(name: "paste.png")])
  end

  it "refuses before anything is kept when the model can't see images" do
    allow(Samagotchi::VisionSupport).to receive(:for).and_return(answer(false, "the server has no vision model loaded"))
    expect(kernel).not_to receive(:run)
    expect(engine).not_to receive(:collect_due_reminders)
    before = session.messages.map(&:dup)

    expect { turn(images: [{ path: shot }]) }.to raise_error(Samagotchi::LLM::VisionUnsupported)

    expect(events.map { |e| e[:type] }).to eq(%i[turn_started turn_failed])
    failed = events.last
    expect(failed).to include(error_kind: :vision_unsupported, retryable: false)
    expect(failed[:summary]).to include("can't take images: the server has no vision model loaded", "send text only")
    expect(session.messages).to eq(before)
    expect(Samagotchi::Session.load(session.id).messages).to eq(before)
  end

  it "fails the turn for a ref outside the session's images (traversal)" do
    expect(kernel).not_to receive(:run)
    expect { turn(images: [{ file: "../../etc/passwd" }]) }.to raise_error(Samagotchi::ImageStore::Error, /unknown image/)
    expect(events.map { |e| e[:type] }).to eq(%i[turn_started turn_failed])
    expect(events.first).not_to have_key(:images)
  end

  it "fails the turn for a path that isn't an image" do
    text = File.join(@state_dir, "notes.png")
    File.write(text, "plain text")
    expect { turn(images: [{ path: text }]) }.to raise_error(Samagotchi::ImageStore::Error, /notes\.png is not an image/)
  end

  it "doesn't ask whether the model sees images on a turn without any" do
    expect(Samagotchi::VisionSupport).not_to receive(:for)
    allow(kernel).to receive(:run) { |messages, **| result_for(messages) }

    turn

    expect(events.first).not_to have_key(:images)
    expect(session.messages[-2]).to eq({ role: "user", content: "what's this?" })
  end
end
