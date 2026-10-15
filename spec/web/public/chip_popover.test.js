import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createChipPopover, popoverPlace } from "../../../lib/samagotchi/web/public/chip_popover.js";
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
