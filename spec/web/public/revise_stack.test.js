// Revise stacks (revise_stack.js): the chains, the stub's and the chips'
// words, and the page: superseded turns fold to stubs in place, the top
// answer's version chip, the Revise button's rule, the gap dividers, a jump.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { markupOf } from "./dom_shim.js";

for (const k of ["MutationObserver", "localStorage"]) {
  if (!(k in globalThis)) globalThis[k] = window[k];
}

const {
  HIDDEN_CLASS, REVISE_UNAVAILABLE, historyTurns, installReviseStacks, reviseChipTemplate, reviseChipText,
  reviseWorkerUnavailable, stacks, stubKey, stubText, versionChipText,
} = await import("../../../lib/samagotchi/web/public/revise_stack.js");
const { FOLD_PREFIX, readFolded, writeFold } = await import("../../../lib/samagotchi/web/public/answer_fold.js");
const { revealInHistory } = await import("../../../lib/samagotchi/web/public/history_reveal.js");

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
const lines = (n) => Array.from({ length: n }, (_, i) => `line ${i + 1}`).join("\n");

function clearFolds() {
  for (let i = localStorage.length - 1; i >= 0; i--) {
    const key = localStorage.key(i);
    if (key?.startsWith(FOLD_PREFIX)) localStorage.removeItem(key);
  }
}

test("stacks: chains in order, a revises of a missing or later target ignored, a revised draft re-targeted to the top", () => {
  const m = (turn_id, revises = null, extra = {}) => ({ role: "user", turn_id, ...(revises ? { revises: { turn_id: revises } } : {}), ...extra });
  assert.deepEqual(stacks([m("a"), m("b", "a"), m("c", "b"), m("d")]), [["a", "b", "c"]]);
  assert.deepEqual(stacks([m("a"), m("b", "gone")]), [], "a missing target is no stack");
  assert.deepEqual(stacks([m("a", "b"), m("b")]), [], "a later target is no stack");
  assert.deepEqual(stacks([m("a"), m("b", "a"), m("c", "a")]), [["a", "b", "c"]], "re-targeted to the top");
  assert.deepEqual(stacks([m("a"), m("x"), m("b", "a"), m("y", "x")]), [["a", "b"], ["x", "y"]]);
  assert.deepEqual(stacks([m("a"), m("b", "a", { merged: true })]), [], "a merged line opens nothing");
  assert.deepEqual(stacks([m("a"), m("a", "a")]), []);
  assert.deepEqual(stacks(null), []);
  assert.deepEqual(stacks([{ role: "assistant" }, m("a"), m("b", "a")]), [["a", "b"]]);
});

test("the words: a stub, the version chip, the composer's chip and its refusal", () => {
  assert.equal(stubText({ version: 1, label: "PROJ-123: Retry", lines: 84, top: 3 }),
    "v1 · “PROJ-123: Retry” · 84 lines — superseded by v3");
  assert.equal(stubText({ version: 2, label: "", lines: 1, top: 3 }), "v2 · 1 line — superseded by v3");
  assert.equal(versionChipText(3), "v3 · 2 earlier");
  assert.equal(reviseChipText("The ticket"), "Revising: The ticket");
  assert.equal(reviseChipText("x", { unavailable: true }), `Revise: ${REVISE_UNAVAILABLE}`);
  assert.equal(markupOf(reviseChipTemplate(null)), "");
  const chip = markupOf(reviseChipTemplate({ turn_id: "t1", label: "The ticket" }));
  assert.match(chip, /class="revise-chip"/);
  assert.match(chip, /Revising: The ticket/);
  assert.match(chip, /revise-chip-clear/);
  assert.match(markupOf(reviseChipTemplate({ turn_id: "t1", label: "x" }, { unavailable: true })), /revise-chip refused/);
});

