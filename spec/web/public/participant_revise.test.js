// A participant's Revise (participant_revise.js): the page's mirror of
// ParticipantRevise on historyTurns' list, the worker gate, and the
// viewer-bound mayRevise.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const {
  PARTICIPANT_REVISE_FEATURE, PARTICIPANT_REVISE_UNAVAILABLE, mayReviseOwn, participantMayRevise, participantReviseUnavailable,
  revisableOwn,
} = await import("../../../lib/samagotchi/web/public/participant_revise.js");
const { setViewerSelf } = await import("../../../lib/samagotchi/web/public/viewer_self.js");

const ME = "p:p_me";

// historyTurns' shape: [author or null, {wake, verify, own, answer}].
function turns(specs) {
  return specs.map(([author, opts = {}], i) => {
    let prompt = null;
    if (!opts.wake) {
      prompt = document.createElement("div");
      prompt.className = "bubble user";
      prompt.dataset.turnId = `t${i}`;
      if (author) prompt.dataset.author = author;
      if (opts.own) prompt.dataset.own = "1";
      if (opts.verify) prompt.dataset.verify = "1";
    }
    return { id: `t${i}`, prompt, wake: !!opts.wake, answer: opts.answer === false ? null : document.createElement("div") };
  });
}

// The shared table (spec/shared/participant_revise_cases.json), also the
// server rule's (spec/participant_revise_spec.rb). Ids t<i> as there; a
// shell turn (the owner's `!` line) never reaches their page.
const CASES = JSON.parse(readFileSync(new URL("../../shared/participant_revise_cases.json", import.meta.url), "utf8")).cases;
const AUTHORS = { me: ME, other: "p:p_other", owner: null };

function caseTurns(specs) {
  return specs.flatMap((spec, i) => {
    if (spec.by === "shell") return [];
    let prompt = null;
    if (spec.by !== "wake") {
      prompt = document.createElement("div");
      prompt.className = "bubble user";
      prompt.dataset.turnId = `t${i}`;
      if (AUTHORS[spec.by]) prompt.dataset.author = AUTHORS[spec.by];
      if (spec.verify) prompt.dataset.verify = "1";
    }
    const answered = spec.answered !== false;
    return [{ id: `t${i}`, prompt, wake: spec.by === "wake", answer: answered ? document.createElement("div") : null }];
  });
}

for (const c of CASES) {
  test(`mayReviseOwn (shared table): ${c.name}`, () => {
    const list = caseTurns(c.turns);
    const index = list.findIndex((t) => t.id === `t${c.target}`);
    assert.equal(mayReviseOwn(list, index, ME), c.expected);
  });
}

test("mayReviseOwn: no viewer, or an index past the list", () => {
  assert.equal(mayReviseOwn(turns([[ME]]), 0, null), false);
  assert.equal(mayReviseOwn(turns([[ME]]), 5, ME), false);
});

test("revisableOwn: one backward pass gives every revisable turn", () => {
  const list = turns([[ME], [null], [ME], [ME, { verify: true }], [ME]]);
  assert.deepEqual([...revisableOwn(list, ME)].map((t) => t.id), ["t4", "t2"]);
});

test("mayReviseOwn: this tab's own echo counts as theirs", () => {
  assert.equal(mayReviseOwn(turns([[null, { own: true }]]), 0, ME), true);
  assert.equal(mayReviseOwn(turns([[ME], [null, { own: true }]]), 0, ME), true);
});

test("participantReviseUnavailable: a live worker without participant_revise only", () => {
  assert.equal(PARTICIPANT_REVISE_FEATURE, "participant_revise");
  assert.equal(participantReviseUnavailable(["revise"], true), true);
  assert.equal(participantReviseUnavailable(["revise", "participant_revise"], true), false);
  assert.equal(participantReviseUnavailable(["revise"], false), false, "a sleeping worker wakes as a new one");
  assert.match(PARTICIPANT_REVISE_UNAVAILABLE, /too old for you to revise/);
});

test("participantMayRevise: the viewer's own answers, none while their composer is closed", () => {
  setViewerSelf({ kind: "participant", id: "p_me", name: "Me", client_id: "review:p_me" });
  let closed = false;
  const may = participantMayRevise(() => closed);
  const list = turns([[null], [ME]]);
  assert.equal(may(list[1], list), true);
  assert.equal(may(list[0], list), false);
  closed = true;
  assert.equal(may(list[1], list), false);
  setViewerSelf(null);
});
