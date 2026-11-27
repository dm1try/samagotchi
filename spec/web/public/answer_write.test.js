import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { writeAnswer } from "../../../lib/samagotchi/web/public/answer_write.js";
import { fullTime } from "../../../lib/samagotchi/web/public/format.js";

function bubble(html) {
  const el = document.createElement("div");
  el.className = "bubble output markdown";
  el.innerHTML = html;
  document.body.append(el);
  return el;
}

test("writeAnswer: class, copy source, display flag, html and title; the title from at, none when it can't be parsed", () => {
  const el = bubble("See JIRA-1.");
  writeAnswer(el, {
    role: "assistant", content: "See JIRA-1.", display: "Hook display",
    html: "<p>See <strong>JIRA-1</strong>.</p>", at: "2026-11-27T14:32:05Z",
  });
  assert.ok(el.classList.contains("markdown"));
  assert.equal(el.getAttribute("data-copy-source"), "Hook display");
  assert.ok(el.hasAttribute("data-answer-display"));
  assert.equal(el.innerHTML, "<p>See <strong>JIRA-1</strong>.</p>");
  assert.equal(el.getAttribute("title"), fullTime("2026-11-27T14:32:05Z"));
  assert.ok(fullTime("2026-11-27T14:32:05Z").length > 0);

  // No display: no display flag.
  const noDisplay = bubble("plain");
  writeAnswer(noDisplay, {
    role: "assistant", content: "plain",
    html: "<p>plain</p>", at: "2026-11-27T14:32:05Z",
  });
  assert.ok(!noDisplay.hasAttribute("data-answer-display"));
  assert.equal(noDisplay.getAttribute("data-copy-source"), "plain");

  // No html (web.markdown off): the text and any existing title stay.
  const plain = bubble("plain text");
  plain.setAttribute("title", "keeping the old one");
  writeAnswer(plain, { role: "assistant", content: "plain text" });
  assert.equal(plain.innerHTML, "plain text");
  assert.equal(plain.getAttribute("title"), "keeping the old one");

  // A non-html at: no title.
  const noTime = bubble("x");
  writeAnswer(noTime, { role: "assistant", content: "x", html: "<p>x</p>", at: "" });
  assert.equal(noTime.getAttribute("title"), null);
  el.remove();
  noDisplay.remove();
  plain.remove();
  noTime.remove();
});
