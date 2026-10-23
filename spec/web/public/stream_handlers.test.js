import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createStreamHandlers } from "../../../lib/samagotchi/web/public/stream_handlers.js";

const ME = "tab-me";

// A page with recording hooks: every hook and view method pushes its name
// and arguments onto +calls+; the open session and its fields can change
// between events (page.open), as a session switch does.
function fakePage({ selected = "s1", running = false, read = null } = {}) {
  const calls = [];
  const rec = (name, ret) => (...args) => {
    calls.push([name, ...args]);
    return typeof ret === "function" ? ret(...args) : ret;
  };
  const page = {
    calls,
    selected,
    current: { model: "qwen", ctxWindow: 1000, llmContext: null, timing: { tokens: null, turnRecords: [] } },
    capabilities: {},
    guess: false,
    composerText: "",
    open(id, fields = {}) {
      page.selected = id;
      page.current = { model: "other", ctxWindow: 1000, llmContext: null, timing: { tokens: null, turnRecords: [] }, ...fields };
    },
    names: () => calls.map((c) => c[0]),
  };
  const liveTurn = {
    running,
    failedText: null,
    timing: { setNote: rec("timing.setNote"), detach: rec("timing.detach"), start: rec("timing.start") },
    releaseDisplay: rec("liveTurn.releaseDisplay"),
  };
  const historyEl = {
    scrollHeight: 0, scrollTop: 0, clientHeight: 0,
    querySelector: () => null,
  };
  const deps = {
    selected: () => page.selected,
    state: () => page.current,
    clientId: ME,
    capabilities: () => page.capabilities,
    historyEl,
    liveTurn,
    turnDom: new Proxy({}, { get: (_, name) => rec(`turnDom.${String(name)}`, name === "notice" ? true : undefined) }),
    shownTexts: { turnStarted: rec("shownTexts.turnStarted") },
    questionCards: new Proxy({}, { get: (_, name) => rec(`questionCards.${String(name)}`) }),
    contextChips: { refresh: rec("contextChips.refresh") },
    llmContextControl: { refresh: rec("llmContextControl.refresh") },
    thinkingControl: { refresh: rec("thinkingControl.refresh") },
    reasoningHistoryControl: { refresh: rec("reasoningHistoryControl.refresh") },
    sentIds: new Set(),
    earlyRestores: new Map(),
    stream: {
      takeGuess: () => {
        const guess = page.guess;
        page.guess = false;
        return guess;
      },
      restart: rec("stream.restart"),
    },
    composer: {
      empty: () => !page.composerText.trim(),
      refill: rec("composer.refill", (text) => { page.composerText = text; }),
      setChips: rec("composer.setChips"),
    },
    getSession: rec("getSession", read || (async () => ({ messages: [] }))),
    commandBubble: rec("commandBubble", null),
    findInTurnRoots: rec("findInTurnRoots", []),
    applyPromptOps: rec("applyPromptOps", "bubble"),
    readTurnEnd: rec("readTurnEnd", async () => {}),
    resync: rec("resync", async () => {}),
  };
  for (const name of [
    "updateInfoBar", "showSteers", "markRecapStale", "setTurnRunning", "setLiveStatus", "endTurnView", "appendChunk",
    "applyFinalMarkdown", "refreshTimingFromSession", "makeUserBubble", "addEndBubble", "addCommandBubble", "addNoteBubble",
    "setUsedMemories", "showRecap", "showGuardrailWarning", "showHookNotice", "onInitEvent", "upsertCard", "refreshCardBodies",
  ]) deps[name] = rec(name);
  return { page, deps, handlers: createStreamHandlers(deps), liveTurn };
}

