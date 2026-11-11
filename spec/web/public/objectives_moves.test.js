import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { chipConcerns, createObjectivesMoves, moveOfRow, movesInBlock } from "../../../lib/samagotchi/web/public/objectives_moves.js";

globalThis.MutationObserver ??= window.MutationObserver;

const row = (over = {}) => ({ tool: "objectives", title: "O2 Filters carry size · merged f00ee32", output: "[objectives]\nRecorded a move on O2. The list is unchanged.", ...over });

test("a row is a move only when the call recorded one", () => {
  assert.deepEqual(moveOfRow(row()), { id: "O2", note: "Filters carry size · merged f00ee32" });
  assert.equal(moveOfRow(row({ output: "[objectives]\nError: no objective O2" })), null);
  assert.equal(moveOfRow(row({ output: "" })), null);
  assert.equal(moveOfRow(row({ tool: "read" })), null);
});

test("a row's state rides in its params; its title, which an older page reads, stays as it was", () => {
  const done = row({ params: 'id="O2" state="done" note="Filters carry size"' });
  assert.deepEqual(moveOfRow(done), { id: "O2", note: "Filters carry size · merged f00ee32", state: "done" });
  assert.deepEqual(moveOfRow(row({ params: 'id="O2" note="n"' })), { id: "O2", note: "Filters carry size · merged f00ee32" });
});

test("a move line says claims done or blocked beside the id, as words with a class", () => {
  const historyEl = document.createElement("div");
  document.body.appendChild(historyEl);
  historyEl.innerHTML = '<div class="turn-work"><span data-move-id="O1" data-move-note="a" data-move-state="done"></span>'
    + '<span data-move-id="O2" data-move-note="b" data-move-state="blocked"></span><span data-move-id="O3" data-move-note="c"></span></div>';
  createObjectivesMoves({ historyEl });
  const lines = [...historyEl.querySelectorAll(".obj-move-line")];
  assert.deepEqual(lines.map((l) => l.querySelector(".obj-state")?.textContent ?? null), ["claims done", "blocked", null]);
  assert.ok(lines[0].querySelector(".obj-state").classList.contains("done"));
  assert.deepEqual(movesInBlock(historyEl.querySelector(".turn-work")).map((m) => m.state ?? null), ["done", "blocked", null]);
});

test("a flagged backing shows on the newest line naming that objective only, and goes when it's clean", () => {
  const historyEl = document.createElement("div");
  document.body.appendChild(historyEl);
  historyEl.innerHTML = '<div class="turn-work"><span data-move-id="O1" data-move-note="old"></span></div>'
    + '<div class="turn-work"><span data-move-id="O1" data-move-note="mid"></span><span data-move-id="O1" data-move-note="new" data-move-state="done"></span><span data-move-id="O2" data-move-note="b"></span></div>';
  let backing = { unbacked: true, command: "ok", edited_after_command: true };
  const control = createObjectivesMoves({ historyEl, latestMove: (id) => (id === "O1" ? { backing } : null) });
  const marks = () => [...historyEl.querySelectorAll(".obj-moves")].map((l) => [...l.querySelectorAll(".obj-unbacked")].map((m) => m.textContent));
  assert.deepEqual(marks(), [[], ["not backed: edited after the last command ran"]]);
  // On the last move of O1 only, not its earlier one in the same block.
  const second = [...historyEl.querySelectorAll(".obj-moves")][1].querySelectorAll(".obj-move-line");
  assert.deepEqual([...second].map((l) => !!l.querySelector(".obj-unbacked")), [false, true, false]);
  backing = { unbacked: false, command: "ok" };
  control.decorate();
  assert.deepEqual(marks(), [[], []]);
});

test("a block's moves are its marked rows, in order", () => {
  const block = document.createElement("div");
  block.innerHTML = '<span data-move-id="O1" data-move-note="a"></span><span class="x"></span><span data-move-id="O2" data-move-note="b"></span>';
  assert.deepEqual(movesInBlock(block), [{ id: "O1", note: "a" }, { id: "O2", note: "b" }]);
});

