import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { focusBack, holdFocus, modalDialog, tabStops } from "../../../lib/samagotchi/web/public/popover_modal.js";

// A Tab's keydown on the focused element; whether it was taken (prevented).
const tab = (shiftKey = false) => {
  const e = new window.KeyboardEvent("keydown", { key: "Tab", shiftKey, bubbles: true, cancelable: true });
  (document.activeElement || document.body).dispatchEvent(e);
  return e.defaultPrevented;
};

function popWith(markup) {
  const pop = document.createElement("div");
  pop.innerHTML = markup;
  document.body.append(pop);
  return pop;
}

test("tabStops: what Tab reaches, in order, none disabled, hidden or tabindex -1", () => {
  const pop = popWith('<button>a</button><button disabled>x</button><div hidden><button>h</button></div><a href="#">l</a>' +
    '<span tabindex="-1">n</span><input><span tabindex="0">t</span>');
  assert.deepEqual(tabStops(pop).map((e) => e.textContent || e.tagName), ["a", "l", "INPUT", "t"]);
  pop.remove();
});

test("modalDialog: a named modal dialog; Tab and Shift+Tab wrap while open and on the page, a Tab from outside goes in", () => {
  let open = true;
  const pop = popWith("<button>a</button><button>b</button>");
  const out = popWith("<button>out</button>").firstElementChild;
  modalDialog(pop, { label: "Things", isOpen: () => open });
  assert.deepEqual([pop.getAttribute("role"), pop.getAttribute("aria-modal"), pop.getAttribute("aria-label")], ["dialog", "true", "Things"]);
  const [a, b] = pop.querySelectorAll("button");
  out.focus();
  assert.equal(tab(true), true); // from outside, backwards: the last
  assert.ok(document.activeElement === b);
  assert.equal(tab(), true);
  assert.ok(document.activeElement === a);
  assert.equal(tab(), false); // a to b: the browser's own
  open = false;
  out.focus();
  assert.equal(tab(), false);
  open = true;
  pop.remove(); // gone from the page while still "open" (a dropped element): no trap
  assert.equal(tab(), false);
  out.parentElement.remove();
});

test("holdFocus: a popover with nothing to focus leaves the Tab alone", () => {
  const pop = popWith("<p>text</p>");
  const e = new window.KeyboardEvent("keydown", { key: "Tab", cancelable: true });
  holdFocus(e, pop);
  assert.equal(e.defaultPrevented, false);
  pop.remove();
});

test("focusBack: focus that was in the popover (or an Esc's) goes back to the opener, if it is still there", () => {
  const pop = document.createElement("div");
  pop.innerHTML = "<button>in</button>";
  const chip = document.createElement("button");
  document.body.append(pop, chip);
  pop.querySelector("button").focus();
  focusBack(pop)(chip);
  assert.ok(document.activeElement === chip);
  const out = document.createElement("button");
  document.body.append(out);
  out.focus();
  focusBack(pop)(chip); // the focus was elsewhere: it stays
  assert.ok(document.activeElement === out);
  focusBack(pop, { refocus: true })(chip);
  assert.ok(document.activeElement === chip);
  out.focus();
  chip.remove();
  focusBack(pop, { refocus: true })(chip); // gone: nothing to focus
  assert.ok(document.activeElement === out);
  focusBack(pop, { refocus: true })(null);
  pop.remove();
  out.remove();
});
