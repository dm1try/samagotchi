# frozen_string_literal: true

require "tmpdir"
require_relative "live_fixtures"

RSpec.describe LLMContextLive::Driver do
  let(:dir) { Dir.mktmpdir("live-driver-") }
  let(:workspace) { LLMContextLive::Workspace.new(dir) }
  let(:shell) { LiveFixtures::FakeShell.new }
  let(:driver) { described_class.new(chi: "/opt/chi", shell: shell, clock: -> { 0 }, log: StringIO.new) }

  after { FileUtils.rm_rf(dir) }

  def chi_calls(word) = shell.calls.select { |argv| argv.first == "/opt/chi" && argv[1] == word }

  def run = driver.run(LiveFixtures.task, workspace, model: "or:acme/coder", flags: %w[--llm-context stale,forget])

  it "starts the session with the first turn, sends the next into it, then stops it" do
    shell.on(/ send --new/, LiveFixtures.json(status: "answered", session_id: "s1", text: "plan"))
         .on(/ send s1/, LiveFixtures.json(status: "answered", session_id: "s1", text: "done"))
         .on(/sessions stop|pkill/, LiveFixtures.ran)

    outcome = run

    first, second = chi_calls("send")
    expect(first).to include("--new", "--dir", workspace.repo, "--model", "or:acme/coder", "--llm-context", "stale,forget")
    expect(first.last).to eq("Find it in #{workspace.repo}.")
    expect(second.last).to eq("Fix it.")
    expect(outcome.turns.map(&:status)).to eq(%w[answered answered])
    expect(chi_calls("sessions").last).to eq(["/opt/chi", "sessions", "stop", "s1"])
    expect(shell.calls.last).to eq(["pkill", "-f", workspace.state_home])
  end

  it "answers the model's first question with its judgement, dismisses a second, and Stops at the step limit" do
    question = ->(id, kind, **more) { LiveFixtures.json(status: "question", session_id: "s1", question: { id: id, kind: kind, **more }) }
    shell.on(/ send --new/, question.call("q1", "question", allow_freeform: true))
         .on(/answer s1 --question q1/, question.call("q2", "question", options: %w[a b]))
         .on(/answer s1 --question q2/, LiveFixtures.json(status: "answered", session_id: "s1"))
         .on(/ send s1/, question.call("q3", "continue"))
         .on(/answer s1 --question q3/, LiveFixtures.json(status: "not_continued", session_id: "s1"))
         .on(/sessions stop|pkill/, LiveFixtures.ran)

    outcome = run

    answers = chi_calls("answer")
    expect(answers[0]).to include("--text", "use your judgement")
    expect(answers[1]).to include("--dismiss")
    expect(answers[2]).to include("--option", "Stop")
    expect(outcome.turns.map(&:to_h)).to match([include(status: "answered", answered: 2, limit: false),
                                                include(status: "limit", answered: 1, limit: true)])
  end

  it "ends the run at once on a payment error and says so" do
    shell.on(/ send --new/, LiveFixtures.json(status: "failed", session_id: "s1", error_kind: "credits", detail: "402"))
         .on(/sessions stop|pkill/, LiveFixtures.ran)

    outcome = run

    expect(outcome.payment).to be(true)
    expect(chi_calls("send").size).to eq(1)
  end

  it "reports a turn still running at the timeout and sends no more" do
    shell.on(/ send --new/, LiveFixtures.json(status: "running", session_id: "s1", detail: "still running"))
         .on(/sessions stop|pkill/, LiveFixtures.ran)

    outcome = run

    expect(outcome.timed_out).to be(true)
    expect(chi_calls("send").size).to eq(1)
  end

  it "keeps an unreadable chi reply as the run's error, and still cleans up" do
    shell.on(/ send --new/, LiveFixtures.ran("", status: 1, err: "boom"))
         .on(/pkill/, LiveFixtures.ran)

    outcome = run

    expect(outcome.error).to include("no JSON", "boom")
    expect(shell.calls.last).to eq(["pkill", "-f", workspace.state_home])
  end
end
