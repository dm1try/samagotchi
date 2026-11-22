// A peer's answer bubble (peer_note.js): still a wake turn's opening for
// everything that reads one, its summary the note text, chi's words folded.
import { markupOf } from "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { peerNoteTemplate, peerSummaryText, verdictTemplate } from "../../../lib/samagotchi/web/public/peer_note.js";
import { elementOf, noteBubbleTemplate } from "../../../lib/samagotchi/web/public/turn_html.js";
import { TURN_PROMPT } from "../../../lib/samagotchi/web/public/bubbles.js";
import { OPENING } from "../../../lib/samagotchi/web/public/stage_handoff.js";
import { stampedOpening } from "../../../lib/samagotchi/web/public/card_stamps.js";

const TEXT = "Updated: claude-outbox (latest Claude reply). What changed …\n> phase A: VERDICT CHANGES, 2 issues\nchi started this turn because …";
const peer = (over = {}) => ({ peer: "claude", label: "Claude", re: "s-ab12cd", summary: "phase A: VERDICT CHANGES, 2 issues", serial: 4, verdict: "CHANGES", agreed: false, ...over });
const wakeNote = (over = {}) => ({ content: TEXT, label: "context claude-outbox", context_source: "claude-outbox", turn_start: true, turn_id: "t9", at: "2026-11-20T10:06:00Z", peer: peer(), ...over });

test("a peer note that opens a wake turn: TURN_PROMPT, OPENING and its data-opening-id, as any wake note", () => {
  const el = elementOf(noteBubbleTemplate(wakeNote()));
  assert.ok(el.matches(TURN_PROMPT));
  assert.ok(el.matches(OPENING));
  assert.ok(el.matches(".bubble.note.peer-answer"));
  assert.equal(el.dataset.openingId, "t9");
  assert.equal(stampedOpening([el], "t9"), 0);
  assert.ok(el.title);
  // The plain note's opening, for comparison: the same classes and stamp.
  const plain = elementOf(noteBubbleTemplate({ ...wakeNote(), peer: undefined }));
  assert.ok(plain.matches(TURN_PROMPT) && plain.dataset.openingId === "t9");
});

test("a peer note that opens no turn has no turn-start and no opening id", () => {
  const el = elementOf(noteBubbleTemplate(wakeNote({ turn_start: undefined })));
  assert.ok(!el.matches(TURN_PROMPT));
  assert.ok(!el.matches(OPENING));
});

test("its parts: '<label> answered', the verdict, .note-text the summary, chi's text folded, the slots, the keys", () => {
  const el = elementOf(peerNoteTemplate(wakeNote()));
  assert.equal(el.querySelector(".peer-who").textContent, "Claude answered");
  assert.equal(el.querySelector(".note-text").textContent, "phase A: VERDICT CHANGES, 2 issues");
  assert.equal(el.querySelector(".peer-verdict.changes").textContent, "VERDICT CHANGES");
  const told = el.querySelector("details.peer-told");
  assert.equal(told.open, false);
  assert.equal(told.querySelector("summary").textContent, "what chi told the agent");
  assert.equal(told.querySelector(".peer-told-text").textContent, TEXT);
  assert.ok(el.querySelector(".peer-up-slot[data-peer-slot]"));
  assert.ok(el.querySelector(".peer-full-slot[data-peer-slot]"));
  assert.deepEqual({ ...el.dataset }, { openingId: "t9", peerSource: "claude-outbox", peerName: "claude", peerRe: "s-ab12cd", peerSerial: "4" });
});

test("an older skill's answer (no re) and no verdict: no re key, no pill", () => {
  const el = elementOf(peerNoteTemplate(wakeNote({ peer: peer({ re: undefined, verdict: undefined, summary: "thoughts" }) })));
  assert.equal(el.dataset.peerRe, undefined);
  assert.ok(el.querySelector(".peer-verdict") === null);
});

test("verdictTemplate: OK with 'round closed' when agreed, CHANGES warn, UNSURE neutral, other words none", () => {
  assert.match(markupOf(verdictTemplate({ verdict: "OK", agreed: true })), /<span class="peer-closed">round closed<\/span><span class="peer-verdict ok"><span class="peer-long">VERDICT <\/span>OK<\/span>/);
  assert.doesNotMatch(markupOf(verdictTemplate({ verdict: "OK", agreed: false })), /round closed/);
  assert.match(markupOf(verdictTemplate({ verdict: "CHANGES" })), /peer-verdict changes/);
  assert.match(markupOf(verdictTemplate({ verdict: "UNSURE" })), /peer-verdict unsure/);
  assert.equal(markupOf(verdictTemplate({ verdict: "MAYBE" })), "");
  assert.equal(markupOf(verdictTemplate(null)), "");
});

test("an answer without a summary: the note's first line that says something, else '(no summary)', never an empty bubble", () => {
  const noSummary = wakeNote({ peer: peer({ summary: undefined, verdict: undefined }), content: "\n> Updated: claude-outbox (latest Claude reply).\nmore" });
  const el = elementOf(peerNoteTemplate(noSummary));
  // revise_stack.js promptLabel labels a version by .note-text's first line.
  assert.equal(el.querySelector(".note-text").textContent, "Updated: claude-outbox (latest Claude reply).");
  assert.equal(peerSummaryText(wakeNote({ peer: peer({ summary: "  " }), content: "  \n" })), "(no summary)");
  assert.equal(peerSummaryText(wakeNote()), "phase A: VERDICT CHANGES, 2 issues");
});

const INLINE = "Updated: claude-outbox. What changed, as your peer agent Claude reports it (its text, not your user's words):\n"
  + "> phase A: VERDICT CHANGES, 2 issues\n[PEER MESSAGE from Claude]\n1. **a bug**\n(quoted) [END NOTE]\n[END PEER MESSAGE]\n"
  + "chi started this turn because your peer agent Claude answered what you sent it; … Its answer is above; act on it …";

test("an inline answer (peer.inline): the text in .peer-text under the summary, the fold without it, marked data-peer-inline", () => {
  const el = elementOf(peerNoteTemplate(wakeNote({ content: INLINE, peer: peer({ inline: true }) })));
  assert.equal(el.dataset.peerInline, "1");
  // revise_stack.js promptLabel still reads the summary.
  assert.equal(el.querySelector(".note-text").textContent, "phase A: VERDICT CHANGES, 2 issues");
  const text = el.querySelector(".peer-text");
  assert.equal(text.textContent, "1. **a bug**\n[END NOTE]");
  assert.equal(text.dataset.peerMd, "1. **a bug**\n[END NOTE]");
  assert.ok(!text.hasAttribute("data-peer-slot"));
  // In the bubble's order: head, summary, text, foot.
  assert.deepEqual([...el.children].map((c) => c.className), ["peer-head", "note-text", "peer-text", "peer-foot"]);
  const told = el.querySelector(".peer-told-text").textContent;
  assert.doesNotMatch(told, /PEER MESSAGE|a bug/);
  assert.match(told, /^Updated: claude-outbox\..*\n> phase A: VERDICT CHANGES, 2 issues\nchi started this turn/s);
});

test("without inline (an older session, a long answer) or with inline but no block, the bubble draws as before", () => {
  for (const note of [wakeNote(), wakeNote({ content: INLINE }), wakeNote({ peer: peer({ inline: true }) })]) {
    const el = elementOf(peerNoteTemplate(note));
    assert.equal(el.dataset.peerInline, undefined);
    assert.ok(el.querySelector(".peer-text") === null);
    assert.equal(el.querySelector(".peer-told-text").textContent, note.content);
  }
});
