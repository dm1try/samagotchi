import test from "node:test";
import assert from "node:assert/strict";
import { renderStable } from "../../../lib/samagotchi/web/public/stable_html.js";

// An element whose innerHTML writes are counted; its one live part is the
// element querySelector hands back once html holds that part's class.
function fakeEl() {
  const part = { textContent: "" };
  let html = "";
  return {
    writes: 0,
    part,
    get innerHTML() { return html; },
    set innerHTML(value) { html = value; this.writes += 1; part.textContent = ""; },
    querySelector: (sel) => (html.includes(`class="${sel.slice(1)}"`) ? part : null),
  };
}

test("renderStable: the same html twice writes it once", () => {
  const el = fakeEl();
  renderStable(el, "<span>a</span>");
  renderStable(el, "<span>a</span>");
  assert.equal(el.writes, 1);
  renderStable(el, "<span>b</span>");
  assert.equal(el.writes, 2);
});

test("renderStable: a tick of the live part sets its text, not the html", () => {
  const el = fakeEl();
  const html = '<button>copy</button><span class="session-time"></span>';
  renderStable(el, html, { ".session-time": "session 1s" });
  renderStable(el, html, { ".session-time": "session 2s" });
  assert.equal(el.writes, 1);
  assert.equal(el.part.textContent, "session 2s");
});

test("renderStable: a rewrite fills the live part again", () => {
  const el = fakeEl();
  renderStable(el, '<span class="session-time"></span>', { ".session-time": "session 1s" });
  renderStable(el, '<b>x</b><span class="session-time"></span>', { ".session-time": "session 1s" });
  assert.equal(el.writes, 2);
  assert.equal(el.part.textContent, "session 1s");
});

test("renderStable: a live part the html leaves out is skipped", () => {
  const el = fakeEl();
  renderStable(el, "<span>a</span>", { ".session-time": "" });
  assert.equal(el.part.textContent, "");
});