test("every stream event type has its handler", () => {
  const { handlers } = fakePage();
  assert.deepEqual(Object.keys(handlers).sort(), [
    "answer_display", "card", "command_queued", "command_ran", "context_added", "context_status", "continue_offered",
    "continue_resolved", "empty_answer_retry", "generation_chunk", "generation_completed", "generation_retrying",
    "generation_started", "guardrail_warning", "hook_notice", "input_merged", "llm_context_edited", "merged_input",
    "participants_changed", "pending_input_merged", "plugin_init_finished", "plugin_init_started", "plugin_init_wait", "prompt_restored",
    "question_answered", "question_cancelled", "question_relay", "question_requested", "recap_ready", "reminder_injected",
    "reset", "side_usage", "steer_cut", "tool_call_completed", "tool_call_started", "turn_canceled", "turn_completed",
    "turn_dequeued", "turn_enqueued", "turn_failed", "turn_started", "used_memories_updated", "working_set_updated",
  ]);
});

test("participants_changed reads the owner's participants again; with no panel, it is ignored", () => {
  assert.doesNotThrow(() => fakePage().handlers.participants_changed({ participants: [] }));
  let reloads = 0;
  const page = fakePage();
  const handlers = createStreamHandlers({ ...page.deps, participantsControl: { reload: () => { reloads += 1; } } });
  handlers.participants_changed({ participants: [], joined: [], left: [] });
  assert.equal(reloads, 1);
});

test("working_set_updated goes to the working set; with it off (none), it is ignored", () => {
  const off = fakePage();
  assert.doesNotThrow(() => off.handlers.working_set_updated({ items: [], at: 2 }));
  const page = fakePage();
  const got = [];
  const handlers = createStreamHandlers({ ...page.deps, workingSet: { update: (snapshot) => got.push(snapshot) } });
  handlers.working_set_updated({ items: [{ kind: "file", key: "/a", state: "stale" }], at: 4, event_seq: 9 });
  assert.deepEqual(got, [{ items: [{ kind: "file", key: "/a", state: "stale" }], at: 4 }]);
});

test("a chunk goes to the turn view; its ctx lands on the session open at that moment", () => {
  const { page, handlers } = fakePage();
  const first = page.current;
  handlers.generation_chunk({ text: "hi", thinking: "", counts: { total_tokens: 120, context_window_tokens: 1000 } });
  assert.equal(first.ctxPct, 12);
  // A session switch mid-stream: the handlers read the new session's fields.
  page.open("s2");
  handlers.generation_chunk({ text: "there", thinking: "", counts: { total_tokens: 300, context_window_tokens: 1000 } });
  assert.equal(page.current.ctxPct, 30);
  assert.equal(first.ctxPct, 12);
  assert.deepEqual(page.names().filter((n) => n === "turnDom.chunk").length, 2);
  assert.equal(page.names().filter((n) => n === "updateInfoBar").length, 2);
});

test("generation_started and generation_completed set the window, served model and tokens", () => {
  const { page, handlers } = fakePage();
  handlers.generation_started({ context_window_tokens: 8192, context_window_source: "server" });
  assert.equal(page.current.ctxWindow, 8192);
  assert.equal(page.current.ctxWindowSource, "server");
  assert.equal(page.names().filter((n) => n === "updateInfoBar").length, 1);
  handlers.generation_started({ context_window_tokens: 8192, context_window_source: "server" });
  assert.equal(page.names().filter((n) => n === "updateInfoBar").length, 1);
  handlers.generation_completed({ served_model: "q2", requested_model: "q" });
  assert.deepEqual(page.current.served, ["q2", "q", null]);
  assert.equal(page.current.timing.modelSegments, undefined);
  // The server's whole list of rows per model replaces the page's.
  const rows = [{ model_ref: "a:one" }, { model_ref: "b:two" }];
  handlers.generation_completed({ tokens: { prompt_sum: 1 }, model_segments: rows });
  assert.deepEqual(page.current.timing.modelSegments, rows);
  assert.ok(page.names().includes("turnDom.generationCompleted"));
});

test("turn_completed appends an unstreamed answer from turn_summary.output", async () => {
  const { page, handlers } = fakePage();
  await handlers.turn_completed({ turn_summary: { output: "answer", empty_answer: null } });

  assert.ok(page.calls.some(([name, text]) => name === "appendChunk" && text === "answer"));
});

