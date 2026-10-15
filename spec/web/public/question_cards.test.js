import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createQuestionCards } from "../../../lib/samagotchi/web/public/question_cards.js";

// A small DOM stand-in: elements with classList, children, listeners and a
// querySelector for the selectors the cards use (tag, .class, :checked,
// descendant, "a, b").
class FakeEl {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parent = null;
    this.dataset = {};
    this.classes = new Set();
    this.listeners = {};
    this.textContent = "";
    this.disabled = false;
    this.checked = false;
    this.value = "";
    this.isConnected = false;
    const el = this;
    this.classList = {
      add: (...c) => c.forEach((x) => el.classes.add(x)),
      remove: (...c) => c.forEach((x) => el.classes.delete(x)),
      contains: (c) => el.classes.has(c),
    };
  }
  set className(v) { this.classes = new Set(String(v).split(/\s+/).filter(Boolean)); }
  get className() { return [...this.classes].join(" "); }
  appendChild(c) { this.children.push(c); c.parent = this; return c; }
  insertBefore(c, ref) {
    const i = this.children.indexOf(ref);
    if (i < 0) return this.appendChild(c);
    this.children.splice(i, 0, c);
    c.parent = this;
    return c;
  }
  remove() {
    if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this);
    this.parent = null;
    this.isConnected = false;
  }
  replaceWith(other) {
    const siblings = this.parent.children;
    siblings[siblings.indexOf(this)] = other;
    other.parent = this.parent;
    this.parent = null;
  }
  get nextSibling() {
    const siblings = this.parent?.children || [];
    return siblings[siblings.indexOf(this) + 1] || null;
  }
  setAttribute(name, value) { (this.attrs ||= {})[name] = String(value); }
  getAttribute(name) { return this.attrs?.[name] ?? null; }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  click() { (this.listeners.click || []).forEach((fn) => fn({})); }
  focus() { this.focused = true; }
  matchesOne(sel) {
    const m = sel.match(/^([a-z]*)((?:\.[\w-]+)*)(:checked)?$/);
    if (!m) throw new Error(`selector ${sel}`);
    if (m[1] && this.tagName !== m[1].toUpperCase()) return false;
    if (m[3] && !this.checked) return false;
    return m[2].split(".").filter(Boolean).every((c) => this.classes.has(c));
  }
  matches(sel) {
    return sel.split(",").some((part) => {
      const steps = part.trim().split(/\s+/);
      if (!this.matchesOne(steps.pop())) return false;
      let up = this.parent;
      while (steps.length && up) {
        if (up.matchesOne(steps[steps.length - 1])) steps.pop();
        up = up.parent;
      }
      return steps.length === 0;
    });
  }
  descendants() { return this.children.flatMap((c) => [c, ...c.descendants()]); }
  querySelectorAll(sel) { return this.descendants().filter((d) => d.matches(sel)); }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  closest(sel) {
    for (let n = this; n; n = n.parent) if (n.matches(sel)) return n;
    return null;
  }
}

function setup({ near = true, fail = null, page = {}, asking = "" } = {}) {
  const history = new FakeEl("div");
  const calls = [];
  const call = (name) => (...args) => {
    calls.push([name, ...args]);
    // fail: the message, or api()'s error fields ({message, status, code}).
    if (!fail) return Promise.resolve({});
    return Promise.reject(typeof fail === "string" ? new Error(fail) : Object.assign(new Error(fail.message), fail));
  };
  let scrolled = 0;
  let hintDrops = 0;
  const cards = createQuestionCards({
    sessionId: () => "s1",
    clientId: "web-me",
    place: (card) => { history.appendChild(card); card.isConnected = true; },
    isNearBottom: () => (typeof near === "function" ? near(history) : near),
    scrollToEnd: () => { scrolled += 1; },
    removeHintIfEmpty: () => { hintDrops += 1; },
    askingText: () => asking,
    api: { sendAnswer: call("sendAnswer"), dismissQuestion: call("dismissQuestion"), sendCommand: call("sendCommand") },
    doc: {
      createElement: (tag) => new FakeEl(tag),
      createTextNode: (text) => Object.assign(new FakeEl("#text"), { textContent: text }),
      // page: {activeElement, body, prompt} for the focus rule.
      get activeElement() { return page.activeElement ?? null; },
      body: page.body ?? null,
      getElementById: (id) => (id === "prompt" ? page.prompt ?? null : null),
    },
  });
  return { cards, history, calls, scrolled: () => scrolled, hintDrops: () => hintDrops };
}

