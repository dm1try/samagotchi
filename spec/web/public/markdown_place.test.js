import test from "node:test";
import assert from "node:assert/strict";
import { createMarkdownPlace } from "../../../lib/samagotchi/web/public/markdown_place.js";

function setup() {
  const output = { name: "answer" };
  const gen = { name: "closed step" };
  const root = { querySelectorAll: (selector) => selector === ".bubble.output" ? [output] : [output, gen] };
  const calls = [];
  const state = { capabilities: { display: true }, roots: [root], dir: "/project", touched: new Set(["a.rb"]) };
  const place = createMarkdownPlace({
    capabilities: () => state.capabilities,
    renderText: async (text) => ({ html: `<p>${text}</p>` }),
    roots: () => state.roots,
    touchedFiles: (roots) => { calls.push(["touched", roots]); return state.touched; },
    currentDir: () => state.dir,
    linkRefs: (...args) => calls.push(["link", ...args]),
    applyFinalAnswer: (...args) => calls.push(["apply", ...args]),
    findInTurnRoots: (selector) => {
      calls.push(["find", selector]);
      return state.roots.flatMap((r) => r.querySelectorAll(selector));
    },
    normalize: (text) => text.trim(),
    pairAnswerRefs: (el) => calls.push(["pair", el]),
    setAnswerRefs: (el, refs) => calls.push(["set", el, refs]),
  });
  return { calls, gen, output, place, root, state };
}

test("renderMarkdown renders only when display capability is enabled", async () => {
  const { place, state } = setup();
  assert.equal(await place.renderMarkdown("hello"), "<p>hello</p>");
  state.capabilities = {};
  assert.equal(await place.renderMarkdown("hidden"), null);
});

test("linkRefsIn links a rendered text against the live roots and session directory", () => {
  const { calls, place, root, state } = setup();
  const el = {};
  place.linkRefsIn(el);
  assert.deepEqual(calls, [
    ["touched", state.roots],
    ["link", el, state.touched, "/project"],
  ]);
  assert.equal(calls[0][1][0], root);
});

test("linkRefsIn with a plugin's refs sets and pairs them first, then links the path:line refs", () => {
  const { calls, place, state } = setup();
  const el = {};
  const refs = [{ match: "JIRA-1", kind: "issue" }];
  place.linkRefsIn(el, refs);
  assert.deepEqual(calls, [
    ["set", el, refs],
    ["pair", el],
    ["touched", state.roots],
    ["link", el, state.touched, "/project"],
  ]);
});

test("pairRefsIn pairs a plugin's refs only; without refs it does nothing", () => {
  const { calls, place } = setup();
  const el = {};
  place.pairRefsIn(el, null);
  place.pairRefsIn(el);
  assert.deepEqual(calls, []);
  const refs = [{ match: "JIRA-1", kind: "issue" }];
  place.pairRefsIn(el, refs);
  assert.deepEqual(calls, [["set", el, refs], ["pair", el]]);
});

test("applyFinalMarkdown applies answer rendering, then links the final refs", () => {
  const { calls, gen, output, place, state } = setup();
  const messages = [{ role: "assistant", content: "answer" }];
  place.applyFinalMarkdown(messages);
  assert.deepEqual(calls[0], ["find", ".bubble.output"]);
  assert.equal(calls[1][0], "apply");
  assert.deepEqual(calls[1][1], messages);
  assert.deepEqual(calls[1][2], [output]);
  assert.equal(calls[1][3](" text "), "text");
  assert.deepEqual(calls.slice(2), [
    ["touched", state.roots],
    ["pair", output],
    ["pair", gen],
    ["link", output, state.touched, "/project"],
    ["link", gen, state.touched, "/project"],
  ]);
});

test("linkTextRefs pairs answers and closed-step texts (a question's refs), then links both", () => {
  const { calls, gen, output, place, state } = setup();
  place.linkTextRefs();
  assert.deepEqual(calls, [
    ["touched", state.roots],
    ["pair", output],
    ["pair", gen],
    ["link", output, state.touched, "/project"],
    ["link", gen, state.touched, "/project"],
  ]);
});