// After /model (Engine#announce_switched_context!): the new model's window
// and its %, or usage null when the window didn't resolve.
test("context_status after /model sets the window and the %, and usage null clears the %", () => {
  const { page, handlers } = fakePage();
  page.current.ctxPct = 80;
  handlers.context_status({ usage: { estimated_pct: 10 }, bucket: "under20", context_window_tokens: 128000,
                            context_window_source: "server" });
  assert.equal(page.current.ctxPct, 10);
  assert.equal(page.current.ctxWindow, 128000);
  assert.equal(page.current.ctxWindowSource, "server");

  handlers.context_status({ usage: null, bucket: null, context_window_tokens: null });
  assert.equal(page.current.ctxPct, null);
  assert.equal(page.current.ctxWindow, null);
  assert.equal(page.current.ctxWindowSource, null);
  assert.equal(page.names().filter((n) => n === "updateInfoBar").length, 2);
});

// The old model's window is gone after a switch whose new one didn't
// resolve: a chunk's counts (no window in them) count no % until a window
// comes; a turn's own context_status (no window key) keeps the window.
test("context_status: after an unresolved /model a chunk sets no %, and a turn's estimate keeps the window", () => {
  const { page, handlers } = fakePage();
  page.current.ctxWindow = 8192;
  handlers.context_status({ usage: null, bucket: null, context_window_tokens: null, context_window_source: null });
  handlers.generation_chunk({ text: "x", thinking: "", counts: { prompt_tokens: 6000, completion_tokens: 200, total_tokens: 6200 } });
  assert.equal(page.current.ctxPct, null);
  handlers.generation_started({ context_window_tokens: 32000, context_window_source: "server" });
  handlers.generation_chunk({ text: "y", thinking: "", counts: { prompt_tokens: 6000, completion_tokens: 200, total_tokens: 6200 } });
  assert.equal(page.current.ctxPct, (6200 / 32000) * 100);
  handlers.context_status({ usage: { estimated_pct: 20 }, bucket: "20to40" });
  assert.equal(page.current.ctxPct, 20);
  assert.equal(page.current.ctxWindow, 32000);
});

// The ctx tooltip's "until the next request" (ctxBarTip): set by a switch's
// unresolved window, gone with a window or when the next request starts.
test("context_status: an unresolved /model marks the window unknown until the next request starts or a window comes", () => {
  const { page, handlers } = fakePage();
  handlers.context_status({ usage: null, bucket: null, context_window_tokens: null });
  assert.equal(page.current.ctxUnknownAfterSwitch, true);
  handlers.generation_started({ context_window_tokens: null });
  assert.equal(page.current.ctxUnknownAfterSwitch, false);
  handlers.context_status({ usage: null, bucket: null, context_window_tokens: null });
  assert.equal(page.current.ctxUnknownAfterSwitch, true);
  handlers.context_status({ usage: { estimated_pct: 10 }, bucket: "under20", context_window_tokens: 128000,
                            context_window_source: "server" });
  assert.equal(page.current.ctxUnknownAfterSwitch, false);
});

test("turn_started on a guessed stream that replays a drawn turn restarts the stream only", () => {
  const { page, handlers } = fakePage();
  page.guess = true;
  page.current.timing.turnRecords = [{ id: "t1" }];
  handlers.turn_started({ type: "turn_started", turn_id: "t1" });
  assert.deepEqual(page.names(), ["stream.restart"]);
  assert.equal(page.guess, false);
});

test("turn_started draws the turn: prompt ops, running, the turn view, the timing line", () => {
  const { page, handlers } = fakePage();
  page.guess = true; // a guess, but a new turn: drawn as any other
  handlers.turn_started({ type: "turn_started", turn_id: "t9", started_at: 5 });
  assert.deepEqual(page.names(), [
    "turnDom.handOff", "markRecapStale", "shownTexts.turnStarted", "applyPromptOps", "setTurnRunning", "setLiveStatus",
    "timing.detach", "turnDom.turnStarted", "timing.start",
  ]);
  const started = page.calls.find((c) => c[0] === "turnDom.turnStarted")[1];
  assert.equal(started.promptBubble, "bubble");
});