const flush = () => new Promise((r) => setImmediate(r));
const PQ = { id: "q1", question: "Which one?", options: ["a", "b"], allow_freeform: true };

test("a question: an open card with its options, a freeform box, Submit and Dismiss", () => {
  const { cards, history, scrolled, hintDrops } = setup();
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  assert.equal(history.children[0], card);
  assert.equal(card.className, "bubble question");
  assert.equal(card.dataset.qid, "q1");
  assert.equal(card.open, true);
  assert.equal(card.querySelector("summary").textContent, "Question");
  assert.equal(card.querySelector(".question-text").textContent, "Which one?");
  assert.deepEqual(card.querySelectorAll(".question-option input").map((i) => [i.type, i.value, i.name]),
    [["radio", "a", "q-q1"], ["radio", "b", "q-q1"]]);
  assert.equal(card.querySelector(".question-freeform").placeholder, "Other…");
  assert.equal(card.querySelector(".question-dismiss").textContent, "Dismiss");
  assert.equal(cards.pendingQuestion(), PQ);
  assert.equal(scrolled(), 1);
  assert.equal(hintDrops(), 1);
});

// Placing the card makes the history taller: whether to follow is read
// before (a reader at the end stays there, the card in view).
test("a question follows a history that was at its end before the card went in", () => {
  const { cards, scrolled } = setup({ near: (history) => history.children.length === 0 });
  cards.renderQuestion(PQ);
  assert.equal(scrolled(), 1);
});

test("a question leaves a history scrolled up where it is", () => {
  const { cards, scrolled } = setup({ near: false });
  cards.renderQuestion(PQ);
  assert.equal(scrolled(), 0);
});

test("the same question again is one card", () => {
  const { cards, history } = setup();
  cards.renderQuestion(PQ);
  cards.renderQuestion({ ...PQ });
  assert.equal(history.children.length, 1);
});

test("Submit with nothing chosen says so; with a pick it sends the answer to the session", async () => {
  const { cards, calls } = setup();
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  card.querySelector(".question-submit").click();
  assert.equal(card.querySelector(".question-error").classList.contains("hidden"), false);
  assert.equal(calls.length, 0);
  card.querySelectorAll(".question-option input")[1].checked = true;
  card.querySelector(".question-freeform").value = "  and why  ";
  card.querySelector(".question-submit").click();
  assert.deepEqual(calls, [["sendAnswer", "s1", { id: "q1", selected: ["b"], freeform: "and why" }]]);
  assert.equal(card.classList.contains("submitting"), true);
  assert.equal(card.querySelector(".question-error").classList.contains("hidden"), true);
});

test("a send to a stopped session says to restart it", async () => {
  const { cards } = setup({ fail: { message: "no live bridge for session s1", status: 503, code: "not_live" } });
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  card.querySelectorAll(".question-option input")[0].checked = true;
  card.querySelector(".question-submit").click();
  await flush();
  assert.equal(card.querySelector(".question-error").textContent, "Session is not running — restart it to answer.");
  assert.equal(card.querySelector(".question-submit").disabled, false);
  assert.equal(card.classList.contains("submitting"), false);
});

// 4.27: a live worker that failed the request (the server's 502 bridge_error)
// is not a session that isn't running: the card shows what the worker said.
test("a send the worker failed shows its detail, not the restart line", async () => {
  const { cards } = setup({ fail: "the question desk raised" });
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  card.querySelectorAll(".question-option input")[0].checked = true;
  card.querySelector(".question-submit").click();
  await flush();
  assert.equal(card.querySelector(".question-error").textContent, "the question desk raised");
  assert.equal(card.querySelector(".question-submit").disabled, false);
});

test("a dismissal the worker failed shows its detail too", async () => {
  const { cards } = setup({ fail: "the question desk raised" });
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  card.querySelector(".question-dismiss").click();
  await flush();
  assert.equal(card.querySelector(".question-error").textContent, "the question desk raised");
  assert.equal(card.querySelector(".question-dismiss").disabled, false);
});

