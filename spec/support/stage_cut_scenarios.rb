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
  def asking_turn(description, id:, tool:, params:, pending:, answer:, words: "")
    step1 = [gen(1), *(words.empty? ? [] : [text(1, words)]), call_started(1, tool, params, "t1")]
    events = [started(id, "do it"), *step1, asked(pending), answered(pending[:id], answer),
              call_done(1, tool, params, "t1", "[#{tool}]\nok"), done(1), gen(2), text(2, "Done."), done(2), completed(id, "Done.")]
    waiting = 1 + step1.size + 1
    { description: description, prompt: "do it", turn_id: id, events: events,
      cuts: [{ at: waiting, label: "waiting" }, { at: waiting + 5, label: "answered" }] }
  end

  SCENARIOS = {
    question_leadin: lambda {
      asking_turn("The model's own question after a reply: the turn opens in the history.",
                  id: "turn-ql", tool: "ask_user_question", params: 'question="Which one?"', words: "Both matter. Which first?",
                  pending: { id: "q1", kind: "question", question: "Which one?", options: [{ label: "A" }, { label: "B" }] }, answer: "A")
    },
    question_bare: lambda {
      asking_turn("The model's question with no reply before it.",
                  id: "turn-qb", tool: "ask_user_question", params: 'question="Which one?"',
                  pending: { id: "q1", kind: "question", question: "Which one?", options: [{ label: "A" }, { label: "B" }] }, answer: "A")
    },
    approval_line: lambda {
      asking_turn("An approval with a line before its command.",
                  id: "turn-al", tool: "execute", params: 'command="echo ok"', words: "Running the command.",
                  pending: approval("a1"), answer: "Allow once")
    },
    approval_bare: lambda {
      asking_turn("An approval with no line before its command.",
                  id: "turn-ab", tool: "execute", params: 'command="echo ok"', pending: approval("a1"), answer: "Allow once")
    },
    relayed_approval: lambda {
      relay = { id: "r1", child_id: "ab12cd34-0000", child_short: "ab12cd34", child_question_id: "q9", task: "run it", chain: ["ab12cd34"], more: 0 }
      asking_turn("A delegate's approval relayed to the parent's page.",
                  id: "turn-ra", tool: "delegate", params: 'task="run it"', words: "Handing it to a delegate.",
                  pending: approval("a1", header: "Approve delegate ab12cd34's tool call?", relay: relay), answer: "Allow once")
    },
    hook_question: lambda {
      asking_turn("A hook's question before a call runs.",
                  id: "turn-hq", tool: "execute", params: 'command="true"', words: "Running a command.",
                  pending: { id: "h1", kind: "hook", hook: "r0", question: "Run true?", options: %w[Yes No] }, answer: "Yes")
    },
    before_turn_hook: lambda {
      id = "turn-bh"
      pending = { id: "h1", kind: "hook", hook: "gate", question: "Start this turn?", options: %w[Yes No] }
      events = [started(id, "do it"), asked(pending), answered("h1", "Yes"), gen(1), text(1, "Done."), done(1), completed(id, "Done.")]
      { description: "A before_turn hook's question before the first step.", prompt: "do it", turn_id: id, events: events,
        cuts: [{ at: 2, label: "waiting" }, { at: 4, label: "answered" }] }
    },
    checkin_approval: lambda {
      id = "turn-ca"
      card = { type: :card, id: "check-in", source: "check-in", title: "3 tool calls, no answer yet", body: "Still on it?", level: "info",
               actions: [{ label: "Nudge", command: "/check-in nudge" }], in_turn: true }
      events = [started(id, "do it"), gen(1), call_started(1, "read", 'path="a"', "t1"), call_done(1, "read", 'path="a"', "t1", "[read]\na"),
                card, done(1), gen(2), text(2, "Running the command."), call_started(2, "execute", 'command="echo ok"', "t2"),
                asked(approval("a1")), answered("a1", "Allow once"), call_done(2, "execute", 'command="echo ok"', "t2", "[execute]\nok"), done(2),
                gen(3), text(3, "Done."), done(3), completed(id, "Done.")]
      { description: "check-in's card still open, then an approval: two cards wait.", prompt: "do it", turn_id: id, events: events,
        cuts: [{ at: 5, label: "checkin" }, { at: 10, label: "both" }, { at: 14, label: "approval answered" }] }
    },
    two_approvals: lambda {
      id = "turn-2a"
      events = [started(id, "do it"), gen(1), text(1, "Running both commands."),
                call_started(1, "execute", 'command="echo ok"', "t1"), asked(approval("a1")), answered("a1", "Allow once"),
                call_done(1, "execute", 'command="echo ok"', "t1", "[execute]\nok"),
                call_started(1, "execute", 'command="echo ok"', "t2", 2), asked(approval("a2")), answered("a2", "Allow once"),
                call_done(1, "execute", 'command="echo ok"', "t2", "[execute]\nok", 2), done(1),
                gen(2), text(2, "Done."), done(2), completed(id, "Done.")]
      { description: "Two approvals from one step: one lead-in, for the first.", prompt: "do it", turn_id: id, events: events,
        cuts: [{ at: 5, label: "first waiting" }, { at: 9, label: "second waiting" }, { at: 12, label: "second answered" }] }
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
      { description: "A question after an approval in the same step: one lead-in, for the approval.", prompt: "do it", turn_id: id,
        events: events, cuts: [{ at: 5, label: "approval waiting" }, { at: 9, label: "question waiting" }, { at: 12, label: "question answered" }] }
    },
    step_limit: lambda {
      id = "turn-sl"
      pending = { id: "c1", kind: "continue", header: "Step limit", options: %w[Continue Stop], limit: 1,
                  question: "The turn ran out of iterations (1 steps) before it answered. Continue it?", allow_freeform: true,
                  context: { original_prompt: "do it" } }
      events = [started(id, "do it"), gen(1), text(1, "Step one."), call_started(1, "execute", 'command="true"', "t1"),
                call_done(1, "execute", 'command="true"', "t1", "[execute]\n"), done(1), completed(id, "Step one."),
                { type: :continue_offered, context: { original_prompt: "do it" } }, asked(pending)]
      { description: "A turn that ran out of steps: the step-limit question after its end.", prompt: "do it", turn_id: id, events: events,
        messages: [user("do it", id), { role: "model", content: "Step one.", tool_calls: [{ id: "c1", name: "execute", arguments: '{"command":"true"}' }] },
                   { role: "tool_response", content: "[execute]\n", tool_call_id: "c1", tool_ids: ["t1"] }],
        cuts: [{ at: 9, label: "waiting" }] }
    }
  }.freeze
end
