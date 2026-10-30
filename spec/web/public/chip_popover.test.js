import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createChipPopover, popoverPlace, SHEET_TALL, sheetPlace } from "../../../lib/samagotchi/web/public/chip_popover.js";
import { html, render } from "../../../lib/samagotchi/web/public/vendor/lit-html.js";

test("the popover opens above the chip, below it when the room above is short, capped to the room it has", () => {
  const win = { width: 343, innerWidth: 375, innerHeight: 560 };
  // Room above: opens upward, its bottom 8 px over the chip.
  assert.deepEqual(popoverPlace({ left: 130, top: 470, bottom: 494 }, { ...win, height: 300 }), { left: 16, bottom: 98 });
  // A chip near the top: below it.
  assert.deepEqual(popoverPlace({ left: 20, top: 60, bottom: 84 }, { ...win, height: 300 }), { left: 16, top: 92 });
  // Neither side fits: the roomier one, capped (it scrolls), never above the window's top.
  assert.deepEqual(popoverPlace({ left: 20, top: 300, bottom: 324 }, { ...win, height: 400 }), { left: 16, bottom: 268, maxHeight: 276 });
});

// A shell on the shim's document: a chip inside +el+, a form with a ×, a
// Set and another data-act; +calls+ records what reached the caller.
function shell(opts = {}) {
  const el = document.createElement("div");
  el.innerHTML = '<button class="my-chip">chip</button>';
  document.body.append(el);
  const calls = [];
  let sid = "s1";
  const ctl = createChipPopover({
    id: "myPopover", className: "ctx-popover my-popover", width: 300, el, anchor: ".my-chip",
    summary: () => ({ n: calls.length }), session: () => sid, win: { innerWidth: 1000, innerHeight: 800 },
    show: (data, opening) => {
      calls.push(["show", opening]);
      render(html`<form><button type="button" data-act="close">×</button><button type="button" data-act="other">o</button
        ><button type="submit">Set</button></form>`, ctl.pop);
    },
    onClose: () => calls.push(["close"]), onSubmit: (form) => calls.push(["submit", form.tagName]),
    onAct: (name) => calls.push(["act", name]), ...opts,
  });
  const chip = el.querySelector(".my-chip");
  return { ctl, el, chip, calls, setSession: (id) => { sid = id; }, done: () => { el.remove(); ctl.pop.remove(); } };
}

test("the shell is a hidden dialog on the body; the chip opens and closes it, a refresh redraws it", () => {
  const s = shell();
  assert.equal(s.ctl.pop.id, "myPopover");
  assert.equal(s.ctl.pop.className, "ctx-popover my-popover");
  assert.equal(s.ctl.pop.getAttribute("role"), "dialog");
  assert.equal(s.ctl.isOpen(), false);
  s.chip.click();
  assert.equal(s.ctl.isOpen(), true);
  assert.equal(s.ctl.pop.style.width, "300px");
  s.ctl.refresh();
  s.chip.click();
  assert.equal(s.ctl.isOpen(), false);
  assert.equal(s.ctl.pop.querySelector("form"), null);
  assert.deepEqual(s.calls, [["show", true], ["show", false], ["close"]]);
  s.done();
});

test("×, Esc and a click outside close it; a Set and another act reach the caller", () => {
  const s = shell();
  s.chip.click();
  s.ctl.pop.querySelector("[data-act=other]").click();
  s.ctl.pop.querySelector("form").dispatchEvent(new window.Event("submit", { bubbles: true, cancelable: true }));
  assert.deepEqual(s.calls.slice(1), [["act", "other"], ["submit", "FORM"]]);
  assert.equal(s.ctl.isOpen(), true);
  s.ctl.pop.querySelector("[data-act=close]").click();
  assert.equal(s.ctl.isOpen(), false);
  s.chip.click();
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape" }));
  assert.equal(s.ctl.isOpen(), false);
  s.chip.click();
  document.body.click();
  assert.equal(s.ctl.isOpen(), false);
  s.done();
});

test("a refresh for another session, or with no summary, closes it", () => {
  const s = shell();
  s.chip.click();
  s.setSession("s2");
  s.ctl.refresh();
  assert.equal(s.ctl.isOpen(), false);
  s.done();
  const none = shell({ summary: () => null });
  none.chip.click();
  assert.equal(none.ctl.isOpen(), false);
  none.done();
});

