// The composer's drafts (drafts.js): the one writer of the message box and
// its chips, over a happy-dom textarea and a stand-in mount.
import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createDrafts } from "../../../lib/samagotchi/web/public/drafts.js";

if (!("localStorage" in globalThis)) globalThis.localStorage = window.localStorage;
const KEY = (id) => `chi_composer_draft:${id}`;
const START = "chi_start_draft";
function wipe() {
  for (let i = localStorage.length - 1; i >= 0; i--) {
    const key = localStorage.key(i);
    if (key === START || key?.startsWith("chi_composer_draft:")) localStorage.removeItem(key);
  }
}

// +shown+: the key on view. The mount's chips as composer_mount.js keeps them.
// +show+: drafts.show(shown) at once (the page's boot); +keep+: storage left as it is.
function setup({ shown = "s1", text = "", show = true, keep = false } = {}) {
  if (!keep) wipe();
  const promptEl = document.createElement("textarea");
  document.body.append(promptEl);
  const log = [];
  const revoked = [];
  let list = [];
  const view = {
    chips: () => list,
    // The mount's: a chip left out frees its preview unless revoke is false.
    setChips: (next, opts) => {
      log.push(["setChips", next.map((c) => c.name), opts ?? null]);
      if (opts?.revoke !== false) for (const c of list) if (c.src && !next.includes(c)) revoked.push(c.src);
      list = next;
    },
    resetHistory: () => log.push("resetHistory"),
  };
  let key = shown;
  const drafts = createDrafts({
    promptEl, view, fit: () => log.push("fit"), shownKey: () => key, revoke: (src) => revoked.push(src),
    reveal: { openForVisit: () => log.push("openForVisit"), focusPrompt: () => log.push("focusPrompt") },
  });
  if (show) drafts.show(shown);
  if (text) drafts.setText(shown, text);
  log.length = 0;
  // A switch as select / clearSelection make it: the key, then forgetSession's show.
  const switchTo = (next) => { key = next; drafts.show(next); };
  // The user typing into the box (its input event).
  const type = (value) => { promptEl.value = value; drafts.syncFromView(); };
  // The user adding an image (the mount pushes onto its list in place).
  const attach = (name) => { const chip = { name, file: {}, src: `blob:${name}` }; list.push(chip); return chip; };
  return { drafts, promptEl, log, view, revoked, switchTo, type, attach, chipNames: () => list.map((c) => c.name) };
}

test("setText writes the box and fits it; reveal, focus and the caret at the end on demand", () => {
  const { drafts, promptEl, log } = setup();
  drafts.setText("s1", "hello");
  assert.equal(promptEl.value, "hello");
  assert.deepEqual(log, ["fit"]);
  log.length = 0;
  drafts.setText("s1", "line one\nline two", { reveal: true, focus: true, caretEnd: true });
  assert.deepEqual(log, ["openForVisit", "fit", "focusPrompt"]);
  assert.equal(promptEl.selectionStart, "line one\nline two".length);
  assert.equal(promptEl.selectionEnd, "line one\nline two".length);
});

test("text and has read the box and the chips; clear empties the text only, the chips stay", () => {
  const { drafts, promptEl, type } = setup({ text: "draft" });
  assert.equal(drafts.text("s1"), "draft");
  assert.equal(drafts.has("s1"), true);
  drafts.putChips("s1", [{ name: "a.png" }]);
  drafts.clear("s1");
  assert.equal(promptEl.value, "");
  assert.deepEqual(drafts.chips("s1").map((c) => c.name), ["a.png"]);
  assert.equal(drafts.has("s1"), true, "a chip alone is a draft");
  drafts.putChips("s1", []);
  assert.equal(drafts.has("s1"), false);
  type("   ");
  assert.equal(drafts.has("s1"), false, "white space alone is no draft");
  assert.equal(promptEl.value, "   ");
});

test("putChips hands the list to the mount", () => {
  const { drafts, log } = setup();
  drafts.putChips("s1", [{ name: "a.png" }, { name: "b.png" }]);
  assert.deepEqual(log, [["setChips", ["a.png", "b.png"], null]]);
});


// ── One draft per session window ─────────────────────────────────────────

test("(a) a draft typed in A is not on B: the box and the chips swap with the window, and come back", () => {
  const { drafts, promptEl, switchTo, type, attach, chipNames, log } = setup({ shown: "A" });
  type("alpha draft");
  attach("a.png");
  switchTo("B");
  assert.equal(promptEl.value, "");
  assert.deepEqual(chipNames(), []);
  assert.ok(log.includes("resetHistory"), "↑/↓ browsing ends with the swap");
  type("beta");
  switchTo("A");
  assert.equal(promptEl.value, "alpha draft");
  assert.deepEqual(chipNames(), ["a.png"]);
  assert.equal(drafts.text("B"), "beta");
});