test("turn_failed keeps a rolled-back turn's line for its prompt_restored", () => {
  const { handlers, liveTurn } = fakePage();
  handlers.turn_failed({ error: "boom" });
  assert.ok(liveTurn.failedText);
  handlers.turn_failed({ error: "boom", kept_steps: 2 });
  assert.equal(liveTurn.failedText, null);
});

// A continue turn's origin carries its offer turn's enqueued_id (the
// original prompt's bubble key). Its failure ends the turn view only: no
// prompt_restored follows a continue turn, so no failed bubble reuses the key.
test("turn_failed of a continue turn (origin with the offer turn's enqueued_id) draws no user bubble", () => {
  const { page, handlers } = fakePage();
  handlers.turn_failed({ error: "boom", continue: true, origin: { client_id: ME, enqueued_id: "e1" } });
  assert.ok(!page.names().includes("makeUserBubble"));
});

test("prompt_restored: this tab's sent prompt refills an empty composer, then the failed bubble and line", async () => {
  const { page, deps, handlers, liveTurn } = fakePage();
  deps.sentIds.add("e1");
  liveTurn.failedText = "✕ failed";
  await handlers.prompt_restored({ prompt: "again", origin: { client_id: ME, enqueued_id: "e1" } });
  assert.equal(page.composerText, "again");
  assert.deepEqual(page.names(), ["composer.refill", "resync", "makeUserBubble", "addEndBubble"]);
  assert.equal(page.calls[2][2].state, "failed");
  assert.equal(liveTurn.failedText, null);
});

test("prompt_restored: a full composer keeps its text", async () => {
  const { page, deps, handlers } = fakePage();
  deps.sentIds.add("e1");
  page.composerText = "typing";
  await handlers.prompt_restored({ prompt: "again", origin: { client_id: ME, enqueued_id: "e1" } });
  assert.equal(page.composerText, "typing");
  assert.ok(!page.names().includes("composer.refill"));
});

test("command_ran: a /model run sets the open session's model and draws its bubble", async () => {
  const { page, handlers } = fakePage();
  page.open("s2", { model: "old" });
  await handlers.command_ran({ line: "/model new", output: "ok", model_name: "new", client_id: ME });
  assert.equal(page.current.model, "new");
  assert.equal(page.current.served, null);
  assert.deepEqual(page.names(), ["updateInfoBar", "addCommandBubble"]);
});

test("command_ran: this tab's busy command comes back into an empty composer, not another tab's or over a draft", async () => {
  const busy = { line: "/foo\n> q\n\nmy note", status: "busy", output: "busy: wait for the turn to end" };
  const { page, handlers } = fakePage();
  await handlers.command_ran({ ...busy, client_id: ME });
  assert.equal(page.composerText, "/foo\n> q\n\nmy note");
  const other = fakePage();
  await other.handlers.command_ran({ ...busy, client_id: "tab-other" });
  assert.equal(other.page.composerText, "");
  const drafted = fakePage();
  drafted.page.composerText = "new draft";
  await drafted.handlers.command_ran({ ...busy, client_id: ME });
  assert.equal(drafted.page.composerText, "new draft");
  const ran = fakePage();
  await ran.handlers.command_ran({ line: "/foo x", status: "ok", client_id: ME });
  assert.equal(ran.page.composerText, "");
});

test("command_ran: /llm-context and /thinking refresh their chips", async () => {
  const { page, handlers } = fakePage();
  await handlers.command_ran({ line: "/thinking low", llm_context: { strategy: "stale" }, thinking: { level: "low" } });
  assert.deepEqual(page.current.llmContext, { strategy: "stale" });
  assert.deepEqual(page.current.thinking, { level: "low" });
  assert.ok(page.names().includes("llmContextControl.refresh"));
  assert.ok(page.names().includes("thinkingControl.refresh"));
});

