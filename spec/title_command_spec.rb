# frozen_string_literal: true

require "tmpdir"
require "spec_helper"
require "samagotchi/title_command"
require "samagotchi/session"
require "samagotchi/idle_recap"

# /title: shows, sets or clears the session's own name.
RSpec.describe Samagotchi::TitleCommand do
  let(:recap) { nil }
  let(:engine) { Struct.new(:session, :recap).new(session, recap) }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd).tap do |s|
      s.first_preview = "hey chi, coordinate"
    end
  end
  let(:command) { described_class.new(engine: engine) }

  it "shows the title, or the first message the lists show without one" do
    expect(command.run("")).to eq(["title: none (shows the first message: hey chi, coordinate)", false, :ok])
    session.first_preview = ""
    expect(command.run(" ")).to eq(["title: none (shows the first message)", false, :ok])
    session.title = "Coordinator"
    expect(command.run("")).to eq(["title: Coordinator", false, :ok])
  end

  context "with an auto title from the recap" do
    let(:recap) { instance_double(Samagotchi::IdleRecap, state: { text: "Tabs work.", title: "Parser tab handling" }) }

    it "says the auto title shows without a title, and a title still wins" do
      expect(command.run("")).to eq(["title: none (shows the auto title: Parser tab handling)", false, :ok])
      expect(command.run("Coordinator")).to eq(["title: Coordinator", true, :ok])
      expect(command.run("--clear").first).to eq("title: none (shows the auto title: Parser tab handling)")
    end
  end

  it "shows the first message under a recap without an auto title (one saved before them)" do
    engine.recap = instance_double(Samagotchi::IdleRecap, state: { text: "Tabs work." })
    expect(command.run("")).to eq(["title: none (shows the first message: hey chi, coordinate)", false, :ok])
  end

  it "sets it, whitespace collapsed and cut at 80 characters (changed: its host saves it); the same again is no change" do
    expect(command.run("  Coordinator \n  of  the day ")).to eq(["title: Coordinator of the day", true, :ok])
    expect(session.title).to eq("Coordinator of the day")
    expect(command.run("Coordinator of the day")).to eq(["title: Coordinator of the day\n(no change)", false, :ok])

    expect(command.run("x" * 90)[1]).to be(true)
    expect(session.title).to eq("#{"x" * 80}…")
  end

  it "clears it with --clear, back to the first message" do
    session.title = "Coordinator"

    expect(command.run(" --clear")).to eq(["title: none (shows the first message: hey chi, coordinate)", true, :ok])
    expect(session.title).to be_nil
    expect(command.run("--clear").last(2)).to eq([false, :ok])
  end

  it "refuses --clear with more after it, and keeps the title" do
    session.title = "Coordinator"

    expect(command.run("--clear  now")).to eq(["usage: /title [TEXT|--clear]", false, :error])
    expect(session.title).to eq("Coordinator")
  end

  it "refuses without a session" do
    expect(described_class.new(engine: Struct.new(:session).new(nil)).run("X"))
      .to eq(["no session yet", false, :error])
  end

  it "drops a preview that is the command itself, and the host's save derives it from the first user message" do
    dir = Dir.mktmpdir("title-spec")
    session.first_preview = "/title Coordinator"
    session.messages = [{ role: "user", content: "the real first question" }]
    command.run("Coordinator")
    session.save(state_dir: dir)

    expect(Samagotchi::Session.load(session.id, state_dir: dir))
      .to have_attributes(title: "Coordinator", first_preview: "the real first question")
  ensure
    FileUtils.rm_rf(dir)
  end
end