test("a pick on B goes into B's draft (withDraft of B's text); A's stays as typed", () => {
  const { drafts, promptEl, switchTo, type } = setup({ shown: "A" });
  type("alpha draft");
  switchTo("B");
  type("beta");
  drafts.setText("B", `${drafts.text("B")}\n1: fix now`, { reveal: true, focus: true, caretEnd: true });
  assert.equal(promptEl.value, "beta\n1: fix now");
  assert.equal(drafts.text("A"), "alpha draft");
});

test("a swap frees no preview: A's chips keep their blob URLs; a draft's × and send free them", () => {
  const { drafts, switchTo, attach, revoked, log } = setup({ shown: "A" });
  const a = attach("a.png");
  attach("b.png");
  switchTo("B");
  switchTo("A");
  assert.deepEqual(revoked, []);
  assert.ok(log.some((c) => c[0] === "setChips" && c[2]?.revoke === false));
  drafts.putChips("A", [a]);
  assert.deepEqual(revoked, ["blob:b.png"]);
});

test("a write for a window not on view goes into its draft, never the box", () => {
  const { drafts, promptEl, switchTo, type } = setup({ shown: "A" });
  type("for A");
  switchTo("B");
  type("for B");
  drafts.setText("A", "A again", { reveal: true, focus: true });
  drafts.putChips("A", [{ name: "r.png" }]);
  assert.equal(promptEl.value, "for B");
  assert.equal(drafts.text("A"), "A again");
  assert.deepEqual(drafts.chips("A").map((c) => c.name), ["r.png"]);
  assert.equal(drafts.has("A"), true);
  drafts.clear("A");
  assert.equal(drafts.text("A"), "");
  assert.equal(promptEl.value, "for B");
});

test("move into an empty draft: the text and chips as they are; from emptied, its saved copy gone", () => {
  const { drafts, promptEl, switchTo, type, attach, chipNames, revoked } = setup({ shown: "" });
  type("start text");
  attach("s.png");
  assert.equal(localStorage.getItem(START), "start text");
  drafts.move("", "n1");
  assert.equal(promptEl.value, "");
  assert.deepEqual(chipNames(), []);
  assert.ok(localStorage.getItem(START) === null);
  assert.equal(localStorage.getItem(KEY("n1")), "start text");
  switchTo("n1");
  assert.equal(promptEl.value, "start text");
  assert.deepEqual(chipNames(), ["s.png"]);
  assert.deepEqual(revoked, [], "the moved chips keep their previews");
});

test("move into a draft with text: the moved text goes under it, the chips after its own", () => {
  const { drafts, promptEl, switchTo, type, attach, chipNames } = setup({ shown: "A" });
  type("from A");
  attach("a.png");
  switchTo("B");
  type("in B\n");
  attach("b.png");
  drafts.move("A", "B");
  assert.equal(promptEl.value, "in B\nfrom A");
  assert.deepEqual(chipNames(), ["b.png", "a.png"]);
  assert.equal(drafts.text("A"), "");
  assert.ok(localStorage.getItem(KEY("A")) === null);
  assert.equal(localStorage.getItem(KEY("B")), "in B\nfrom A");
  drafts.move("A", "B");
  assert.equal(promptEl.value, "in B\nfrom A", "an empty draft moves nothing");
});

test("saved in this browser: a session's text under chi_composer_draft:<id>, read back by a fresh page; chips never", () => {
  const first = setup({ shown: "A" });
  first.type("kept over a reload");
  first.attach("lost.png");
  assert.equal(localStorage.getItem(KEY("A")), "kept over a reload");
  const again = setup({ shown: "A", keep: true });
  assert.equal(again.promptEl.value, "kept over a reload");
  assert.deepEqual(again.chipNames(), []);
  assert.equal(again.drafts.text("A"), "kept over a reload");
});

test("an emptied draft removes its key, never stores an empty string; the start page's own key", () => {
  const { switchTo, type } = setup({ shown: "A" });
  type("x");
  type("  ");
  assert.ok(localStorage.getItem(KEY("A")) === null);
  switchTo("");
  type("start");
  assert.equal(localStorage.getItem(START), "start");
  assert.ok(localStorage.getItem(KEY("")) === null);
  const again = setup({ shown: "", keep: true });
  assert.equal(again.promptEl.value, "start");
});