test("a decision card's Concerns gets a chip, once", () => {
  const body = document.createElement("div");
  body.innerHTML = "<p>The summary.</p><p><strong>Which?</strong></p><p>Concerns O2 Stops before checkout</p>";
  chipConcerns(body);
  chipConcerns(body);
  const chips = body.querySelectorAll(".obj-pill");
  assert.equal(chips.length, 1);
  assert.equal(chips[0].textContent, "O2");
  assert.equal(chips[0].parentElement.textContent, "O2 Stops before checkout");
});

function history(answerText, { canShorten = true, shorten = () => {} } = {}) {
  const historyEl = document.createElement("div");
  document.body.appendChild(historyEl);
  historyEl.innerHTML = '<div class="bubble output"></div><div class="revise-row"></div><div class="turn-timing"></div>';
  historyEl.querySelector(".bubble.output").textContent = answerText;
  return { historyEl, control: createObjectivesMoves({ historyEl, canShorten: () => canShorten, shorten }) };
}

test("the newest long answer offers its short version after its own rows, where it can", () => {
  let asked = 0;
  const { historyEl } = history("x".repeat(3000), { shorten: () => { asked += 1; } });
  const row = historyEl.querySelector(".obj-short");
  assert.equal(row.previousElementSibling.className, "turn-timing");
  row.querySelector("button").click();
  assert.equal(asked, 1);
  assert.equal(row.querySelector("button").disabled, true);
  assert.ok(history("short answer").historyEl.querySelector(".obj-short") === null);
  assert.ok(history("x".repeat(3000), { canShorten: false }).historyEl.querySelector(".obj-short") === null);
});

test("a failed Short version can be tapped again", async () => {
  const { historyEl } = history("x".repeat(3000), { shorten: async () => false });
  const button = historyEl.querySelector(".obj-short button");
  button.click();
  assert.equal(button.disabled, true);
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(button.disabled, false);
});

test("a failed Not yet on a move can be tapped again; a sent one stays off", async () => {
  const historyEl = document.createElement("div");
  document.body.appendChild(historyEl);
  historyEl.innerHTML = '<div class="turn-work"><span data-move-id="O1" data-move-note="a"></span></div>';
  let answer = false;
  createObjectivesMoves({ historyEl, notYet: async () => answer });
  const button = historyEl.querySelector(".obj-notyet");
  button.click();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(button.disabled, false);
  answer = true;
  button.click();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(button.disabled, true);
});

// A finished block as turn_block.js stamps it: its end, its rows' tools, a participant's.
// A tool is "name" (it went through) or "name:error" (its status mark).
const block = ({ end = "completed", tools = ["edit"], move = null, participant = false } = {}) => `<div class="turn-work" data-end="${end}"${participant ? ' data-participant="1"' : ""}>`
  + tools.map((t) => `<div class="activity-row" data-tool="${t.split(":")[0]}"><span class="activity-status ${t.split(":")[1] || "ok"}"></span></div>`).join("")
  + (move ? `<div class="activity-row" data-tool="objectives"><span data-move-id="${move}" data-move-note="n"></span></div>` : "") + "</div>";

const LIST = '<div class="bubble note objectives-entry"></div>';

// +html+ after the list's note unless +list+ is false.
function noMove(html, { can = true, list = true } = {}) {
  const historyEl = document.createElement("div");
  document.body.appendChild(historyEl);
  historyEl.innerHTML = (list ? LIST : "") + html;
  let allowed = can;
  const control = createObjectivesMoves({ historyEl, canMarkNoMove: () => allowed });
  const lines = () => [...historyEl.querySelectorAll(".obj-nomove")];
  return { historyEl, control, lines, allow: (v) => { allowed = v; } };
}