test("Dismiss leaves the question unanswered", () => {
  const { cards, calls } = setup();
  cards.renderQuestion(PQ);
  cards.questionCard().querySelector(".question-dismiss").click();
  assert.deepEqual(calls, [["dismissQuestion", "s1", "q1"]]);
});

test("answered (here or elsewhere): marked, disabled, collapsed to the result; a replay is a no-op", () => {
  const { cards } = setup();
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  cards.resolveQuestion("q1", { answer: { selected: ["a"] } });
  assert.equal(card.classList.contains("answered"), true);
  assert.equal(card.querySelectorAll(".question-option input")[0].checked, true);
  assert.equal(card.querySelector(".question-option").classList.contains("selected"), true);
  assert.ok(card.querySelectorAll("input, button").every((el) => el.disabled));
  assert.equal(card.open, false);
  assert.equal(card.querySelectorAll(".question-result").length, 1);
  assert.equal(cards.pendingQuestion(), null);
  cards.resolveQuestion("q1", { answer: { selected: ["a"] } });
  assert.equal(card.querySelectorAll(".question-result").length, 1);
});

test("another question's resolve leaves this one; a hand-toggled card stays as left", () => {
  const { cards } = setup();
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  cards.resolveQuestion("q2", { cancelled: true });
  assert.equal(card.classList.contains("cancelled"), false);
  card.querySelector("summary").click();
  cards.resolveQuestion("q1", { cancelled: true, reason: "turn ended" });
  assert.equal(card.classList.contains("cancelled"), true);
  assert.equal(card.open, true);
});

test("an approval: its details, Deny, and a denied answer marks it", () => {
  const { cards } = setup();
  const pq = { id: "a1", kind: "approval", question: "Run it?", options: ["Allow", "Deny"], allow_freeform: true,
    approval: { tool: "execute", command: "rm -rf build", reason: "cleanup" } };
  cards.renderQuestion(pq);
  const card = cards.questionCard();
  assert.equal(card.className, "bubble question approval");
  assert.equal(card.querySelector(".approval-tool").textContent, "execute");
  assert.equal(card.querySelector(".question-dismiss").textContent, "Deny");
  cards.resolveQuestion("a1", { answer: { selected: ["Deny"] } });
  assert.equal(card.classList.contains("denied"), true);
});

test("an edit approval: one ref per path, the path text as before", () => {
  const { cards } = setup();
  cards.renderQuestion({ id: "a2", kind: "approval", question: "Edit?", options: ["Allow", "Deny"],
    approval: { tool: "write", paths: ["/r/a.rb", "/r/b c.rb"], reason: "outside" } });
  const code = cards.questionCard().querySelector(".approval-what code");
  const refs = code.children.filter((c) => c.tagName === "SPAN");
  assert.deepEqual(refs.map((r) => [r.className, r.dataset.refKind, r.dataset.refPath, r.textContent]),
    [["ref", "file", "/r/a.rb", "/r/a.rb"], ["ref", "file", "/r/b c.rb", "/r/b c.rb"]]);
  assert.equal(code.children.map((c) => c.textContent).join(""), "/r/a.rb\n/r/b c.rb");
});

test("an approval's directory path (a plugin's, ending in /) stays plain text", () => {
  const { cards } = setup();
  cards.renderQuestion({ id: "a3", kind: "approval", question: "Save?", options: ["Allow", "Deny"],
    approval: { tool: "save_note", paths: ["/r/notes/", "/r/a.rb"], reason: "outside" } });
  const code = cards.questionCard().querySelector(".approval-what code");
  assert.deepEqual(code.children.map((c) => [c.tagName, c.textContent]), [["#TEXT", "/r/notes/"], ["#TEXT", "\n"], ["SPAN", "/r/a.rb"]]);
});

test("removeQuestion drops the live card", () => {
  const { cards, history } = setup();
  cards.renderQuestion(PQ);
  cards.removeQuestion();
  assert.equal(history.children.length, 0);
  assert.equal(cards.questionCard(), null);
  assert.equal(cards.pendingQuestion(), null);
});

test("a continue offer: one card with the task; Yes sends /continue to the session", () => {
  const { cards, history, calls } = setup();
  cards.renderContinue({ context: { original_prompt: "fix the build" } });
  cards.renderContinue({});
  assert.equal(history.children.length, 1);
  const card = history.children[0];
  assert.equal(card.querySelector(".continue-context").textContent, "fix the build");
  card.querySelector(".continue-yes").click();
  assert.equal(calls[0][0], "sendCommand");
  assert.equal(calls[0][1], "s1");
  assert.match(calls[0][2], /^\/continue/);
  assert.deepEqual(calls[0][3], { clientId: "web-me" });
  assert.ok(card.querySelectorAll("button, input").every((el) => el.disabled));
});

