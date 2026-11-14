# frozen_string_literal: true

# The stage perf probe's session (script/stage-perf-probe): TURNS finished
# turns written by chi's own writers, as a worker leaves them: the events go
# through a Bridge's TurnAccumulator (its drawings, Bridge::TurnDrawings) and
# CardStore (cards.json), and the messages through Session#save. CARDS
# plugin cards (every third one a warning) and QUESTIONS answered questions,
# spread over the turns. CardStore keeps its CAPACITY (20) of cards and
# questions, as a worker does: the others are in their turns' drawings only.
#
#   ruby script/stage_perf_probe/session.rb PROJECT_DIR   (XDG_* set by the caller)
#
# Prints the session's id.
require_relative "../../lib/samagotchi/session"
require_relative "../../lib/samagotchi/bridge/card_store"
require_relative "../../lib/samagotchi/bridge/turn_accumulator"
require_relative "../../lib/samagotchi/bridge/turn_drawings"

TURNS = 300
CARDS = 60
QUESTIONS = 40
AT = "2026-11-14T10:00:00.000+01:00"

project = ARGV.fetch(0)
session = Samagotchi::Session.new_session(mode: "assist", model_name: "fake-script", working_directory: project, test_run: false)
state_dir = Samagotchi::Session.default_state_dir
dir = Samagotchi::Session.session_dir(session.id, state_dir: state_dir)
FileUtils.mkdir_p(dir)

messages = []
drawings = Samagotchi::Bridge::TurnDrawings.new(path: File.join(dir, Samagotchi::Bridge::TurnDrawings::FILE), messages: -> { messages })
accumulator = Samagotchi::Bridge::TurnAccumulator.new(on_turn_end: drawings.method(:append))
cards = Samagotchi::Bridge::CardStore.new(path: File.join(dir, Samagotchi::Bridge::CardStore::FILE), messages: -> { messages })
feed = ->(event) { [accumulator, cards].each { |observer| observer.call(event) } }

# Which turns carry a card, which a question: spread evenly.
card_turns = (0...CARDS).to_h { |n| [(n * TURNS / CARDS) + 1, n] }
question_turns = (0...QUESTIONS).to_h { |n| [(n * TURNS / QUESTIONS) + 3, n] }

words = "The probe's answer, a paragraph long enough to wrap on a phone: it says what the turn did and where."

TURNS.times do |i|
  id = "probe-turn-#{i}"
  prompt = "Probe turn #{i}: look at the project"
  from = messages.size
  messages = [*messages, { role: "user", content: prompt, turn_id: id, at: AT }]
  feed.call({ type: :turn_started, prompt: prompt, turn_id: id, at: AT, origin: { client_id: "web:probe" } })
  feed.call({ type: :generation_started, iteration: 1 })
  step = 1
  if (q = question_turns[i])
    qid = "probe-q-#{q}"
    params = 'question="Which file?"'
    feed.call({ type: :generation_chunk, iteration: 1, text: "Two files could answer this.", thinking: "" })
    feed.call({ type: :tool_call_started, iteration: 1, call_index: 1, tool: "ask_user_question", params: params, tool_id: "t#{i}" })
    feed.call({ type: :question_requested,
                pending_question: { id: qid, kind: "question", question: "Which file should I read (#{q})?",
                                    options: %w[README.md Gemfile], status: "pending" } })
    feed.call({ type: :question_answered, id: qid, answer: { selected: ["README.md"] } })
    feed.call({ type: :tool_call_completed, iteration: 1, call_index: 1, tool: "ask_user_question", tool_id: "t#{i}",
                output: "README.md", output_truncated: false, duration_ms: 900,
                activity: { tool: "ask_user_question", status: "ok", params: params, action: "asking" } })
    feed.call({ type: :generation_completed, iteration: 1 })
    call = { id: "c#{i}", name: "ask_user_question", arguments: JSON.generate(question: "Which file?") }
    messages = [*messages, { role: "model", content: "Two files could answer this.", tool_calls: [call] },
                { role: "tool_response", content: "README.md", tool_call_id: "c#{i}", tool_ids: ["t#{i}"] }]
    step = 2
    feed.call({ type: :generation_started, iteration: 2 })
  end
  if (c = card_turns[i])
    feed.call({ type: :card, id: "probe-card-#{c}", source: "probe", title: "Probe card #{c}", body: "A plugin's card body #{c}.",
                level: (c % 3).zero? ? :warn : :info, actions: [], in_turn: true })
  end
  answer = "#{words} (#{i})"
  feed.call({ type: :generation_chunk, iteration: step, text: answer, thinking: "" })
  feed.call({ type: :generation_completed, iteration: step })
  messages = [*messages, { role: "model", content: answer }]
  feed.call({ type: :turn_completed, turn_id: id, duration_ms: 2400, kept_from: from, kept_to: messages.size,
              turn_summary: { output: answer } })
end

session.messages = messages
session.save(state_dir: state_dir)
puts session.id