// Two shells: on one el (the session bar's chips share #infoText) and on
// sibling els (the start page's chips). +make(el, n)+ adds the nth.
function twoShells(sameEl) {
  const make = (el, n) => {
    el.insertAdjacentHTML("beforeend", `<button class="chip-${n}">chip ${n}</button>`);
    const ctl = createChipPopover({
      id: `pop${n}`, className: "ctx-popover", width: 300, el, anchor: `.chip-${n}`,
      summary: () => ({}), win: { innerWidth: 1000, innerHeight: 800 }, show: () => {}, onSubmit: () => {},
    });
    return { ctl, chip: el.querySelector(`.chip-${n}`) };
  };
  const els = [document.createElement("div"), sameEl ? null : document.createElement("div")].filter(Boolean);
  document.body.append(...els);
  const a = make(els[0], 1);
  const b = make(els.at(-1), 2);
  return { a, b, done: () => { els.forEach((el) => el.remove()); a.ctl.pop.remove(); b.ctl.pop.remove(); } };
}

for (const sameEl of [true, false]) {
  test(`one chip popover open at a time (${sameEl ? "chips on one el" : "chips on sibling els"})`, () => {
    const { a, b, done } = twoShells(sameEl);
    a.chip.click();
    assert.equal(a.ctl.isOpen(), true);
    b.chip.click();
    assert.equal(b.ctl.isOpen(), true);
    assert.equal(a.ctl.isOpen(), false);
    a.chip.click();
    assert.equal(a.ctl.isOpen(), true);
    assert.equal(b.ctl.isOpen(), false);
    done();
  });
}

test("a sheet's place: the window's width less 8 px edges, at its bottom, at most 60 % high (or the share asked)", () => {
  assert.deepEqual(sheetPlace({ innerWidth: 390, innerHeight: 844 }), { left: 8, bottom: 8, width: 374, maxHeight: 506 });
  assert.equal(sheetPlace({ innerWidth: 390, innerHeight: 670 }, { share: SHEET_TALL }).maxHeight, 570);
  // A keyboard over the page: on the visual viewport, sized to it.
  assert.deepEqual(sheetPlace({ innerWidth: 390, innerHeight: 844 }, { viewport: { height: 500, offsetTop: 0 } }),
    { left: 8, bottom: 352, width: 374, maxHeight: 300 });
});

test("open(anchor) from another opener: summary gets the anchor; a click on an opener isn't outside; Esc and × give focus back", () => {
  const other = document.createElement("div");
  other.className = "my-rail";
  other.tabIndex = 0;
  document.body.append(other);
  const anchors = [];
  const s = shell({ openers: ".my-chip, .my-rail", summary: (anchor) => { anchors.push(anchor); return {}; } });
  s.ctl.open(other);
  assert.ok(anchors[0] === other);
  assert.ok(s.ctl.opener() === other);
  other.click(); // the opener's own click handler decides; the document's doesn't close it
  assert.equal(s.ctl.isOpen(), true);
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape" }));
  assert.equal(s.ctl.isOpen(), false);
  assert.ok(document.activeElement === other);
  // The ×: focus was in the popover, back to the opener.
  s.ctl.open(s.chip);
  const x = s.ctl.pop.querySelector("[data-act=close]");
  x.focus();
  x.click();
  assert.ok(document.activeElement === s.chip);
  s.done();
  other.remove();
});

test("a sheet popover is a bottom sheet in a narrow window, a popover at its chip in a wide one", () => {
  const win = { innerWidth: 390, innerHeight: 800 };
  const s = shell({ sheet: true, win });
  s.chip.click();
  assert.equal(s.ctl.pop.classList.contains("sheet"), true);
  assert.deepEqual([s.ctl.pop.style.left, s.ctl.pop.style.bottom, s.ctl.pop.style.width, s.ctl.pop.style.maxHeight, s.ctl.pop.style.top],
    ["8px", "8px", "374px", "480px", ""]);
  s.ctl.close();
  win.innerWidth = 1000;
  s.chip.click();
  assert.equal(s.ctl.pop.classList.contains("sheet"), false);
  assert.equal(s.ctl.pop.style.width, "300px");
  s.done();
});

