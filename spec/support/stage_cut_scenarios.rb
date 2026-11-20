# frozen_string_literal: true

require "json"

# Turns with a card that waits, cut mid-turn (spec/shared/stage_cuts/
# <name>.json, written from here by spec/web/session_show_cuts_spec.rb): each
# one's live events (as a Bridge's observers get them) and its cuts, the
# event counts a page reloads at. The spec writes the show chi web sends at
# each cut (Web::SessionShow over a snapshot the Bridge's TurnAccumulator and
# CardStore fold from the events so far); the node harness
# (spec/web/public/stage_cuts_parity.test.js) feeds the events to cut k to a
# live page and draws that show on another, and compares the stage and the
# history.
module StageCutScenarios
  DIR = File.expand_path("../shared/stage_cuts", __dir__)
  AT = "2026-11-12T10:00:00.000+01:00"
  HEAD = { role: "system", content: "You are chi." }.freeze

  module_function

  def path(name) = File.join(DIR, "#{name}.json")

  def all = SCENARIOS.map { |name, build| build.call.merge(name: name.to_s) }

  def user(text, id) = { role: "user", content: text, turn_id: id, at: AT }
  def started(id, prompt) = { type: :turn_started, prompt: prompt, turn_id: id, at: AT, origin: { client_id: "web:me" } }
  def gen(iteration) = { type: :generation_started, iteration: iteration }
  def text(iteration, words) = { type: :generation_chunk, iteration: iteration, text: words, thinking: "" }
  def done(iteration) = { type: :generation_completed, iteration: iteration }

  def call_started(iteration, name, params, tool_id, index = 1)
    { type: :tool_call_started, iteration: iteration, call_index: index, tool: name, params: params, tool_id: tool_id }
  end

  def call_done(iteration, name, params, tool_id, output, index = 1)
    { type: :tool_call_completed, iteration: iteration, call_index: index, tool: name, tool_id: tool_id, output: output, output_truncated: false,
      duration_ms: 120, activity: { tool: name, status: "ok", params: params, action: "running command" } }
  end

  def completed(id, output) = { type: :turn_completed, turn_id: id, duration_ms: 2400, turn_summary: { output: output } }

  # A model message: its reply and the calls it made.
  def model(words, calls = [])
    msg = { role: "model", content: words }
    msg[:tool_calls] = calls.map { |c| { id: c[:id], name: c[:name], arguments: c[:arguments] } } unless calls.empty?
    msg
  end

  # The turn's saved messages (after the session's system message): its
  # prompt, then each step's reply (+words+) with its calls (tool_call: the
  # name, the JSON arguments, the tool's output and the event's tool id) and
  # their responses, then the answer.
  # A step's +merged+ lines (texts) are user lines merged into the turn
  # before its reply (Steer::INPUT_KIND, as the engine saves them;
  # Web::MessageDisplay reads them as merged: true at that step).
  def turn_messages(id, steps, answer)
    [user("do it", id), *steps.flat_map do |step|
      [*Array(step[:merged]).map { |line| { role: "user", kind: "input", content: line, at: AT } },
       model(step[:words], step[:calls]),
       *step[:calls].map { |c| { role: "tool_response", content: c[:output], tool_call_id: c[:id], tool_ids: [c[:tool_id]] } }]
    end, model(answer)]
  end

  # +scenario+ ended: its turn_completed with the range of +messages+
  # (kept_from/kept_to, as Engine#end_turn puts it, so the turn-end cut
  # reloads the turn from the drawing live wrote: TurnDrawings), the
  # messages, and a cut after the end (the history compared there: where a
  # finished turn's cards land, the coverage reload_check.js handed over).
  def with_turn_end(scenario, messages)
    events = scenario[:events].map { |e| e[:type] == :turn_completed ? e.merge(kept_from: 1, kept_to: 1 + messages.size) : e }
    scenario.merge(events: events, messages: messages, cuts: [*scenario[:cuts], { at: events.size, label: "turn end" }])
  end

  def tool_call(name, arguments, output, tool_id, id = "c#{tool_id.delete_prefix("t")}")
    { id: id, name: name, arguments: arguments, output: output, tool_id: tool_id }
  end

  # A line sent from another tab while the turn runs (its queued bubble on
  # every page), merged into the turn at +iteration+'s boundary.
  def merged(iteration, line, enqueued_id = "e2")
    [{ type: :turn_enqueued, enqueued_id: enqueued_id, client_id: "web:other", prompt: line },
     { type: :input_merged, origins: [{ client_id: "web:other", enqueued_id: enqueued_id }] },
     { type: :pending_input_merged, iteration: iteration, count: 1, content: line, steers: [] }]
  end

  # check-in's card: asking (its actions), or settled (redrawn without them,
  # as the bundle's close_card does).
  CHECKIN_ACTIONS = [{ label: "Nudge", command: "/checkin nudge" }, { label: "Keep going", command: "/checkin later" },
                     { label: "Stop", command: "/checkin stop" }].freeze

  def checkin_asks(id = "check-in-1")
    { type: :card, id: id, source: "check-in", title: "3 tool calls, no answer yet", body: "Still on it?", level: "info",
      actions: CHECKIN_ACTIONS, in_turn: true }
  end

  def checkin_settled(id = "check-in-1")
    { type: :card, id: id, source: "check-in", title: "check-in", body: "Nudged.", level: "info", actions: [], in_turn: true }
  end

  # A step that reads +path+ (tool id +tool_id+), its call and its events.
  def read_step(iteration, path, tool_id, words: "")
    events = [gen(iteration), *(words.empty? ? [] : [text(iteration, words)]),
              call_started(iteration, "read", "path=\"#{path}\"", tool_id), call_done(iteration, "read", "path=\"#{path}\"", tool_id, "[read]\n#{path}")]
    [events, tool_call("read", "{\"path\":\"#{path}\"}", "[read]\n#{path}", tool_id)]
  end

  # +list+: the turn's events with [:cut, label] markers where a page
  # reloads (a cut's +at+ is the count of events before its marker).
  def cut_list(list)
    events = []
    cuts = []
    list.each { |e| e.is_a?(Array) && e.first == :cut ? cuts << { at: events.size, label: e.last } : events << e }
    [events, cuts]
  end

  # A turn in +steps+ (the messages' steps) ended by "Done." at +last+'s
  # step, from +list+ (events and cut markers; the start, the answer's step
  # and the end added here).
  def settle_turn(description, id:, list:, steps:, last:)
    events, cuts = cut_list([started(id, "do it"), *list, gen(last), text(last, "Done."), done(last), completed(id, "Done.")])
    with_turn_end({ description: description, prompt: "do it", turn_id: id, events: events, cuts: cuts }, turn_messages(id, steps, "Done."))
  end

  def asked(pending) = { type: :question_requested, pending_question: pending.merge(status: "pending") }
  def answered(id, label) = { type: :question_answered, id: id, answer: { selected: [label] } }

  APPROVAL = { tool: "execute", command: "echo ok", cwd: "/work", rule: "e2e-ask", source: "config", reason: "asks", scopes: ["once"] }.freeze

  def approval(id, **extra)
    { id: id, kind: "approval", header: "Approve tool call?", question: "execute: echo ok\n  in /work\n  why: asks (rule e2e-ask, config)",
      options: ["Allow once", "Deny"], approval: APPROVAL, **extra }
  end

  # A turn whose step 1 (+words+ before its call, "" for none) calls
  # +tool+, which asks +pending+ (+answer+ its label); step 2 answers.
  # Cuts: the card waiting, then the answer with the next step started.
  # +arguments+: the call's JSON arguments, as the turn's messages keep them.
  def asking_turn(description, id:, tool:, params:, arguments:, pending:, answer:, words: "")
    step1 = [gen(1), *(words.empty? ? [] : [text(1, words)]), call_started(1, tool, params, "t1")]
    events = [started(id, "do it"), *step1, asked(pending), answered(pending[:id], answer),
              call_done(1, tool, params, "t1", "[#{tool}]\nok"), done(1), gen(2), text(2, "Done."), done(2), completed(id, "Done.")]
    waiting = 1 + step1.size + 1
    messages = turn_messages(id, [{ words: words, calls: [tool_call(tool, arguments, "[#{tool}]\nok", "t1")] }], "Done.")
    with_turn_end({ description: description, prompt: "do it", turn_id: id, events: events,
                    cuts: [{ at: waiting, label: "waiting" }, { at: waiting + 5, label: "answered" }] }, messages)
  end

  SCENARIOS = {
    question_leadin: lambda {
      asking_turn("The model's own question after a reply: the turn opens in the history.",
                  id: "turn-ql", tool: "ask_user_question", params: 'question="Which one?"', arguments: '{"question":"Which one?"}', words: "Both matter. Which first?",
                  pending: { id: "q1", kind: "question", question: "Which one?", options: [{ label: "A" }, { label: "B" }] }, answer: "A")
    },
    question_bare: lambda {
      asking_turn("The model's question with no reply before it.",
                  id: "turn-qb", tool: "ask_user_question", params: 'question="Which one?"', arguments: '{"question":"Which one?"}',
                  pending: { id: "q1", kind: "question", question: "Which one?", options: [{ label: "A" }, { label: "B" }] }, answer: "A")
    },
    approval_line: lambda {
      asking_turn("An approval with a line before its command.",
                  id: "turn-al", tool: "execute", params: 'command="echo ok"', arguments: '{"command":"echo ok"}', words: "Running the command.",
                  pending: approval("a1"), answer: "Allow once")
    },
    approval_bare: lambda {
      asking_turn("An approval with no line before its command.",
                  id: "turn-ab", tool: "execute", params: 'command="echo ok"', arguments: '{"command":"echo ok"}', pending: approval("a1"), answer: "Allow once")
    },
    relayed_approval: lambda {
      relay = { id: "r1", child_id: "ab12cd34-0000", child_short: "ab12cd34", child_question_id: "q9", task: "run it", chain: ["ab12cd34"], more: 0 }
      asking_turn("A delegate's approval relayed to the parent's page.",
                  id: "turn-ra", tool: "delegate", params: 'task="run it"', arguments: '{"task":"run it"}', words: "Handing it to a delegate.",
                  pending: approval("a1", header: "Approve delegate ab12cd34's tool call?", relay: relay), answer: "Allow once")
    },
    hook_question: lambda {
      asking_turn("A hook's question before a call runs.",
                  id: "turn-hq", tool: "execute", params: 'command="true"', arguments: '{"command":"true"}', words: "Running a command.",
                  pending: { id: "h1", kind: "hook", hook: "r0", question: "Run true?", options: %w[Yes No] }, answer: "Yes")
    },
    before_turn_hook: lambda {
      id = "turn-bh"
      pending = { id: "h1", kind: "hook", hook: "gate", question: "Start this turn?", options: %w[Yes No] }
      events = [started(id, "do it"), asked(pending), answered("h1", "Yes"), gen(1), text(1, "Done."), done(1), completed(id, "Done.")]
      with_turn_end({ description: "A before_turn hook's question before the first step.", prompt: "do it", turn_id: id, events: events,
                      cuts: [{ at: 2, label: "waiting" }, { at: 4, label: "answered" }] }, turn_messages(id, [], "Done."))
    },
    checkin_approval: lambda {
      id = "turn-ca"
      card = { type: :card, id: "check-in", source: "check-in", title: "3 tool calls, no answer yet", body: "Still on it?", level: "info",
               actions: [{ label: "Nudge", command: "/check-in nudge" }], in_turn: true }
      events = [started(id, "do it"), gen(1), call_started(1, "read", 'path="a"', "t1"), call_done(1, "read", 'path="a"', "t1", "[read]\na"),
                card, done(1), gen(2), text(2, "Running the command."), call_started(2, "execute", 'command="echo ok"', "t2"),
                asked(approval("a1")), answered("a1", "Allow once"), call_done(2, "execute", 'command="echo ok"', "t2", "[execute]\nok"), done(2),
                gen(3), text(3, "Done."), done(3), completed(id, "Done.")]
      messages = turn_messages(id, [{ words: "", calls: [tool_call("read", '{"path":"a"}', "[read]\na", "t1")] },
                                    { words: "Running the command.", calls: [tool_call("execute", '{"command":"echo ok"}', "[execute]\nok", "t2")] }], "Done.")
      with_turn_end({ description: "check-in's card still open, then an approval: two cards wait.", prompt: "do it", turn_id: id, events: events,
                      cuts: [{ at: 5, label: "checkin" }, { at: 10, label: "both" }, { at: 14, label: "approval answered" }] }, messages)
    },
    # The cards that settle: check-in's card redrawn without its actions, a
    # warning redrawn at info. An approval asks after its call's
    # tool_call_started (ToolRunner#run: the gate votes first, the ask comes
    # after the row), as in checkin_approval.
    checkin_settled: lambda {
      r1, c1 = read_step(1, "a", "t1")
      r2, c2 = read_step(2, "b", "t2")
      settle_turn("check-in's card asks, then is redrawn without its actions; the turn goes on.", id: "turn-cs", last: 3,
                  steps: [{ words: "", calls: [c1] }, { words: "", calls: [c2] }],
                  list: [*r1, checkin_asks, [:cut, "checkin"], done(1), *r2, checkin_settled, [:cut, "settled"], done(2)])
    },
    checkin_settled_then_approval: lambda {
      r1, c1 = read_step(1, "a", "t1")
      r2, c2 = read_step(2, "b", "t2")
      cmd = 'command="echo ok"'
      run = tool_call("execute", '{"command":"echo ok"}', "[execute]\nok", "t3")
      settle_turn("check-in's card settles, then an approval is asked and answered.", id: "turn-csa", last: 4,
                  steps: [{ words: "", calls: [c1] }, { words: "", calls: [c2] }, { words: "Running the command.", calls: [run] }],
                  list: [*r1, checkin_asks, [:cut, "checkin"], done(1), *r2, checkin_settled, [:cut, "settled"], done(2),
                         gen(3), text(3, "Running the command."), call_started(3, "execute", cmd, "t3"), asked(approval("a1")), [:cut, "approval waiting"],
                         answered("a1", "Allow once"), call_done(3, "execute", cmd, "t3", "[execute]\nok"),
                         done(3), [:cut, "approval answered"]])
    },
    approval_then_checkin_settled: lambda {
      r1, c1 = read_step(1, "a", "t1")
      r3, c3 = read_step(3, "b", "t3")
      cmd = 'command="echo ok"'
      run = tool_call("execute", '{"command":"echo ok"}', "[execute]\nok", "t2")
      settle_turn("An approval answered while check-in's card asks, then the card settles.", id: "turn-acs", last: 4,
                  steps: [{ words: "", calls: [c1] }, { words: "Running the command.", calls: [run] }, { words: "", calls: [c3] }],
                  list: [*r1, checkin_asks, [:cut, "checkin"], done(1), gen(2), text(2, "Running the command."),
                         call_started(2, "execute", cmd, "t2"), asked(approval("a1")), [:cut, "both"], answered("a1", "Allow once"),
                         call_done(2, "execute", cmd, "t2", "[execute]\nok"), done(2), [:cut, "approval answered"],
                         *r3, checkin_settled, [:cut, "settled"], done(3)])
    },
    question_no_leadin_with_checkin: lambda {
      r1, c1 = read_step(1, "a", "t1")
      params = 'question="Which one?"'
      ask = tool_call("ask_user_question", '{"question":"Which one?"}', "A", "t2")
      question = { id: "q1", kind: "question", question: "Which one?", options: [{ label: "A" }, { label: "B" }] }
      settle_turn("A question with no lead-in (its step has no text), asked and answered while check-in's card asks.", id: "turn-qnc", last: 3,
                  steps: [{ words: "", calls: [c1] }, { words: "", calls: [ask] }],
                  list: [*r1, checkin_asks, [:cut, "checkin"], done(1), gen(2), call_started(2, "ask_user_question", params, "t2"),
                         asked(question), [:cut, "both"], answered("q1", "A"), call_done(2, "ask_user_question", params, "t2", "A"),
                         done(2), [:cut, "question answered"]])
    },
    checkin_merged_line: lambda {
      r1, c1 = read_step(1, "a", "t1")
      r2, c2 = read_step(2, "b", "t2")
      settle_turn("A line merged into the turn between check-in's card arriving and settling.", id: "turn-cml", last: 3,
                  steps: [{ words: "", calls: [c1] }, { merged: ["also check b"], words: "", calls: [c2] }],
                  list: [*r1, checkin_asks, [:cut, "checkin"], done(1), *merged(2, "also check b")[0, 1], [:cut, "queued"], *merged(2, "also check b")[1..], [:cut, "merged"],
                         *r2, checkin_settled, [:cut, "settled"], done(2)])
    },
    merged_then_approval: lambda {
      r1, c1 = read_step(1, "a", "t1")
      cmd = 'command="echo ok"'
      run = tool_call("execute", '{"command":"echo ok"}', "[execute]\nok", "t2")
      settle_turn("A line merged into a turn nothing opened, then an approval under its lead-in: the turn opens first.", id: "turn-mta", last: 3,
                  steps: [{ words: "", calls: [c1] }, { merged: ["also check b"], words: "Running the command.", calls: [run] }],
                  list: [*r1, done(1), *merged(2, "also check b"), gen(2), text(2, "Running the command."),
                         call_started(2, "execute", cmd, "t2"), asked(approval("a1")), [:cut, "approval waiting"],
                         answered("a1", "Allow once"), call_done(2, "execute", cmd, "t2", "[execute]\nok"), done(2), [:cut, "approval answered"]])
    },
    warn_card_cleared: lambda {
      r1, c1 = read_step(1, "a", "t1")
      r3, c3 = read_step(3, "b", "t3")
      cmd = 'command="echo ok"'
      run = tool_call("execute", '{"command":"echo ok"}', "[execute]\nok", "t2")
      warn = { type: :card, id: "spend", source: "cost-cap", title: "Near the cost cap", body: "$4.80 of $5.00.", level: "warn", in_turn: true }
      settle_turn("A warn card, then an approval (the waiting cut), then the card redrawn at info.", id: "turn-wc", last: 4,
                  steps: [{ words: "", calls: [c1] }, { words: "Running the command.", calls: [run] }, { words: "", calls: [c3] }],
                  list: [*r1, warn, done(1), gen(2), text(2, "Running the command."), call_started(2, "execute", cmd, "t2"), asked(approval("a1")), [:cut, "both"],
                         answered("a1", "Allow once"), call_done(2, "execute", cmd, "t2", "[execute]\nok"),
                         done(2), [:cut, "approval answered"], *r3, warn.merge(level: "info", body: "Spend back under the cap."),
                         [:cut, "cleared"], done(3)])
    },
    two_approvals: lambda {
      id = "turn-2a"
      events = [started(id, "do it"), gen(1), text(1, "Running both commands."),
                call_started(1, "execute", 'command="echo ok"', "t1"), asked(approval("a1")), answered("a1", "Allow once"),
                call_done(1, "execute", 'command="echo ok"', "t1", "[execute]\nok"),
                call_started(1, "execute", 'command="echo ok"', "t2", 2), asked(approval("a2")), answered("a2", "Allow once"),
                call_done(1, "execute", 'command="echo ok"', "t2", "[execute]\nok", 2), done(1),
                gen(2), text(2, "Done."), done(2), completed(id, "Done.")]
      messages = turn_messages(id, [{ words: "Running both commands.", calls: [tool_call("execute", '{"command":"echo ok"}', "[execute]\nok", "t1"),
                                                                               tool_call("execute", '{"command":"echo ok"}', "[execute]\nok", "t2")] }], "Done.")
      with_turn_end({ description: "Two approvals from one step: one lead-in, for the first.", prompt: "do it", turn_id: id, events: events,
                      cuts: [{ at: 5, label: "first waiting" }, { at: 9, label: "second waiting" }, { at: 12, label: "second answered" }] }, messages)
    },
    question_after_approval: lambda {
      id = "turn-qa"
      question = { id: "q1", kind: "question", question: "Which one?", options: [{ label: "A" }, { label: "B" }] }
      events = [started(id, "do it"), gen(1), text(1, "Checking first."),
                call_started(1, "execute", 'command="echo ok"', "t1"), asked(approval("a1")), answered("a1", "Allow once"),
                call_done(1, "execute", 'command="echo ok"', "t1", "[execute]\nok"),
                call_started(1, "ask_user_question", 'question="Which one?"', "t2", 2), asked(question), answered("q1", "A"),
                call_done(1, "ask_user_question", 'question="Which one?"', "t2", "A", 2), done(1),
                gen(2), text(2, "Done."), done(2), completed(id, "Done.")]
      messages = turn_messages(id, [{ words: "Checking first.", calls: [tool_call("execute", '{"command":"echo ok"}', "[execute]\nok", "t1"),
                                                                        tool_call("ask_user_question", '{"question":"Which one?"}', "A", "t2")] }], "Done.")
      with_turn_end({ description: "A question after an approval in the same step: one lead-in, for the approval.", prompt: "do it", turn_id: id,
                      events: events, cuts: [{ at: 5, label: "approval waiting" }, { at: 9, label: "question waiting" },
                                             { at: 12, label: "question answered" }] }, messages)
    },
    step_limit: lambda {
      id = "turn-sl"
      pending = { id: "c1", kind: "continue", header: "Step limit", options: %w[Continue Stop], limit: 1,
                  question: "The turn ran out of iterations (1 steps) before it answered. Continue it?", allow_freeform: true,
                  context: { original_prompt: "do it" } }
      events = [started(id, "do it"), gen(1), text(1, "Step one."), call_started(1, "execute", 'command="true"', "t1"),
                call_done(1, "execute", 'command="true"', "t1", "[execute]\n"), done(1),
                # The turn's messages are the session's 1...4 (after its system message).
                completed(id, "Step one.").merge(kept_from: 1, kept_to: 4),
                { type: :continue_offered, context: { original_prompt: "do it" } }, asked(pending)]
      { description: "A turn that ran out of steps: the step-limit question after its end.", prompt: "do it", turn_id: id, events: events,
        messages: [user("do it", id), { role: "model", content: "Step one.", tool_calls: [{ id: "c1", name: "execute", arguments: '{"command":"true"}' }] },
                   { role: "tool_response", content: "[execute]\n", tool_call_id: "c1", tool_ids: ["t1"] }],
        cuts: [{ at: 9, label: "waiting" }] }
    }
  }.freeze
end
