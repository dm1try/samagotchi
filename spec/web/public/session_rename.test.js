import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createRename, inputBox, outsideClip, titleLine } from "../../../lib/samagotchi/web/public/session_rename.js";

const rect = (left, top, width, height) => ({ left, top, width, height, right: left + width, bottom: top + height });

// The title row on screen (a card's .preview-row, or the top bar's): its
// text, then its ✎.
function harness({ titles = { s1: "Coordinator" }, shown = (id) => titles[id] || "" } = {}) {
  document.body.innerHTML = "";
  const row = document.createElement("div");
  row.innerHTML = '<span class="text">Coordinator</span><button>✎</button>';
  row.getBoundingClientRect = () => rect(20, 10, 300, 20);
  document.body.append(row);
  const button = row.querySelector("button");
  const page = { id: "s1", anchor: row, popoversClosed: 0, closes: 0 };
  const sent = [];
  const rename = createRename({
    doc: document,
    anchor: () => page.anchor,
    session: () => page.id,
    titleOf: (id) => titles[id] || null,
    shownTitle: shown,
    closePopovers: () => { page.popoversClosed += 1; },
    onClose: () => { page.closes += 1; },
    run: (line) => { sent.push(line); return Promise.resolve(true); },
  });
  const input = () => document.querySelector("input.rename-input");
  const key = (k) => input().dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));
  return { rename, row, button, input, key, sent, page };
}

test("titleLine: the text as /title, whitespace collapsed; blank clears", () => {
  assert.equal(titleLine("  Release \n day "), "/title Release day");
  assert.equal(titleLine("   "), "/title --clear");
});

test("inputBox: the anchor's box, a short one widened and heightened, never past the right edge", () => {
  assert.deepEqual(inputBox(rect(20, 10, 300, 30), 1200), { left: 20, top: 10, width: 300, height: 30 });
  assert.deepEqual(inputBox(rect(20, 10, 50, 16), 1200), { left: 20, top: 6, width: 192, height: 24 });
  assert.equal(inputBox(rect(300, 0, 200, 20), 400).width, 84);
});

test("outsideClip: a row swiped past its strip's edge is out; one inside is in", () => {
  const strip = rect(0, 0, 390, 100);
  assert.equal(outsideClip(rect(16, 10, 300, 20), strip), false);
  assert.equal(outsideClip(rect(-40, 10, 300, 20), strip), true);
  assert.equal(outsideClip(rect(200, 10, 300, 20), strip), true);
});

test("open: an input at the end of body over the title row, prefilled, focused; popovers closed first; Enter sends /title", () => {
  const h = harness();
  h.rename.open();
  assert.equal(h.page.popoversClosed, 1);
  assert.ok(h.input().parentElement === document.body);
  assert.ok(document.activeElement === h.input());
  assert.equal(h.input().value, "Coordinator");
  assert.deepEqual([h.input().style.left, h.input().style.top, h.input().style.width], ["20px", "8px", "300px"]);
  assert.equal(h.rename.isOpen(), true);
  assert.equal(h.input().classList.contains("over-bar"), true); // not in the strip: the top bar's row
  h.input().value = "Release day";
  h.key("Enter");
  assert.deepEqual(h.sent, ["/title Release day"]);
  assert.equal(h.input(), null);
  assert.equal(h.page.closes, 1);
});

test("open does nothing with no title on screen or no session", () => {
  const h = harness();
  h.page.anchor = null;
  h.rename.open();
  assert.equal(h.input(), null);
  assert.equal(h.page.popoversClosed, 0);
  h.page.anchor = h.row;
  h.page.id = null;
  h.rename.open();
  assert.equal(h.input(), null);
});

test("the placeholder is the title as shown (an untitled chain link's is its chain's)", () => {
  const h = harness({ titles: {}, shown: () => "Plan the release" });
  h.rename.open();
  assert.equal(h.input().value, "");
  assert.equal(h.input().placeholder, "Plan the release");
  h.key("Escape");
  const bare = harness({ titles: {}, shown: () => "" });
  bare.rename.open();
  assert.equal(bare.input().placeholder, "Session title");
});

test("empty clears; the same title, Esc, or another session opened meanwhile sends nothing", () => {
  const h = harness();
  h.rename.open();
  h.input().value = "";
  h.key("Enter");
  assert.deepEqual(h.sent, ["/title --clear"]);

  h.rename.open();
  h.input().value = " Coordinator ";
  h.key("Enter");
  h.rename.open();
  h.input().value = "Other";
  h.key("Escape");
  assert.equal(h.input(), null);
  assert.deepEqual(h.sent, ["/title --clear"]);

  h.rename.open();
  h.page.id = "s2";
  h.rename.follow("s2");
  assert.equal(h.input(), null);
});

test("Esc gives the focus back to the ✎ in the title row as drawn now", () => {
  const h = harness();
  h.rename.open();
  // The strip drew the card again meanwhile: a new row, a new ✎.
  const row = document.createElement("div");
  row.innerHTML = '<span class="text">Coordinator</span><button>✎</button>';
  document.body.append(row);
  h.page.anchor = row;
  h.key("Escape");
  assert.ok(document.activeElement === row.querySelector("button"));
});

test("leaving the field saves what was typed, once; Esc then blur, or a switch, sends nothing", () => {
  const h = harness();
  h.rename.open();
  h.input().value = "Typed on a phone";
  h.input().dispatchEvent(new window.Event("blur"));
  assert.deepEqual(h.sent, ["/title Typed on a phone"]);
  assert.equal(h.input(), null);

  h.rename.open();
  const el = h.input();
  el.value = "Thrown away";
  h.key("Escape");
  el.dispatchEvent(new window.Event("blur"));
  assert.deepEqual(h.sent, ["/title Typed on a phone"]);

  // The page opened another session before the blur: nothing goes to it.
  h.rename.open();
  h.input().value = "Meant for s1";
  h.page.id = "s2";
  h.input().dispatchEvent(new window.Event("blur"));
  assert.deepEqual(h.sent, ["/title Typed on a phone"]);
  assert.equal(h.input(), null);
});

test("reposition follows the title row; with it gone the input closes unsent", () => {
  const h = harness();
  h.rename.open();
  h.row.getBoundingClientRect = () => rect(40, 60, 260, 20);
  h.rename.reposition();
  assert.deepEqual([h.input().style.left, h.input().style.top], ["40px", "58px"]);
  const el = h.input();
  el.value = "Half typed";
  h.page.anchor = null;
  h.rename.reposition();
  assert.equal(h.input(), null);
  assert.equal(h.page.closes, 1);
  el.dispatchEvent(new window.Event("blur"));
  assert.deepEqual(h.sent, []);
});

test("reposition closes unsent when a card's row is swiped out of the strip", () => {
  const h = harness();
  const strip = document.createElement("section");
  strip.id = "topStrip";
  strip.getBoundingClientRect = () => rect(0, 0, 390, 100);
  strip.append(h.row);
  document.body.append(strip);
  h.rename.open();
  h.rename.reposition();
  assert.equal(h.rename.isOpen(), true);
  assert.equal(h.input().classList.contains("over-bar"), false);
  h.row.getBoundingClientRect = () => rect(-200, 10, 300, 20);
  h.rename.reposition();
  assert.equal(h.rename.isOpen(), false);
  assert.deepEqual(h.sent, []);
});

test("an untitled session's input starts empty", () => {
  const h = harness({ titles: {} });
  h.rename.open();
  assert.equal(h.input().value, "");
  h.key("Enter");
  assert.deepEqual(h.sent, []);
});