test("No, because… needs a reason", () => {
  const { cards, history, calls } = setup();
  cards.renderContinue({});
  const card = history.children[0];
  card.querySelector(".continue-no-reason").click();
  assert.equal(calls.length, 0);
  assert.equal(card.querySelector(".continue-reason").focused, true);
  card.querySelector(".continue-reason").value = "done already";
  card.querySelector(".continue-no-reason").click();
  assert.equal(calls.length, 1);
});

test("resolved: the decision, and who made it when it was another client", () => {
  const { cards, history } = setup();
  cards.renderContinue({});
  const card = history.children[0];
  cards.resolveContinue({ decision: "resume", client_id: "web-me" });
  assert.equal(card.classList.contains("resolved"), true);
  assert.equal(card.querySelector(".question-result").textContent, "Continued");
  cards.renderContinue({});
  const other = history.children[1];
  cards.resolveContinue({ decision: "abort", client_id: "tui-123" });
  assert.match(other.querySelector(".question-result").textContent, /^Not continued \(.+\)$/);
});

test("forgetContinue: a later offer draws a new card", () => {
  const { cards, history } = setup();
  cards.renderContinue({});
  cards.forgetContinue();
  cards.renderContinue({});
  assert.equal(history.children.length, 2);
});

const STEP_LIMIT = {
  id: "c1", kind: "continue", header: "Step limit", options: ["Continue", "Stop"], allow_freeform: true, limit: 3,
  question: "The turn ran out of iterations (3 steps) before it answered. Continue it?\nPrompt: fix the build",
};

test("a step-limit question: Continue and Stop buttons, a reason for Stop, no Dismiss", () => {
  const { cards, history, calls } = setup();
  cards.renderQuestion(STEP_LIMIT);
  const card = history.children[0];
  assert.ok(card.classList.contains("step-limit"));
  assert.equal(card.querySelector("summary").textContent, "Step limit");
  assert.equal(card.querySelector(".question-text").textContent, STEP_LIMIT.question);
  assert.deepEqual(card.querySelectorAll(".question-choice").map((b) => b.textContent), ["Continue", "Stop"]);
  assert.equal(card.querySelector(".continue-reason").placeholder, "Stop, because… (the model reads it)");
  assert.equal(card.querySelector(".question-dismiss"), null);
  assert.equal(card.querySelector(".question-submit"), null);
  assert.equal(card.querySelector(".question-option"), null);

  card.querySelector(".continue-yes").click();
  assert.deepEqual(calls[0], ["sendAnswer", "s1", { id: "c1", selected: ["Continue"] }]);
  assert.ok(card.querySelectorAll("button, input").every((el) => el.disabled));
});

test("Stop sends the reason with it; Continue with a reason in the box is refused here", () => {
  const { cards, history, calls } = setup();
  cards.renderQuestion(STEP_LIMIT);
  const card = history.children[0];
  card.querySelector(".continue-reason").value = "  enough  ";
  card.querySelector(".continue-yes").click();
  assert.equal(calls.length, 0);
  assert.equal(card.querySelector(".question-error").classList.contains("hidden"), false);
  card.querySelector(".continue-no").click();
  assert.deepEqual(calls[0], ["sendAnswer", "s1", { id: "c1", selected: ["Stop"], freeform: "enough" }]);
});

test("a step-limit question stands for the old continue card: it drops one drawn first, and none is drawn after", () => {
  const { cards, history } = setup();
  cards.renderContinue({ context: { original_prompt: "fix the build" } });
  assert.equal(history.querySelectorAll(".continue").length, 1);
  cards.renderQuestion(STEP_LIMIT);
  cards.renderContinue({ context: { original_prompt: "fix the build" } });
  assert.equal(history.querySelectorAll(".continue").length, 0);
  assert.equal(history.children.length, 1);
  // An older worker (no question): the old card as before.
  const old = setup();
  old.cards.renderContinue({});
  assert.equal(old.history.querySelectorAll(".continue").length, 1);
});