test("command_ran: /reasoning-history refreshes its chip, and a null (a native host after /model) hides it", async () => {
  const { page, handlers } = fakePage();
  await handlers.command_ran({ line: "/reasoning-history all", reasoning_history: { level: "all", source: "session", own: "all" } });
  assert.deepEqual(page.current.reasoningHistory, { level: "all", source: "session", own: "all" });
  assert.ok(page.names().includes("reasoningHistoryControl.refresh"));
  await handlers.command_ran({ line: "/model box:gemma", model_name: "box:gemma", reasoning_history: null });
  assert.equal(page.current.reasoningHistory, null);
  const { page: other, handlers: plain } = fakePage();
  other.current.reasoningHistory = { level: "turn" };
  await plain.command_ran({ line: "/help", output: "commands" });
  assert.deepEqual(other.current.reasoningHistory, { level: "turn" });
});

test("command_ran: a !cmd the resync drew gets no second bubble", async () => {
  const { page, deps } = fakePage();
  const drawn = { querySelector: () => ({ textContent: "!ls" }) };
  deps.findInTurnRoots = () => [drawn];
  const handlers = createStreamHandlers(deps);
  await handlers.command_ran({ line: "!ls", output: "a", changed: ["messages"] });
  assert.deepEqual(page.names(), ["resync"]);
});

// A switch while the handler re-read the session: what it would draw is the
// other session's, so the session open now gets nothing.
test("command_ran: a switch during its resync draws nothing in the session open then", async () => {
  const { page, deps } = fakePage();
  deps.resync = async () => page.open("s2");
  const handlers = createStreamHandlers(deps);
  await handlers.command_ran({ line: "!ls", output: "a", changed: ["messages"] });
  assert.deepEqual(page.names(), []);
});

test("prompt_restored: a switch during its resync draws nothing in the session open then", async () => {
  const { page, deps, liveTurn } = fakePage();
  deps.resync = async () => page.open("s2");
  const handlers = createStreamHandlers(deps);
  liveTurn.failedText = "✕ failed";
  await handlers.prompt_restored({ prompt: "again", origin: { client_id: "tab-other", enqueued_id: "e1" } });
  assert.deepEqual(page.names(), []);
  assert.equal(liveTurn.failedText, null);
});

test("command_queued: an anytime command's bubble, once; a card's action waits", () => {
  const { page, handlers } = fakePage();
  handlers.command_queued({ anytime: true, line: "/help", command_id: "c1" });
  handlers.command_queued({ anytime: true, card: true, line: "/continue", command_id: "c2" });
  assert.deepEqual(page.names().filter((n) => n === "addCommandBubble").length, 1);
});

test("hook_notice: one the page shows elsewhere (by its capabilities then) isn't drawn", () => {
  const { page, handlers } = fakePage();
  handlers.hook_notice({ line: "links", fallback_for: "source_links" });
  assert.deepEqual(page.names(), ["turnDom.notice"]);
  page.capabilities = { source_links: true };
  handlers.hook_notice({ line: "links", fallback_for: "source_links" });
  assert.deepEqual(page.names(), ["turnDom.notice"]);
});

// A side request (recap, /btw) counted: the ctx tooltip's side line at once.
test("side_usage puts the side block on the open session's timing and re-renders the info bar", () => {
  const { page, handlers } = fakePage();
  const side = { requests: 1, by_kind: { btw: { requests: 1 } } };
  handlers.side_usage({ kind: "btw", side });
  assert.deepEqual(page.current.timing.side, side);
  assert.equal(page.names().filter((n) => n === "updateInfoBar").length, 1);
  handlers.side_usage({ kind: "btw" });
  assert.deepEqual(page.current.timing.side, side);
  assert.equal(page.names().filter((n) => n === "updateInfoBar").length, 1);
});

test("recap_ready shows the recap only with no turn running", () => {
  const idle = fakePage();
  idle.handlers.recap_ready({ recap: "r" });
  assert.ok(idle.page.names().includes("showRecap"));
  const busy = fakePage({ running: true });
  busy.handlers.recap_ready({ recap: "r" });
  assert.ok(!busy.page.names().includes("showRecap"));
});