test("the newest finished turn that did work and recorded no move says so, after its block", () => {
  const { historyEl, lines } = noMove(block() + '<div class="bubble output">a</div>' + block({ tools: ["read", "execute"] }));
  assert.equal(lines().length, 1);
  assert.equal(lines()[0].textContent, "no move recorded");
  assert.equal(lines()[0].previousElementSibling, historyEl.querySelectorAll(".turn-work")[1]);
});

test("no mark for a turn that ran before the list's first note: the model had nothing to move on", () => {
  assert.equal(noMove(block(), { list: false }).lines().length, 0);
  assert.equal(noMove(block() + LIST, { list: false }).lines().length, 0);
  assert.equal(noMove(block() + LIST + block()).lines().length, 1);
});

test("no mark once a newer turn follows the block: a plain one's prompt, a wake turn's note; a steered line is the same turn's", () => {
  for (const later of ['<div class="bubble user">next</div><div class="bubble output">a</div>', '<div class="bubble note turn-start">report</div>']) {
    assert.equal(noMove(block() + later).lines().length, 0, later);
  }
  assert.equal(noMove(block() + '<div class="bubble user steered">also</div><div class="bubble output">a</div>').lines().length, 1);
});

test("only work that went through counts, and an objectives call (a proposal too) is no work", () => {
  assert.equal(noMove(block({ tools: ["edit:error", "execute:blocked", "write:stopped"] })).lines().length, 0);
  assert.equal(noMove(block({ tools: ["objectives"] })).lines().length, 0);
  assert.equal(noMove(block({ tools: ["objectives", "execute:error", "execute"] })).lines().length, 1);
});

test("no mark without a work row, with a move, for a canceled, failed or participant's turn, or when it can't", () => {
  for (const html of [block({ tools: ["read"] }), block({ move: "O1" }), block({ end: "canceled" }), block({ end: "failed" }),
    block({ participant: true }), '<div class="turn-work"><div class="activity-row" data-tool="edit"></div></div>']) {
    assert.equal(noMove(html).lines().length, 0, html);
  }
  assert.equal(noMove(block(), { can: false }).lines().length, 0);
});

test("the mark goes when a move appears in that turn, when a newer turn comes, or when the list has no active item", () => {
  const { historyEl, control, lines, allow } = noMove(block());
  assert.equal(lines().length, 1);
  historyEl.querySelector(".turn-work").insertAdjacentHTML("beforeend", '<span data-move-id="O1" data-move-note="n"></span>');
  control.decorate();
  assert.equal(lines().length, 0);

  const second = noMove(block());
  second.historyEl.insertAdjacentHTML("beforeend", block({ tools: ["read"] }));
  second.control.decorate();
  assert.equal(second.lines().length, 0);

  const third = noMove(block());
  third.allow(false);
  third.control.decorate();
  assert.equal(third.lines().length, 0);
  third.allow(true);
  third.control.decorate();
  assert.equal(third.lines().length, 1);
});

test("the no-move line offers Where are we? only where the worker has the tracker; a tap posts once, a failure gives it back", async () => {
  const historyEl = document.createElement("div");
  document.body.appendChild(historyEl);
  historyEl.innerHTML = LIST + block();
  let can = false;
  let answer = false;
  let taps = 0;
  const control = createObjectivesMoves({ historyEl, canMarkNoMove: () => true, canTrack: () => can, track: async () => { taps += 1; return answer; } });
  const line = () => historyEl.querySelector(".obj-nomove");
  assert.equal(line().textContent, "no move recorded");
  assert.ok(line().querySelector("button") === null);

  can = true;
  control.decorate();
  const button = line().querySelector(".obj-track-ask");
  assert.equal(button.textContent, "Where are we?");
  assert.equal(historyEl.querySelectorAll(".obj-nomove").length, 1);
  button.click();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(button.disabled, false);
  answer = true;
  button.click();
  await new Promise((r) => setTimeout(r, 0));
  assert.equal(button.disabled, true);
  assert.equal(taps, 2);

  can = false;
  control.decorate();
  assert.ok(line().querySelector("button") === null);
});