test("a step-limit question resolves to what was picked, or why it closed", () => {
  const { cards, history } = setup();
  cards.renderQuestion(STEP_LIMIT);
  cards.resolveQuestion("c1", { answer: { selected: ["Stop"], freeform: "enough" } });
  const card = history.children[0];
  assert.equal(card.querySelector(".question-result").textContent, "Stopped: enough");
  assert.ok(card.querySelector(".continue-no").classList.contains("selected"));
  assert.equal(card.querySelector("summary").textContent.endsWith("→ Stopped: enough"), true);
  cards.renderQuestion({ ...STEP_LIMIT, id: "c2" });
  cards.resolveQuestion("c2", { cancelled: true, reason: "dropped" });
  assert.equal(history.children[1].querySelector(".question-result").textContent, "Dropped: a new prompt came");
});

// N1: an allowed call's verdict reads before the command it allows (with the
// details expanded the command reads like another tool call otherwise).
test("a resolved approval card puts the verdict before the command", () => {
  const { cards, history } = setup();
  const pq = {
    id: "a9", kind: "approval", question: "Run it?", options: ["Allow once", "Deny"],
    approval: { tool: "execute", command: "rm -rf build", cwd: "/r", reason: "cleanup" },
  };
  cards.renderQuestion(pq);
  const card = history.children[0];
  cards.resolveQuestion("a9", { answer: { selected: ["Allow once"] } });
  const result = card.querySelector(".question-result");
  const details = card.querySelector(".approval-details");
  assert.ok(result.classList.contains("verdict"));
  assert.ok(card.children.indexOf(result) < card.children.indexOf(details));
  assert.equal(result.textContent, "Allowed: Allow once");
});

const RELAYED_TO = { parent_id: "pppp1111-0000", parent_short: "pppp1111", relay_id: "r1" };
const APPROVAL = {
  id: "a1", kind: "approval", question: "execute: git push", options: ["Allow once", "Deny"], allow_freeform: true,
  approval: { tool: "execute", command: "git push", cwd: "/r", reason: "pushes", scopes: ["once"] },
};

test("a delegate's own card says it waits in the parent too, live, and drops the line once closed or resolved", () => {
  const { cards } = setup();
  cards.renderQuestion(APPROVAL);
  const line = () => cards.questionCard().querySelector(".question-relayed");
  assert.equal(line().classList.contains("hidden"), true);

  cards.markRelayed("other", RELAYED_TO);
  assert.equal(line().classList.contains("hidden"), true);
  cards.markRelayed("a1", RELAYED_TO);
  assert.equal(line().classList.contains("hidden"), false);
  assert.deepEqual(line().children.map((c) => c.textContent), ["Waiting for approval in parent ", "pppp1111", ": answering here works too"]);
  assert.equal(line().querySelector("a").href, "#/s/pppp1111-0000");
  // Still answerable here.
  assert.equal(cards.questionCard().querySelector(".question-submit").disabled, false);

  cards.markRelayed("a1", null);
  assert.equal(line().classList.contains("hidden"), true);
  cards.markRelayed("a1", RELAYED_TO);
  cards.resolveQuestion("a1", { answer: { selected: ["Allow once"] } });
  assert.equal(line().classList.contains("hidden"), true);
});

test("a card drawn from a snapshot shows the relay line at once", () => {
  const { cards } = setup();
  cards.renderQuestion({ ...APPROVAL, relayed_to: RELAYED_TO });
  assert.equal(cards.questionCard().querySelector(".question-relayed").classList.contains("hidden"), false);
});

// 4.02: a reopened card (the snapshot re-renders the resolved question) had
// the result in both its summary and the .question-result body line.
test("a reopened answered card shows the result once: the body line hides", () => {
  const { cards } = setup();
  cards.renderQuestion({ ...APPROVAL, id: "a2" });
  const card = cards.questionCard();
  // What the snapshot replay has already done: the summary carries it.
  card.querySelector("summary").textContent = "execute: git push → Allowed: Allow once";
  cards.resolveQuestion("a2", { answer: { selected: ["Allow once"] } });
  const line = card.querySelector(".question-result");
  assert.equal(line.classList.contains("hidden"), true);
  assert.equal(line.textContent, "Allowed: Allow once");
});