test("reviseWorkerUnavailable: a live worker without the feature only", () => {
  assert.equal(reviseWorkerUnavailable(["verify"], true), true);
  assert.equal(reviseWorkerUnavailable(["verify", "revise"], true), false);
  assert.equal(reviseWorkerUnavailable([], false), false, "a sleeping worker wakes as a new one");
  assert.equal(reviseWorkerUnavailable(null, true), false);
});

// A history of turns: each [id, answer text, {revises, verify, wake}].
function page(turns, deps = {}) {
  const history = document.createElement("div");
  history.id = "history";
  document.body.append(history);
  for (const [id, text, opts = {}] of turns) {
    if (opts.gap) {
      const gap = document.createElement("div");
      gap.className = "time-gap";
      gap.textContent = `── ${opts.gap} ──`;
      history.append(gap);
    }
    let opening;
    if (opts.wake) {
      opening = document.createElement("div");
      opening.className = "bubble note";
    } else {
      opening = document.createElement("div");
      opening.className = "bubble user";
      opening.dataset.turnId = id;
      opening.dataset.copySource = opts.prompt ?? `prompt ${id}`;
      opening.title = `time of ${id}`;
      if (opts.revises) opening.dataset.revises = opts.revises;
      if (opts.verify) opening.dataset.verify = "1";
    }
    // A delegate report's fold row heads its opening (answer_fold.js).
    if (opts.head) {
      const head = document.createElement("button");
      head.className = "answer-fold report folded";
      history.append(head);
    }
    const work = document.createElement("details");
    work.className = "turn-work done";
    const answer = document.createElement("div");
    answer.className = `bubble output${opts.cls || ""}`;
    answer.dataset.answerTurn = id;
    answer.dataset.copySource = text;
    answer.textContent = text;
    const timing = document.createElement("div");
    timing.className = "turn-timing";
    history.append(opening, work, answer, timing);
    if (opts.card) {
      const card = document.createElement("div");
      card.className = opts.card;
      history.append(card);
    }
  }
  const control = installReviseStacks({ historyEl: history, sessionId: () => "s1", ...deps });
  return { history, control };
}

const visible = (el) => !el.classList.contains(HIDDEN_CLASS);
const prompt = (history, id) => history.querySelector(`[data-turn-id="${id}"]`);
const answer = (history, id) => history.querySelector(`.bubble.output[data-answer-turn="${id}"]`);

test("historyTurns: a turn's elements up to the next opening or note; a wake turn keyed by its answer", () => {
  const { history } = page([["t1", "a"], ["w1", "b", { wake: true }], ["t2", "c"]]);
  const turns = historyTurns(history);
  assert.deepEqual(turns.map((t) => [t.id, t.wake, t.els.length]), [["t1", false, 3], ["w1", true, 3], ["t2", false, 3]]);
  history.remove();
});

test("the page: a superseded turn a report opened folds with its report's fold row, the stub above the row", () => {
  const { history } = page([["v1", "first"], ["v2", "second", { revises: "v1", head: true }], ["v3", "third", { revises: "v2" }]]);
  const turns = historyTurns(history);
  assert.deepEqual(turns.map((t) => [t.id, t.els.length]), [["v1", 3], ["v2", 3], ["v3", 3]], "the row is no element of the turn before");
  const row = history.querySelector(".answer-fold");
  const stub = history.querySelector('.stack-stub[data-stack-stub="v2"]');
  assert.ok(stub.nextElementSibling === row && row.nextElementSibling === prompt(history, "v2"));
  assert.ok(!visible(row));
  history.remove();
});

