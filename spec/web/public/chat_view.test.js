import test from "node:test";
import assert from "node:assert/strict";
import { chatHistoryHtml } from "../../../lib/samagotchi/web/public/chat_view.js";
import { normalizeTiming } from "../../../lib/samagotchi/web/public/timing.js";

const thumbs = () => "";

test("chatHistoryHtml: the timing line sits under the answer bubble, not in it, as the live view leaves it", () => {
  const items = [
    { role: "user", content: "p" },
    { role: "assistant", content: "Let me check." },
    { role: "assistant", content: "Both fine.", html: "<p>Both <em>fine</em>.</p>" },
    { role: "note", content: "n", label: "x" },
  ];
  const timing = normalizeTiming({ turn_records: [{ id: "T1", status: "completed", duration_ms: 18503 }] });
  assert.equal(chatHistoryHtml(items, timing, { thumbs }),
    '<div class="bubble user" data-copy-source="p"><div class="user-message">p</div></div>' +
    '<div class="bubble output">Let me check.</div>' +
    '<div class="bubble output markdown" data-copy-source="Both fine."><p>Both <em>fine</em>.</p></div><div class="turn-timing">turn 1 · 19s</div>' +
    '<div class="bubble note"><div class="note-line">note from x</div><div class="note-text">n</div></div>');
});

test("chatHistoryHtml: a canceled turn ends with its timing, then its cancel line", () => {
  const canceled = normalizeTiming({ turn_records: [{ id: "T1", status: "canceled", duration_ms: 900 }] });
  const answered = chatHistoryHtml([{ role: "user", content: "p" }, { role: "assistant", content: "part" }], canceled, { thumbs });
  assert.match(answered, /<div class="bubble output">part<\/div><div class="turn-timing">turn 1 · 0.9s · canceled<\/div><div class="bubble cancel">✕ canceled<\/div>$/);
  const bare = chatHistoryHtml([{ role: "user", content: "p" }], canceled, { thumbs });
  assert.match(bare, /<div class="user-message">p<\/div><\/div><div class="turn-timing">turn 1 · 0.9s · canceled<\/div><div class="bubble cancel">✕ canceled<\/div>$/);
});