test("the opener clicked and the anchor carry aria-expanded while it is open, the other openers don't", () => {
  const other = document.createElement("button");
  other.className = "my-rail";
  document.body.append(other);
  const s = shell({ openers: ".my-chip, .my-rail" });
  const states = () => [s.chip.getAttribute("aria-expanded"), other.getAttribute("aria-expanded")];
  assert.deepEqual(states(), [null, null]);
  s.chip.click();
  assert.deepEqual(states(), ["true", null]);
  s.ctl.close();
  assert.deepEqual(states(), ["false", null]);
  s.ctl.open(other);
  assert.deepEqual(states(), ["false", "true"]);
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape" }));
  assert.deepEqual(states(), ["false", "false"]);
  // At the chip, from the other opener (the start page's override chips): both.
  s.ctl.open(s.chip, { from: other });
  assert.deepEqual(states(), ["true", "true"]);
  s.ctl.close();
  assert.deepEqual(states(), ["false", "false"]);
  s.done();
  other.remove();
});

test("open(anchor, {from}): placed at the anchor, focus goes back to +from+, or the anchor once +from+ is hidden", () => {
  const other = document.createElement("button");
  other.className = "my-rail";
  document.body.append(other);
  const s = shell({ openers: ".my-chip, .my-rail" });
  s.ctl.open(s.chip, { from: other });
  assert.ok(s.ctl.opener() === s.chip);
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape" }));
  assert.ok(document.activeElement === other);
  s.ctl.open(s.chip, { from: other });
  other.hidden = true;
  document.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape" }));
  assert.ok(document.activeElement === s.chip);
  s.done();
  other.remove();
});

test("every popover is modal: aria-modal, Tab and Shift+Tab wrap inside, a Tab from outside goes in", () => {
  const tab = (shiftKey = false) => {
    const e = new window.KeyboardEvent("keydown", { key: "Tab", shiftKey, bubbles: true, cancelable: true });
    document.activeElement.dispatchEvent(e);
    return e.defaultPrevented;
  };
  const s = shell({ label: "Mine" });
  assert.deepEqual([s.ctl.pop.getAttribute("role"), s.ctl.pop.getAttribute("aria-modal"), s.ctl.pop.getAttribute("aria-label")],
    ["dialog", "true", "Mine"]);
  s.chip.click();
  const [x, other, set] = s.ctl.pop.querySelectorAll("button");
  set.focus();
  assert.equal(tab(), true);
  assert.ok(document.activeElement === x);
  assert.equal(tab(true), true);
  assert.ok(document.activeElement === set);
  other.focus();
  assert.equal(tab(), false); // the browser moves it
  s.chip.focus(); // outside (the opener kept it, or a redraw dropped it)
  assert.equal(tab(), true);
  assert.ok(document.activeElement === x);
  s.ctl.close();
  s.chip.focus();
  assert.equal(tab(), false); // closed: the page's own Tab
  s.done();
});

test("an open one is placed again on a resize: a sheet follows the window (and a visual viewport a keyboard shortened)", () => {
  const listeners = {};
  const vvListeners = {};
  const viewport = { height: 800, offsetTop: 0, addEventListener: (type, fn) => { vvListeners[type] = fn; } };
  const win = { innerWidth: 390, innerHeight: 800, visualViewport: viewport, addEventListener: (type, fn) => { listeners[type] = fn; } };
  const s = shell({ sheet: true, win });
  s.chip.click();
  assert.equal(s.ctl.pop.style.maxHeight, "480px");
  win.innerHeight = 420;
  viewport.height = 420;
  listeners.resize();
  assert.deepEqual([s.ctl.pop.style.maxHeight, s.ctl.pop.style.bottom], ["252px", "8px"]);
  win.innerHeight = 800; // a keyboard over the page: the layout viewport stays, the visual one shrinks
  viewport.height = 500;
  vvListeners.resize();
  assert.deepEqual([s.ctl.pop.style.maxHeight, s.ctl.pop.style.bottom], ["300px", "308px"]);
  viewport.height = 800;
  win.innerWidth = 900;
  listeners.resize();
  assert.equal(s.ctl.pop.classList.contains("sheet"), false);
  s.ctl.close();
  listeners.resize(); // closed: nothing to place
  s.done();
});

// An act that redraws its own button away (the participants panel's Cap,
// swapped for its field) is a click inside, not outside: it stays open.
test("a click on a button the act redraws away doesn't close it", () => {
  const s = shell({ onAct: (name) => {
    if (name === "other") render(html`<form><input name="swapped"></form>`, s.ctl.pop);
  } });
  s.chip.click();
  s.ctl.pop.querySelector("[data-act=other]").click();
  assert.equal(s.ctl.isOpen(), true);
  assert.ok(s.ctl.pop.querySelector("input[name=swapped]"));
  document.body.click();
  assert.equal(s.ctl.isOpen(), false);
  s.done();
});