test("the page: superseded turns fold to one stub each, in place; the top answer gets the version chip", async () => {
  clearFolds();
  const { history } = page([
    ["v1", `# PROJ-123: Retry on webhook\n${lines(40)}`, { card: "verify-verdict" }],
    ["v2", "## Shorter\nbody", { revises: "v1", prompt: "cut it shorter" }],
    ["v3", "Shortest", { revises: "v2", prompt: "still too long" }],
    ["x", "unrelated"],
  ]);
  const stubs = [...history.querySelectorAll(".stack-stub")];
  assert.equal(stubs.length, 2);
  assert.ok(stubs[0].nextElementSibling === prompt(history, "v1"), "the stub stands where its turn starts");
  assert.equal(stubs[0].querySelector(".stack-stub-text").textContent,
    "v1 · “PROJ-123: Retry on webhook” · 41 lines — superseded by v3");
  assert.equal(stubs[1].querySelector(".stack-stub-text").textContent, "v2 · “Shorter” · 2 lines — superseded by v3");
  assert.equal(stubs[0].getAttribute("aria-expanded"), "false");
  for (const id of ["v1", "v2"]) {
    assert.ok(!visible(prompt(history, id)));
    assert.ok(!visible(answer(history, id)));
  }
  assert.ok(visible(history.querySelector(".verify-verdict")), "a verdict card stays on view");
  assert.ok(visible(answer(history, "v3")));
  // The top's row: its chip lists the versions by their prompts.
  const top = answer(history, "v3").nextElementSibling;
  assert.ok(top.matches(".revise-row.stacked"));
  assert.equal(top.querySelector("summary").textContent, "v3 · 2 earlier");
  const picks = [...top.querySelectorAll("[data-stack-pick]")];
  assert.deepEqual(picks.map((b) => b.textContent.trim()), ["v1 prompt v1", "v2 cut it shorter", "v3 still too long"]);
  assert.ok(picks[2].disabled, "the version on view isn't picked");
  // Superseded answers have no Revise; the top and an unstacked one do.
  assert.deepEqual([...history.querySelectorAll("[data-revise]")].map((b) => b.dataset.revise), ["v3", "x"]);
  history.remove();
});

test("the page: a stub click unfolds its turn in place (saved per viewer), again folds; a reload keeps it", async () => {
  clearFolds();
  const turns = [["v1", "first"], ["v2", "second", { revises: "v1" }]];
  const first = page(turns);
  const stub = first.history.querySelector(".stack-stub");
  stub.click();
  assert.ok(stub.classList.contains("open"));
  assert.equal(stub.getAttribute("aria-expanded"), "true");
  assert.ok(visible(answer(first.history, "v1")));
  assert.deepEqual(readFolded("s1"), [stubKey("v1")]);
  first.history.remove();
  const again = page(turns);
  assert.ok(visible(answer(again.history, "v1")), "the stored choice");
  again.history.querySelector(".stack-stub").click();
  assert.ok(!visible(answer(again.history, "v1")));
  assert.deepEqual(readFolded("s1"), []);
  again.history.remove();
  clearFolds();
});

test("the page: a version picked in the chip reveals its stub (not saved)", async () => {
  clearFolds();
  const { history } = page([["v1", "first"], ["v2", "second", { revises: "v1" }]]);
  history.querySelector('[data-stack-pick="v1"]').click();
  assert.ok(history.querySelector(".stack-stub").classList.contains("open"));
  assert.ok(visible(answer(history, "v1")));
  assert.deepEqual(readFolded("s1"), []);
  history.remove();
});

test("the page: a live stamp folds the earlier version; a gap between two folded stubs folds into the later", async () => {
  clearFolds();
  const { history } = page([["v1", "first"], ["v2", "second", { gap: "14:32 · 47 min later" }], ["v3", "third", { gap: "15:40 · 1 h later" }]]);
  assert.equal(history.querySelectorAll(".stack-stub").length, 0);
  prompt(history, "v2").dataset.revises = "v1";
  await tick();
  assert.equal(history.querySelectorAll(".stack-stub").length, 1);
  assert.ok(!visible(answer(history, "v1")));
  // v1 alone folded: v2's divider stays (v2 isn't a stub).
  assert.equal(history.querySelectorAll(".time-gap.stack-gap").length, 0);
  prompt(history, "v3").dataset.revises = "v2";
  await tick();
  const stubs = history.querySelectorAll(".stack-stub");
  assert.equal(stubs.length, 2);
  const gaps = [...history.querySelectorAll(".time-gap")];
  assert.ok(gaps[0].classList.contains("stack-gap"), "between v1's and v2's stubs");
  assert.ok(!gaps[1].classList.contains("stack-gap"), "before the top it stays");
  assert.equal(stubs[1].querySelector(".stack-stub-gap").textContent, "14:32 · 47 min later");
  // Unfolded, the divider is back.
  stubs[1].click();
  assert.ok(!gaps[0].classList.contains("stack-gap"));
  history.remove();
  clearFolds();
});

