import test from "node:test";
import assert from "node:assert/strict";
import { createStreamHandlers } from "../../../lib/samagotchi/web/public/stream_handlers.js";

const ME = "tab-me";

// A page with recording hooks: every hook and view method pushes its name
// and arguments onto +calls+; the open session and its fields can change
// between events (page.open), as a session switch does.
function fakePage({ selected = "s1", running = false } = {}) {
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
    getSession: rec("getSession", async () => ({ messages: [] })),
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
    "pending_input_merged", "plugin_init_finished", "plugin_init_started", "plugin_init_wait", "prompt_restored",
    "question_answered", "question_cancelled", "question_relay", "question_requested", "recap_ready", "reminder_injected",
    "reset", "steer_cut", "tool_call_completed", "tool_call_started", "turn_canceled", "turn_completed",
    "turn_enqueued", "turn_failed", "turn_started", "used_memories_updated",
  ]);
});

test("a chunk goes to the turn view; its ctx lands on the session open at that moment", () => {
  const { page, handlers } = fakePage();
  const first = page.current;
  handlers.generation_chunk({ content: "hi", ctx_pct: 12 });
  assert.equal(first.ctxPct, 12);
  // A session switch mid-stream: the handlers read the new session's fields.
  page.open("s2");
  handlers.generation_chunk({ content: "there", ctx_pct: 30 });
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
  handlers.generation_completed({ served_model: "q2", requested_model: "q" });
  assert.deepEqual(page.current.served, ["q2", "q", null]);
  assert.ok(page.names().includes("turnDom.generationCompleted"));
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

test("command_ran: /llm-context and /thinking refresh their chips", async () => {
  const { page, handlers } = fakePage();
  await handlers.command_ran({ line: "/thinking low", llm_context: { strategy: "stale" }, thinking: { level: "low" } });
  assert.deepEqual(page.current.llmContext, { strategy: "stale" });
  assert.deepEqual(page.current.thinking, { level: "low" });
  assert.ok(page.names().includes("llmContextControl.refresh"));
  assert.ok(page.names().includes("thinkingControl.refresh"));
});

test("command_ran: a !cmd the resync drew gets no second bubble", async () => {
  const { page, deps } = fakePage();
  const drawn = { querySelector: () => ({ textContent: "!ls" }) };
  deps.findInTurnRoots = () => [drawn];
  const handlers = createStreamHandlers(deps);
  await handlers.command_ran({ line: "!ls", output: "a", changed: ["messages"] });
  assert.deepEqual(page.names(), ["resync"]);
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

test("reset and card", () => {
  const { page, handlers } = fakePage();
  handlers.reset();
  handlers.card({ id: "c", body: "x" });
  assert.deepEqual(page.names(), ["resync", "upsertCard", "refreshCardBodies"]);
});
