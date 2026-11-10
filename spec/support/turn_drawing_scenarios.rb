# frozen_string_literal: true

require "json"
require "samagotchi/context_note"
require "samagotchi/steer"
require "samagotchi/turn_note"
require "samagotchi/tool_output_cut"
require "samagotchi/tool_row_fields"

# The finished turns the turn-drawing specs share (spec/shared/turn_drawings/
# <name>.json, written from here): each one's live events (as a Bridge's
# observers get them), the session's messages at each end event and at the
# end, then what Bridge::TurnDrawings writes for them (`lines`), chi web's
# unfold of each valid line (`drawn`) and its show (`show`, the display
# items and turn_drawings a page with drawings=1 gets). The Ruby specs
# compute those again and compare (UPDATE_TURN_DRAWINGS=1 writes them); the
# node parity test (spec/web/public/turn_drawing_parity.test.js) feeds the
# events to the live page and draws the show, and compares the two.
module TurnDrawingScenarios
  DIR = File.expand_path("../shared/turn_drawings", __dir__)
  AT = "2026-11-08T10:00:00.000+01:00"
  HEAD = { role: "system", content: "You are chi." }.freeze
  # The zone the scenarios are built in: a continue note's header shows its
  # created_at in local time (ContextNote), so a build in the runner's zone
  # (UTC on CI) would not match the fixture. Fixed UTC+1 (POSIX inverts the
  # sign), AT's offset.
  ZONE = "Etc/GMT-1"

  module_function

  def all
    in_zone { SCENARIOS.map { |name, build| build.call.merge(name: name.to_s) } }
  end

  def in_zone
    saved = ENV.fetch("TZ", nil)
    ENV["TZ"] = ZONE
    yield
  ensure
    saved ? ENV["TZ"] = saved : ENV.delete("TZ")
  end

  def user(text, id, **extra) = { role: "user", content: text, turn_id: id, at: AT, **extra }
  def model(text, **extra) = { role: "model", content: text, **extra }
  def call(id, name, arguments) = { id: id, name: name, arguments: JSON.generate(arguments) }
  def response(call_id, tool_id, output) = { role: "tool_response", content: output, tool_call_id: call_id, tool_ids: [tool_id] }

  def started(id, prompt, **extra) = { type: :turn_started, prompt: prompt, turn_id: id, at: AT, origin: { client_id: "web:me" }, **extra }
  def gen(iteration) = { type: :generation_started, iteration: iteration }
  def text(iteration, words, thinking: "") = { type: :generation_chunk, iteration: iteration, text: words, thinking: thinking }
  def done(iteration) = { type: :generation_completed, iteration: iteration }

  # A call's live events (ToolRunner's): its row fields as ToolRowFields
  # builds them from +args+ (the call's arguments), as live and a reload do.
  def tool(iteration, index, name, params, output, tool_id:, args: {}, status: "ok", action: "reading file", title: nil, duration: 120,
           **extra)
    title_fields = title ? { title: title } : {}
    view = Samagotchi::ToolRowFields.for(name, args, cwd: nil).slice(*Samagotchi::ToolRowFields::EVENT_KEYS)
    [{ type: :tool_call_started, iteration: iteration, call_index: index, tool: name, params: params, tool_id: tool_id, **title_fields,
       **view },
     { type: :tool_call_completed, iteration: iteration, call_index: index, tool: name, tool_id: tool_id, output: output,
       output_truncated: false, duration_ms: duration,
       activity: { tool: name, status: status, params: params, action: action, **title_fields }, **view, **extra }]
  end

  def completed(id, from, to, output, empty: nil, duration: 2400)
    summary = { output: output }
    summary[:empty_answer] = empty if empty
    { type: :turn_completed, turn_id: id, duration_ms: duration, kept_from: from, kept_to: to, turn_summary: summary }
  end

  # A one-turn scenario: its messages are the session's at the end, and
  # its end's too.
  def one(description, events, messages)
    { description: description, events: events, ends: [messages], messages: messages }
  end

  SCENARIOS = {
    plain_answer: lambda {
      id = "turn-plain"
      one("A plain answer: one step, text only.",
          [started(id, "hi"), gen(1), text(1, "Hello there."), done(1), completed(id, 1, 3, "Hello there.")],
          [HEAD, user("hi", id), model("Hello there.")])
    },
    tools_answer: lambda {
      id = "turn-tools"
      one("A step with thinking, text and a read, then the answer.",
          [started(id, "look at a.txt"), gen(1), text(1, "Let me look.", thinking: "look first"),
           *tool(1, 1, "read", 'path="a.txt"', "[read]\nalpha\nbeta", tool_id: "t1", title: "a.txt"), done(1),
           gen(2), text(2, "It says alpha, beta."), done(2), completed(id, 1, 5, "It says alpha, beta.")],
          [HEAD, user("look at a.txt", id),
           model("Let me look.", thinking: "look first", tool_calls: [call("c1", "read", { path: "a.txt" })]),
           response("c1", "t1", "[read]\nalpha\nbeta"), model("It says alpha, beta.")])
    },
    empty_retry: lambda {
      id = "turn-retry"
      one("An empty answer asked again: the retried step's row stays in its step (bug 1).",
          [started(id, "answer please"), gen(1), text(1, "", thinking: "hmm"), done(1),
           { type: :empty_answer_retry, iteration: 1, attempt: 1, of: 1 },
           gen(2), text(2, "Here it is."), done(2), completed(id, 1, 3, "Here it is.")],
          [HEAD, user("answer please", id), model("Here it is.")])
    },
    no_answer: lambda {
      id = "turn-none"
      empty = Samagotchi::TurnNote.empty(retries: 1)
      one("No answer after a retry: two empty steps, the empty-answer notice.",
          [started(id, "say something"), gen(1), text(1, "", thinking: "first try"), done(1),
           { type: :empty_answer_retry, iteration: 1, attempt: 1, of: 1 },
           gen(2), text(2, "", thinking: "second try"), done(2),
           completed(id, 1, 4, "", empty: { retries: 1 })],
          [HEAD, user("say something", id), model(""), empty])
    },
    canceled_steps: lambda {
      id = "turn-cancel"
      one("Canceled after a tool step and a partial text.",
          [started(id, "run the tests"), gen(1), text(1, "Starting."),
           *tool(1, 1, "execute", 'command="rake"', "[execute]\nok", tool_id: "t1", args: { content: "rake" }, action: "running command", title: "rake"),
           done(1), gen(2), text(2, "Halfway"),
           { type: :turn_canceled, turn_id: id, duration_ms: 3100, cancellation_reason: "user", kept_from: 1, kept_to: 6 }],
          [HEAD, user("run the tests", id), model("Starting.", tool_calls: [call("c1", "execute", { command: "rake" })]),
           response("c1", "t1", "[execute]\nok"), model("Halfway"), Samagotchi::TurnNote.cancelled(:user, seconds: 3)])
    },
    failed_steps: lambda {
      id = "turn-failed"
      note = Samagotchi::TurnNote.failed_after("the model server is unreachable", 1)
      one("Failed after a tool step, its work kept: the step the error ended is drawn too.",
          [started(id, "fix it"), gen(1), text(1, "Step one."),
           *tool(1, 1, "read", 'path="b.rb"', "[read]\nb", tool_id: "t1", title: "b.rb"), done(1), gen(2),
           { type: :turn_failed, turn_id: id, duration_ms: 5000, summary: "the model server is unreachable",
             message: "connection refused", error_class: "Errno::ECONNREFUSED", kept_steps: 1, kept_from: 1, kept_to: 5 }],
          [HEAD, user("fix it", id), model("Step one.", tool_calls: [call("c1", "read", { path: "b.rb" })]),
           response("c1", "t1", "[read]\nb"), note])
    },
    steer: lambda {
      id = "turn-steer"
      steer = Samagotchi::Steer.message(text: "keep going", source: "check-in")
      one("A plugin's steer between steps: the next step's first row.",
          [started(id, "build it"), gen(1), text(1, "Building."),
           *tool(1, 1, "execute", 'command="make"', "[execute]\nbuilt", tool_id: "t1", args: { content: "make" }, action: "running command", title: "make"),
           done(1), { type: :pending_input_merged, iteration: 2, count: 0, content: nil, steers: [{ source: "check-in", text: "keep going" }] },
           gen(2), text(2, "Built."), done(2), completed(id, 1, 6, "Built.")],
          [HEAD, user("build it", id), model("Building.", tool_calls: [call("c1", "execute", { command: "make" })]),
           response("c1", "t1", "[execute]\nbuilt"), steer.merge(step: 2), model("Built.")])
    },
    merged_input: lambda {
      id = "turn-merged"
      one("A line merged into the turn and a delegate's report.",
          [started(id, "check a"), gen(1), text(1, "Checking a."),
           *tool(1, 1, "read", 'path="a"', "[read]\na", tool_id: "t1", title: "a"), done(1),
           { type: :input_merged, origins: [{ client_id: "web:me", enqueued_id: "e2" }] },
           { type: :pending_input_merged, iteration: 2, count: 1, content: "also check b", steers: [] },
           { type: :input_merged, origins: [{ client_id: "child:abc" }] },
           { type: :pending_input_merged, iteration: 2, count: 1, content: "[report] child done", source: "delegate_report", steers: [] },
           gen(2), text(2, "Both fine."), done(2), completed(id, 1, 7, "Both fine.")],
          [HEAD, user("check a", id), model("Checking a.", tool_calls: [call("c1", "read", { path: "a" })]),
           response("c1", "t1", "[read]\na"),
           { role: "user", kind: Samagotchi::Steer::INPUT_KIND, content: "also check b", at: AT, step: 2 },
           { role: "user", kind: Samagotchi::Steer::INPUT_KIND, source: "delegate_report", content: "[report] child done", at: AT, step: 2 },
           model("Both fine.")])
    },
    question: lambda {
      id = "turn-question"
      pending = { id: "q1", question: "Which one?", options: [{ label: "A" }, { label: "B" }], status: "pending" }
      one("A question asked and answered mid-turn.",
          [started(id, "pick one"), gen(1), text(1, "Which one do you want?"),
           { type: :tool_call_started, iteration: 1, call_index: 1, tool: "ask_user_question", params: 'question="Which one?"', tool_id: "t1" },
           { type: :question_requested, pending_question: pending },
           { type: :question_answered, id: "q1", answer: { selected: ["A"] } },
           { type: :tool_call_completed, iteration: 1, call_index: 1, tool: "ask_user_question", tool_id: "t1", output: "[ask_user_question]\nA",
             output_truncated: false, duration_ms: 900, activity: { tool: "ask_user_question", status: "ok", params: 'question="Which one?"', action: "asking user" } },
           done(1), gen(2), text(2, "A it is."), done(2), completed(id, 1, 5, "A it is.")],
          [HEAD, user("pick one", id),
           model("Which one do you want?", tool_calls: [call("c1", "ask_user_question", { question: "Which one?" })]),
           response("c1", "t1", "[ask_user_question]\nA"), model("A it is.")])
    },
    reminder_prompt: lambda {
      id = "turn-remind"
      line = { role: "system", content: "[SYSTEM: REMINDERS DUE 2026-11-08 10:00 local]\n- tea: brew", at: AT }
      one("A reminder that went into a prompt's turn: its line shows (bug 4).",
          [started(id, "hello"), { type: :reminder_injected, reminders: [{ name: "tea" }], at: AT },
           gen(1), text(1, "Hi, and tea time."), done(1), completed(id, 1, 4, "Hi, and tea time.")],
          [HEAD, line, user("hello", id), model("Hi, and tea time.")])
    },
    reminder_only: lambda {
      id = "turn-reminder-only"
      line = { role: "system", content: "[SYSTEM: REMINDERS DUE 2026-11-08 10:00 local]\n- tea: brew", at: AT }
      one("A reminder turn: no prompt, its reminder line and its answer.",
          [{ type: :turn_started, prompt: nil, turn_id: id, at: AT, origin: { kind: "reminder" } },
           { type: :reminder_injected, reminders: [{ name: "tea" }], at: AT },
           gen(1), text(1, "Tea time."), done(1), completed(id, 3, 5, "Tea time.")],
          [HEAD, user("earlier", "turn-0"), model("Earlier answer."), line, model("Tea time.")])
    },
    checkin_card: lambda {
      id = "turn-card"
      card = { type: :card, id: "check-in", source: "check-in", title: "Check in", body: "Still on it?", level: "info",
               actions: [{ label: "Nudge", command: "/check-in nudge" }], in_turn: true }
      one("A check-in card shown mid-turn (it asks: under the block, live).",
          [started(id, "long task"), gen(1), text(1, "Working."),
           *tool(1, 1, "execute", 'command="sleep 1"', "[execute]\n", tool_id: "t1", args: { content: "sleep 1" }, action: "running command", title: "sleep 1"),
           card, done(1), gen(2), text(2, "Finished."), done(2), completed(id, 1, 5, "Finished.")],
          [HEAD, user("long task", id), model("Working.", tool_calls: [call("c1", "execute", { command: "sleep 1" })]),
           response("c1", "t1", "[execute]\n"), model("Finished.")])
    },
    checkin_card_replaced: lambda {
      id = "turn-card-again"
      card = { type: :card, id: "check-in", source: "check-in", title: "Check in", body: "Still on it?", level: "info",
               actions: [{ label: "Nudge", command: "/check-in nudge" }], in_turn: true }
      one("A check-in card shown in step 1 and again (its next tick) in step 2: its latest version, in its first place.",
          [started(id, "long task"), gen(1), text(1, "Working."),
           *tool(1, 1, "execute", 'command="sleep 1"', "[execute]\n", tool_id: "t1", args: { content: "sleep 1" },
                                                                         action: "running command", title: "sleep 1"),
           card, done(1), gen(2), text(2, "Still working."),
           *tool(2, 1, "execute", 'command="sleep 2"', "[execute]\n", tool_id: "t2", args: { content: "sleep 2" },
                                                                         action: "running command", title: "sleep 2"),
           card.merge(body: "Still on it? (2)"), done(2), gen(3), text(3, "Finished."), done(3), completed(id, 1, 7, "Finished.")],
          [HEAD, user("long task", id), model("Working.", tool_calls: [call("c1", "execute", { command: "sleep 1" })]),
           response("c1", "t1", "[execute]\n"), model("Still working.", tool_calls: [call("c2", "execute", { command: "sleep 2" })]),
           response("c2", "t2", "[execute]\n"), model("Finished.")])
    },
    long_output: lambda {
      id = "turn-long"
      output = "[execute]\n#{(1..800).map { |n| "line #{n}" }.join("\n")}"
      preview = Samagotchi::ToolOutputCut.preview(output, cap: Samagotchi::ToolOutputCut::WEB_PREVIEW_CHARS, tool: "execute")
      one("A long output: the row's hover is the reload's preview.",
          [started(id, "list"), gen(1), text(1, "Listing."),
           *tool(1, 1, "execute", 'command="seq"', output, tool_id: "t1", args: { content: "seq" }, action: "running command", title: "seq", preview: preview),
           done(1), gen(2), text(2, "800 lines."), done(2), completed(id, 1, 5, "800 lines.")],
          [HEAD, user("list", id), model("Listing.", tool_calls: [call("c1", "execute", { command: "seq" })]),
           response("c1", "t1", output), model("800 lines.")])
    },
    continue_opener: lambda {
      id = "turn-continue"
      opener = Samagotchi::ContextNote.message(note_id: "n1", text: "from the parent", source: "continue",
                                               created_at: "2026-11-08T09:00:00Z")
      one("The first turn of a continue link, head-less, its opener note before it (outside the range).",
          [started(id, "carry on"), gen(1), text(1, "Carrying on."), done(1), completed(id, 2, 4, "Carrying on.")],
          [HEAD, opener, user("carry on", id), model("Carrying on.")])
    },
    pair_participant: lambda {
      id = "turn-pair"
      author = { author: "p:abc", author_name: "Ana", participant_mode: "pair" }
      one("A pair participant's turn: the prompt keeps its author keys.",
          [started(id, "can you check", **author), gen(1), text(1, "Checked."), done(1), completed(id, 1, 3, "Checked.")],
          [HEAD, user("can you check", id, **author), model("Checked.")])
    },
    rollback_rerun: lambda {
      first = "turn-first"
      second = "turn-second"
      messages = [HEAD, user("again", second), model("Same.")]
      { description: "A rollback, then a re-run that said the same at the same boundaries: the newest line wins.",
        events: [started(first, "again"), gen(1), text(1, "Same."), done(1), completed(first, 1, 3, "Same."),
                 started(second, "again"), gen(1), text(1, "Same."), done(1), completed(second, 1, 3, "Same.")],
        ends: [[HEAD, user("again", first), model("Same.")], messages],
        messages: messages }
    }
  }.freeze

  # JSON as the file has it (string keys and types).
  def wire(value) = JSON.parse(JSON.generate(value))

  def path(name) = File.join(DIR, "#{name}.json")
end