test("the page: no Revise on a Verify turn's answer, the running turn's, a streaming one, a wake turn's; the gate disables it", async () => {
  let run = null;
  let off = false;
  const verdictCheck = new Set(["vc"]);
  const { history, control } = page([
    ["a", "plain"], ["v", "checked", { verify: true }], ["vc", "checked by verdict"], ["w", "woke", { wake: true }],
    ["s", "streaming", { cls: " streaming" }], ["r", "running"],
  ], { running: () => run, unavailable: () => off, verifyTurn: (id) => verdictCheck.has(id) });
  const ids = () => [...history.querySelectorAll("[data-revise]")].map((b) => b.dataset.revise);
  assert.deepEqual(ids(), ["a", "r"]);
  // A canceled turn's partial answer (its stop line after it): no Revise.
  const stop = document.createElement("div");
  stop.className = "bubble cancel stopped";
  answer(history, "r").nextElementSibling.after(stop);
  control.decorate();
  assert.deepEqual(ids(), ["a"]);
  stop.remove();
  control.decorate();
  run = { turnId: "r" };
  control.decorate();
  assert.deepEqual(ids(), ["a"]);
  run = null;
  off = true;
  control.decorate();
  const button = history.querySelector('[data-revise="a"]');
  assert.ok(button.disabled);
  assert.equal(button.title, REVISE_UNAVAILABLE);
  history.remove();
});

test("the page: Revise arms with the answer's turn and first line; the armed one reads Revising…", async () => {
  let armed = null;
  const got = [];
  const { history, control } = page([["a", "# The ticket\nbody"]], {
    armed: () => armed,
    onRevise: (anchor) => { got.push(anchor); armed = anchor.turn_id; },
  });
  history.querySelector('[data-revise="a"]').click();
  assert.deepEqual(got, [{ turn_id: "a", label: "The ticket" }]);
  control.decorate();
  const button = history.querySelector('[data-revise="a"]');
  assert.ok(button.classList.contains("armed"));
  assert.equal(button.textContent, "Revising…");
  history.remove();
});

test("revealInHistory: a jump into a superseded turn opens its stub, not saved", async () => {
  clearFolds();
  writeFold("s1", "unrelated", true);
  const { history } = page([["v1", "first"], ["v2", "second", { revises: "v1" }]]);
  const claim = document.createElement("p");
  answer(history, "v1").append(claim);
  revealInHistory(claim);
  await tick();
  assert.ok(visible(answer(history, "v1")));
  assert.ok(visible(prompt(history, "v1")));
  assert.ok(history.querySelector(".stack-stub").classList.contains("open"));
  assert.deepEqual(readFolded("s1"), ["unrelated"]);
  history.remove();
  clearFolds();
});

test("the page: a re-render drops the old stubs and rows and draws the new history's", async () => {
  clearFolds();
  const { history } = page([["v1", "first"], ["v2", "second", { revises: "v1" }]]);
  const kept = [...history.children].filter((el) => !el.matches(".stack-stub, .revise-row")).map((el) => el.cloneNode(true));
  history.replaceChildren(...kept);
  await tick();
  assert.equal(history.querySelectorAll(".stack-stub").length, 1);
  assert.equal(history.querySelectorAll(".revise-row").length, 1);
  history.remove();
});

