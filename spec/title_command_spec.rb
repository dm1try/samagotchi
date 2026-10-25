# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/title_command"
require "samagotchi/session"
require "samagotchi/recap_store"

# /title: shows, sets or clears the session's own name, and without one says
# what the lists show instead — the same read the cards use (RecapStore.card).
RSpec.describe Samagotchi::TitleCommand do
  let(:recap) { nil }
  let(:engine) { Struct.new(:session, :recap, :session_state_dir).new(session, recap, state_dir) }
  let(:session) do
    Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: Dir.pwd).tap do |s|
      s.first_preview = "hey chi, coordinate"
    end
  end
  let(:command) { described_class.new(engine: engine) }

  before { @state_dir = Dir.mktmpdir("title-spec") }
  after { FileUtils.rm_rf(@state_dir) }

  # The state dir the Engine (and so the cards) reads this session's files from.
  attr_reader :state_dir

  # Save what an idle recap would have written beside the session.
  def save_recap(data)
    dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, Samagotchi::RecapStore::FILE), JSON.generate(data))
  end

  it "shows the title, or the first message the lists show without one" do
    expect(command.run("")).to eq(["title: none (shows the first message: hey chi, coordinate)", false, :ok])
    session.first_preview = ""
    expect(command.run(" ")).to eq(["title: none (shows the first message)", false, :ok])
    session.title = "Coordinator"
    expect(command.run("")).to eq(["title: Coordinator", false, :ok])
  end

  context "with an auto title in the saved recap" do
    before { save_recap({ text: "The user was fixing the parser tabs. They work now.", title: "Parser tab handling" }) }

    it "says the auto title shows without a title, and a title still wins" do
      expect(command.run("")).to eq(["title: none (shows the auto title: Parser tab handling)", false, :ok])
      expect(command.run("Coordinator")).to eq(["title: Coordinator", true, :ok])
      expect(command.run("--clear").first).to eq("title: none (shows the auto title: Parser tab handling)")
    end

    it "says it even when this session's recap is off (no live recap job)" do
      engine.recap = nil
      expect(command.run("").first).to eq("title: none (shows the auto title: Parser tab handling)")
    end

    it "says it for a session whose live recap has never read the file" do
      engine.recap = Samagotchi::IdleRecap.new(engine: engine, target: nil, store: nil)
      expect(command.run("").first).to eq("title: none (shows the auto title: Parser tab handling)")
    end

    it "matches what the cards and `chi sessions list` read from the same file" do
      card = Samagotchi::RecapStore.card(Samagotchi::Session.session_dir(session.id, state_dir: state_dir))
      expect(command.run("").first).to eq("title: none (shows the auto title: #{card.title})")
    end
  end

  it "shows the saved recap's first sentence when it has no auto title (one saved before them)" do
    save_recap({ text: "We fixed the parser tabs." })

    expect(command.run("")).to eq(["title: none (shows the recap: We fixed the parser tabs.)", false, :ok])
    expect(command.run("Coordinator").first).to eq("title: Coordinator")
    expect(command.run("--clear").first).to eq("title: none (shows the recap: We fixed the parser tabs.)")
  end

  it "falls back to the first message when there is no recap file at all" do
    expect(command.run("").first).to eq("title: none (shows the first message: hey chi, coordinate)")
  end

  it "sets it, whitespace collapsed and cut at 80 characters (changed: its host saves it); the same again is no change" do
    expect(command.run("  Coordinator \n  of  the day ")).to eq(["title: Coordinator of the day", true, :ok])
    expect(session.title).to eq("Coordinator of the day")
    expect(command.run("Coordinator of the day")).to eq(["title: Coordinator of the day\n(no change)", false, :ok])

    expect(command.run("x" * 90)[1]).to be(true)
    expect(session.title).to eq("#{"x" * 80}…")
  end

  it "clears it with --clear, back to what the lists show" do
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
    session.first_preview = "/title Coordinator"
    session.messages = [{ role: "user", content: "the real first question" }]
    command.run("Coordinator")
    session.save(state_dir: state_dir)

    expect(Samagotchi::Session.load(session.id, state_dir: state_dir))
      .to have_attributes(title: "Coordinator", first_preview: "the real first question")
  end
end