test("a denied approval with a reason: the summary says Denied, the body line keeps the full reason shown", () => {
  const { cards } = setup();
  cards.renderQuestion({ ...APPROVAL, id: "a3" });
  const card = cards.questionCard();
  const reason = "checkout drops the CHANGELOG edits; ".repeat(5).trim();
  cards.resolveQuestion("a3", { answer: { selected: ["Deny"], freeform: reason } });
  assert.equal(card.querySelector("summary").textContent, "execute: git push → Denied");
  const line = card.querySelector(".question-result");
  assert.equal(line.textContent, `Denied: ${reason}`);
  assert.equal(line.classList.contains("hidden"), false);
  assert.equal(card.open, false);
});

test("a denied approval without a reason hides the body line like other results", () => {
  const { cards } = setup();
  cards.renderQuestion({ ...APPROVAL, id: "a4" });
  const card = cards.questionCard();
  cards.resolveQuestion("a4", { answer: { selected: ["Deny"] } });
  assert.equal(card.querySelector("summary").textContent, "execute: git push → Denied");
  assert.equal(card.querySelector(".question-result").classList.contains("hidden"), true);
});

test("a relayed approval on the parent links its delegate's session", () => {
  const { cards } = setup();
  cards.renderQuestion({ ...APPROVAL, relay: { id: "r1", child_id: "cccc2222-0000", chain: ["cccc2222"], task: "push it" } });
  const row = cards.questionCard().querySelector(".approval-delegate");
  const link = row.querySelector("a");
  assert.equal(link.href, "#/s/cccc2222-0000");
  assert.equal(link.textContent, "cccc2222");
  assert.equal(row.children[2].textContent, " · push it");
});

// A keydown on an element inside the card, bubbled to the card's listener.
function press(card, target, key = "Enter", mods = {}) {
  const e = { key, target, defaultPrevented: false, preventDefault() { this.defaultPrevented = true; }, ...mods };
  (card.listeners.keydown || []).forEach((fn) => fn(e));
  return e;
}

test("Enter in the response box submits it", () => {
  const { cards, calls } = setup();
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  const box = card.querySelector(".question-freeform");
  box.value = "the third";
  const e = press(card, box);
  assert.equal(e.defaultPrevented, true);
  assert.deepEqual(calls, [["sendAnswer", "s1", { id: "q1", selected: [], freeform: "the third" }]]);
});

test("Enter on an option submits the pick; with nothing picked it says so", () => {
  const { cards, calls } = setup();
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  const [a, b] = card.querySelectorAll(".question-option input");
  press(card, a);
  assert.equal(calls.length, 0);
  assert.equal(card.querySelector(".question-error").textContent, "Pick an option or enter a response.");
  b.checked = true;
  press(card, b);
  assert.deepEqual(calls, [["sendAnswer", "s1", { id: "q1", selected: ["b"] }]]);
});

test("Shift+Enter, a composing Enter or another key does not submit", () => {
  const { cards, calls } = setup();
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  const box = card.querySelector(".question-freeform");
  box.value = "x";
  for (const [key, mods] of [["Enter", { shiftKey: true }], ["Enter", { isComposing: true }], ["Enter", { metaKey: true }], ["a", {}]]) {
    assert.equal(press(card, box, key, mods).defaultPrevented, false);
  }
  assert.equal(calls.length, 0);
});

test("Enter never denies: on the Deny button it does nothing, on an approval's option it submits", () => {
  const { cards, calls } = setup();
  cards.renderQuestion(APPROVAL);
  const card = cards.questionCard();
  press(card, card.querySelector(".question-dismiss"));
  assert.equal(calls.length, 0);
  card.querySelectorAll(".question-option input")[0].checked = true;
  press(card, card.querySelectorAll(".question-option input")[0]);
  assert.deepEqual(calls.map((c) => c[0]), ["sendAnswer"]);
});

test("a new card takes the focus from an empty composer, its first option", async () => {
  const prompt = { value: "" };
  const { cards } = setup({ page: { prompt, activeElement: prompt } });
  cards.renderQuestion(PQ);
  await flush();
  const [a, b] = cards.questionCard().querySelectorAll(".question-option input");
  assert.equal(a.focused, true);
  assert.equal(b.focused, undefined);
});

test("with no options the response box takes the focus (the page had it)", async () => {
  const body = {};
  const { cards } = setup({ page: { body, activeElement: body, prompt: { value: "" } } });
  cards.renderQuestion({ id: "q2", question: "Why?", allow_freeform: true });
  await flush();
  assert.equal(cards.questionCard().querySelector(".question-freeform").focused, true);
});