test("the switcher's words and steps: N/M, its spoken label, kept within the stack", async () => {
  const { stepVersion, switchText, switcherTemplate } = await import("../../../lib/samagotchi/web/public/revise_switch.js");
  assert.deepEqual(switchText(1, 3), { text: "2/3", label: "version 2 of 3" });
  assert.equal(stepVersion(2, 3, -1), 1);
  assert.equal(stepVersion(0, 3, -1), 0);
  assert.equal(stepVersion(2, 3, 1), 2);
  const markup = markupOf(switcherTemplate("v3", 0, 3));
  assert.match(markup, /aria-label="Previous version"[^>]*aria-disabled="true"/);
  assert.match(markup, /aria-label="Next version"[^>]*aria-disabled="false"/);
  assert.match(markup, /version 1 of 3/);
});

test("the page: the switcher shows an earlier version's answer in the top's place, view only; Copy copies it", async () => {
  clearFolds();
  const { history, control } = page([
    ["v1", "first answer"], ["v2", "second answer", { revises: "v1" }], ["v3", "third answer", { revises: "v2" }],
  ]);
  const row = () => answer(history, "v3").nextElementSibling;
  const counter = () => row().querySelector(".stack-switch-n [aria-hidden]").textContent;
  const prev = () => row().querySelector('[data-stack-step="-1"]');
  const next = () => row().querySelector('[data-stack-step="1"]');
  assert.equal(counter(), "3/3", "the latest by default");
  assert.equal(next().getAttribute("aria-disabled"), "true");
  assert.equal(history.querySelectorAll(".stack-view").length, 0);
  prev().click();
  assert.equal(counter(), "2/3");
  const view = history.querySelector(".stack-view");
  assert.ok(view, "a copy of v2's answer");
  assert.equal(view.textContent, "second answer");
  assert.equal(view.dataset.copySource, "second answer", "Copy copies the version on view");
  assert.ok(!view.hasAttribute("data-answer-turn"), "no answer key: no fold row, no Revise row of its own");
  assert.ok(view.nextElementSibling === answer(history, "v3"), "in the top's place");
  assert.ok(answer(history, "v3").classList.contains("stack-swapped"), "the top hides");
  assert.ok(!visible(answer(history, "v2")), "the superseded turn stays folded");
  assert.equal(historyTurns(history).find((t) => t.id === "v3").answer, answer(history, "v3"), "the top stays the turn's answer");
  prev().click();
  assert.equal(counter(), "1/3");
  assert.equal(history.querySelector(".stack-view").textContent, "first answer");
  assert.equal(history.querySelectorAll(".stack-view").length, 1);
  assert.equal(prev().getAttribute("aria-disabled"), "true");
  prev().click();
  assert.equal(counter(), "1/3", "no step past v1");
  control.decorate();
  assert.equal(history.querySelector(".stack-view").textContent, "first answer", "a redraw keeps the version on view");
  next().click();
  next().click();
  assert.equal(counter(), "3/3");
  assert.equal(history.querySelectorAll(".stack-view").length, 0);
  assert.ok(!answer(history, "v3").classList.contains("stack-swapped"));
  assert.deepEqual(readFolded("s1"), [], "nothing stored");
  history.remove();
});

test("the page: a switched stack hides the top's fold row too; a new Revise on top shows the latest", async () => {
  clearFolds();
  const { history } = page([["v1", "first"], ["v2", "second", { revises: "v1" }], ["v3", "third"]]);
  const fold = document.createElement("button");
  fold.className = "answer-fold";
  answer(history, "v2").before(fold);
  answer(history, "v2").nextElementSibling.querySelector('[data-stack-step="-1"]').click();
  assert.ok(fold.classList.contains("stack-swapped"));
  assert.ok(history.querySelector(".stack-view").nextElementSibling === fold, "before the top's fold row");
  prompt(history, "v3").dataset.revises = "v2";
  await tick();
  assert.equal(history.querySelectorAll(".stack-view").length, 0, "v3 is the top now, on view");
  assert.ok(!fold.classList.contains("stack-swapped"));
  assert.equal(answer(history, "v3").nextElementSibling.querySelector(".stack-switch-n [aria-hidden]").textContent, "3/3");
  history.remove();
});