test("show of the window on view changes nothing; show paints over a value the browser restored", () => {
  const { drafts, promptEl, type, log } = setup({ shown: "A" });
  type("mine");
  drafts.show("A");
  assert.deepEqual(log, []);
  assert.equal(promptEl.value, "mine");
  wipe();
  localStorage.setItem(KEY("B"), "B's");
  const fresh = setup({ shown: "B", show: false, keep: true });
  fresh.promptEl.value = "form-restored text";
  fresh.drafts.show("B");
  assert.equal(fresh.promptEl.value, "B's");
});

test("drop forgets a draft, here and saved, and frees its previews; the draft on view empties and a swap doesn't save it again", () => {
  const { drafts, promptEl, switchTo, type, attach, revoked } = setup({ shown: "A" });
  type("doomed");
  attach("d.png");
  drafts.drop("A");
  assert.equal(promptEl.value, "");
  assert.deepEqual(revoked, ["blob:d.png"]);
  switchTo("");
  assert.ok(localStorage.getItem(KEY("A")) === null);
  assert.equal(drafts.text("A"), "");
});

test("a line in flight: the saved copy leaves it out, text typed since stays; settled, the draft is saved as it is", () => {
  const { drafts, type } = setup({ shown: "A" });
  type("send me");
  drafts.sending("A", "send me");
  assert.ok(localStorage.getItem(KEY("A")) === null, "a reload right after Send brings back nothing");
  type("send me\nand more");
  assert.equal(localStorage.getItem(KEY("A")), "send me\nand more");
  type("send me");
  drafts.settle("A", "another line");
  assert.ok(localStorage.getItem(KEY("A")) === null, "another send's settle leaves it");
  drafts.settle("A", "send me");
  assert.equal(localStorage.getItem(KEY("A")), "send me", "a failed send: the line is the draft again");
});

test("an older cached session_view.js never calls show: the box stays the one for every window", () => {
  const { drafts, promptEl, type } = setup({ shown: "A" });
  type("shared");
  let key = "A";
  const old = createDrafts({ promptEl, view: { chips: () => [], setChips: () => {} }, shownKey: () => key });
  old.show("A");
  key = "B";
  assert.equal(old.text("B"), "shared");
  promptEl.value = "typed on B";
  old.syncFromView();
  assert.equal(localStorage.getItem(KEY("B")), "typed on B");
  assert.equal(drafts.text("A"), "typed on B");
});

test("putBack: into an empty draft only: on view it opens and takes the focus, else it is stored", () => {
  const { drafts, promptEl, switchTo, type, log } = setup({ shown: "A" });
  assert.equal(drafts.putBack("A", "back"), "shown");
  assert.equal(promptEl.value, "back");
  assert.ok(log.includes("openForVisit") && log.includes("focusPrompt"));
  assert.equal(drafts.putBack("A", "again"), false);
  switchTo("B");
  type("mine");
  assert.equal(drafts.putBack("A", "x"), false);
  drafts.clear("A");
  assert.equal(drafts.putBack("A", "into A"), "stored");
  assert.equal(drafts.text("A"), "into A");
  assert.equal(promptEl.value, "mine");
});

// ── Continue → hands the draft to the next link (Phase B) ────────────────

test("handOver: a draft with text moves to the next link (the previous one's saved copy gone), the link's saved", () => {
  const { drafts, switchTo, type, attach } = setup({ shown: "A" });
  type("plan X");
  attach("x.png");
  switchTo("B");
  drafts.handOver("A", "A2", "Continue where we left off.");
  assert.equal(drafts.text("A2"), "plan X");
  assert.deepEqual(drafts.chips("A2").map((c) => c.name), ["x.png"]);
  assert.equal(drafts.text("A"), "");
  assert.ok(localStorage.getItem(KEY("A")) === null);
  assert.equal(localStorage.getItem(KEY("A2")), "plan X");
});

test("handOver: an empty draft leaves the next link the opener; a chips-only draft moves, no opener", () => {
  const { drafts, switchTo, attach } = setup({ shown: "A" });
  drafts.handOver("A", "A2", "Continue where we left off.");
  assert.equal(drafts.text("A2"), "Continue where we left off.");
  switchTo("C");
  attach("c.png");
  drafts.handOver("C", "C2", "Continue where we left off.");
  assert.equal(drafts.text("C2"), "");
  assert.deepEqual(drafts.chips("C2").map((c) => c.name), ["c.png"]);
});

test("handOver: a link with a draft of its own keeps it (continued already); no opener over it", () => {
  const { drafts, switchTo, type } = setup({ shown: "N" });
  type("the next link's own");
  switchTo("A");
  type("A's");
  drafts.handOver("A", "N", null);
  assert.equal(drafts.text("N"), "the next link's own");
  assert.equal(drafts.text("A"), "A's");
  drafts.clear("N");
  drafts.handOver("A", "N", null);
  assert.equal(drafts.text("N"), "A's");
});