test("merged_input: this tab's prompt is own; another client's carries its label", () => {
  const { page, handlers } = fakePage();
  handlers.merged_input({ content: "mine", origins: [{ client_id: ME, enqueued_id: "e1" }] });
  handlers.merged_input({ content: "theirs", origins: [{ client_id: "tui-1" }] });
  const [mine, theirs] = page.calls.filter((c) => c[0] === "makeUserBubble");
  assert.equal(mine[2].own, true);
  assert.equal(mine[2].label, null);
  assert.equal(theirs[2].own, false);
  assert.ok(theirs[2].label);
});

test("answer_display re-reads the session open at that moment", async () => {
  const { page, handlers } = fakePage();
  page.open("s7");
  await handlers.answer_display({ display: true });
  const read = page.calls.find((c) => c[0] === "getSession");
  assert.equal(read[1], "s7");
  assert.ok(page.names().includes("applyFinalMarkdown"));
  assert.ok(page.names().includes("liveTurn.releaseDisplay"));
});

test("answer_display: a switch during the re-read leaves the open session's answers alone", async () => {
  let fake;
  fake = fakePage({ read: async () => { fake.page.open("s8"); return { messages: [] }; } });
  fake.page.open("s7");
  await fake.handlers.answer_display({ display: true });
  assert.equal(fake.page.calls.find((c) => c[0] === "getSession")[1], "s7");
  assert.equal(fake.page.names().includes("applyFinalMarkdown"), false);
  assert.ok(fake.page.names().includes("liveTurn.releaseDisplay"));
});

test("answer_display: a switch while the turn's end was read re-reads nothing", async () => {
  const { page, handlers, liveTurn } = fakePage();
  page.open("s7");
  liveTurn.endRead = Promise.resolve().then(() => page.open("s8"));
  await handlers.answer_display({ display: true });
  assert.equal(page.calls.some((c) => c[0] === "getSession"), false);
  assert.ok(page.names().includes("liveTurn.releaseDisplay"));
});

test("answer_display with refs only (no display) re-reads; with neither it doesn't; both release the display wait", async () => {
  const refsOnly = fakePage();
  refsOnly.page.open("s7");
  await refsOnly.handlers.answer_display({ display: null, refs: 2 });
  assert.ok(refsOnly.page.calls.some((c) => c[0] === "getSession"));
  assert.ok(refsOnly.page.names().includes("applyFinalMarkdown"));
  assert.ok(refsOnly.page.names().includes("liveTurn.releaseDisplay"));
  const none = fakePage();
  none.page.open("s7");
  await none.handlers.answer_display({ display: null });
  assert.equal(none.page.calls.some((c) => c[0] === "getSession"), false);
  assert.equal(none.page.names().includes("applyFinalMarkdown"), false);
  assert.ok(none.page.names().includes("liveTurn.releaseDisplay"));
});

test("reset and card", () => {
  const { page, handlers } = fakePage();
  handlers.reset();
  handlers.card({ id: "c", body: "x" });
  assert.deepEqual(page.names(), ["resync", "upsertCard", "refreshCardBodies"]);
});

test("question_requested: a question's refs go on its step before the card draws (the asking slot pairs them); none, no call", () => {
  const { page, handlers } = fakePage();
  const refs = [{ match: "DEMO-123", kind: "issue", target: { id: "DEMO-123" } }];
  handlers.question_requested({ pending_question: { id: "q1", question: "Go?", refs } });
  assert.deepEqual(page.names(), ["turnDom.questionRefs", "questionCards.renderQuestion"]);
  handlers.question_requested({ pending_question: { id: "q2", question: "Go?" } });
  assert.deepEqual(page.names().slice(2), ["questionCards.renderQuestion"]);
  handlers.question_requested({ pending_question: null });
  assert.equal(page.names().length, 3);
});