test("a composer with text, or focus elsewhere, keeps the focus", async () => {
  const prompt = { value: "half a sentence" };
  const typing = setup({ page: { prompt, activeElement: prompt } });
  typing.cards.renderQuestion(PQ);
  const elsewhere = setup({ page: { prompt: { value: "" }, activeElement: { value: "" } } });
  elsewhere.cards.renderQuestion(PQ);
  await flush();
  for (const { cards } of [typing, elsewhere]) {
    assert.ok(cards.questionCard().querySelectorAll("input").every((i) => !i.focused));
  }
});

test("a card drawn already answered (the history replay) does not take the focus", async () => {
  const prompt = { value: "" };
  const { cards } = setup({ page: { prompt, activeElement: prompt } });
  cards.renderQuestion(PQ);
  cards.resolveQuestion("q1", { answer: { selected: ["a"] } });
  await flush();
  assert.ok(cards.questionCard().querySelectorAll("input").every((i) => !i.focused));
});

// The reply that asked (P2): kept by the answered card, a muted line under
// its summary (CSS clamps it to two lines; whole when the card is open).
const SAID = "I found two config files.\nThey disagree on the port.";
const said = (card) => card.querySelector("summary").querySelector(".question-said");

test("an answered question keeps the reply that asked it under its summary; a pending one shows none yet", () => {
  const { cards } = setup({ asking: `  ${SAID}\n` });
  cards.renderQuestion(PQ);
  const card = cards.questionCard();
  assert.equal(said(card), null);
  cards.resolveQuestion("q1", { answer: { selected: ["a"] } });
  assert.equal(said(card).textContent, SAID);
  assert.equal(card.querySelector("summary").textContent, "Which one? → a");
  // The summary's copy is the closed card's clamp (hidden from screen
  // readers: not the toggle's label); the whole text, selectable, is in the
  // body, which shows when the card is open.
  assert.equal(said(card).getAttribute("aria-hidden"), "true");
  const full = card.children.find((el) => el.classes.has("question-said-full"));
  assert.equal(full.textContent, SAID);
  assert.equal(card.children.indexOf(full), 1);
});

test("a dismissed question and an own approval keep it too", () => {
  const dismissed = setup({ asking: SAID });
  dismissed.cards.renderQuestion(PQ);
  dismissed.cards.resolveQuestion("q1", { cancelled: true });
  assert.equal(said(dismissed.cards.questionCard()).textContent, SAID);
  const own = setup({ asking: SAID });
  own.cards.renderQuestion(APPROVAL);
  own.cards.resolveQuestion("a1", { answer: { selected: ["Allow once"] } });
  assert.equal(said(own.cards.questionCard()).textContent, SAID);
});

test("no kept text for a relayed approval, a hook's question, the step limit, or an empty reply", () => {
  const cases = [
    [{ ...APPROVAL, relay: { id: "r1", child_id: "cccc2222-0000", chain: ["cccc2222"] } }, SAID, { selected: ["Allow once"] }],
    [{ ...PQ, kind: "hook" }, SAID, { selected: ["a"] }],
    [{ id: "c1", kind: "continue", question: "Continue?", options: ["Continue", "Stop"] }, SAID, { selected: ["Continue"] }],
    [PQ, "  \n", { selected: ["a"] }],
  ];
  for (const [pq, asking, answer] of cases) {
    const { cards } = setup({ asking });
    cards.renderQuestion(pq);
    cards.resolveQuestion(pq.id, { answer });
    assert.equal(said(cards.questionCard()), null, pq.kind || "empty");
  }
});

test("a reloaded card takes the text it is given (its step's), not the running turn's", () => {
  const { cards } = setup({ asking: "the running turn's text" });
  cards.renderQuestion(PQ, { said: SAID });
  cards.resolveQuestion("q1", { answer: { selected: ["a"] } });
  assert.equal(said(cards.questionCard()).textContent, SAID);
  const none = setup({ asking: "the running turn's text" });
  none.cards.renderQuestion(PQ, { said: "" });
  none.cards.resolveQuestion("q1", { answer: { selected: ["a"] } });
  assert.equal(said(none.cards.questionCard()), null);
});
