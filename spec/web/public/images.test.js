import test from "node:test";
import assert from "node:assert/strict";
import {
  chipName, chipsHtml, imageFiles, imageUrl, restoredChips, thumbsHtml, turnRefs, turnText,
} from "../../../lib/samagotchi/web/public/images.js";
import { createIdleSession, sendTurn, uploadImage } from "../../../lib/samagotchi/web/public/data.js";
import { promptOps, restoreAction, snapshotEvents } from "../../../lib/samagotchi/web/public/turn_events.js";
import { addCompleted, newActivity } from "../../../lib/samagotchi/web/public/activity.js";

const ME = "web:me";
const REF = { file: "images/0123456789abcdef.png", name: "shot.png", width: 1280, height: 800 };

function recorder(body = {}) {
  const calls = [];
  const fetchImpl = (path, opts) => {
    calls.push([path, opts]);
    return Promise.resolve({ ok: true, status: 200, json: async () => body });
  };
  return { calls, fetchImpl };
}

test("imageFiles takes the image files of a paste or drop, once each", () => {
  const png = { type: "image/png", name: "a.png" };
  const text = { type: "text/plain", name: "a.txt" };
  const dt = { files: [png, text], items: [{ kind: "file", getAsFile: () => png }, { kind: "string" }] };
  assert.deepEqual(imageFiles(dt), [png]);
  assert.deepEqual(imageFiles(null), []);
});

test("chipName keeps a real name and numbers pasted screenshots", () => {
  assert.equal(chipName({ name: "shot.png", type: "image/png" }, 0), "shot.png");
  assert.equal(chipName({ name: "image.png", type: "image/png" }, 1), "pasted-2.png");
  assert.equal(chipName({ name: "", type: "image/jpeg" }, 0), "pasted-1.jpg");
});

test("turnText sends the typed text, or names the images when there is none", () => {
  assert.equal(turnText("  what's this? ", [{ name: "a.png" }]), "what's this?");
  assert.equal(turnText("", [{ name: "a.png" }, { name: "b.png" }]), "[image: a.png] [image: b.png]");
  assert.equal(turnText("", []), "");
});

test("chips render escaped, with a remove button each; turnRefs names the uploaded ones", () => {
  const chips = [{ name: "<b>.png", src: "blob:1", ref: { file: "images/aaaaaaaaaaaaaaaa.png" } }, { name: "c.png", src: "blob:2" }];
  const html = chipsHtml(chips);
  assert.match(html, /&lt;b&gt;\.png/);
  assert.equal((html.match(/chip-remove/g) || []).length, 2);
  assert.deepEqual(turnRefs(chips), [{ file: "images/aaaaaaaaaaaaaaaa.png", name: "<b>.png" }]);
});

test("thumbsHtml points at the session's image route and escapes names", () => {
  assert.equal(imageUrl("s-1", REF), "/api/sessions/s-1/images/0123456789abcdef.png");
  const html = thumbsHtml("s-1", [REF, { src: "blob:x", name: 'a"b' }]);
  assert.match(html, /src="\/api\/sessions\/s-1\/images\/0123456789abcdef\.png"/);
  assert.match(html, /title="shot\.png 1280×800"/);
  assert.match(html, /alt="a&quot;b"/);
  assert.equal(thumbsHtml("s-1", []), "");
});

test("sendTurn names the images; uploadImage posts the raw file; createIdleSession asks for idle", async () => {
  const r = recorder({ enqueued_id: "e1" });
  await sendTurn("s1", "look", { clientId: ME, images: [{ file: REF.file, name: "shot.png" }], fetchImpl: r.fetchImpl });
  assert.deepEqual(JSON.parse(r.calls[0][1].body), { prompt: "look", client_id: ME, images: [{ file: REF.file, name: "shot.png" }] });
  await sendTurn("s1", "text", { clientId: ME, fetchImpl: r.fetchImpl });
  assert.deepEqual(JSON.parse(r.calls[1][1].body), { prompt: "text", client_id: ME });

  const file = { type: "image/png", name: "shot.png" };
  await uploadImage("s1", file, "my shot.png", { fetchImpl: r.fetchImpl });
  assert.equal(r.calls[2][0], "/api/sessions/s1/images?name=my%20shot.png");
  assert.equal(r.calls[2][1].body, file);
  assert.equal(r.calls[2][1].headers["Content-Type"], "image/png");

  await createIdleSession({ fetchImpl: r.fetchImpl });
  assert.deepEqual(JSON.parse(r.calls[3][1].body), { idle: true });
});

test("a failed prompt of this tab gives its images back as chips", () => {
  const event = { type: "prompt_restored", prompt: "look", images: [REF], origin: { client_id: ME, enqueued_id: "e1" } };
  const action = restoreAction(event, { myId: ME, sentIds: new Set(["e1"]), composerEmpty: true });
  assert.deepEqual(action.images, [REF]);
  assert.deepEqual(restoredChips("s1", action.images), [{ name: "shot.png", ref: REF, src: "/api/sessions/s1/images/0123456789abcdef.png" }]);
  const other = restoreAction({ ...event, origin: { client_id: "tui:1" } }, { myId: ME, sentIds: new Set(), composerEmpty: true });
  assert.equal(other.images, undefined);
});

test("another client's prompt bubble and a joined turn carry their images", () => {
  const known = () => false;
  assert.deepEqual(promptOps({ type: "turn_enqueued", enqueued_id: "e2", client_id: "tui:1", prompt: "look", images: [REF] }, { myId: ME, known })[0].images, [REF]);
  const events = snapshotEvents({
    current_turn: { prompt: "look", origin: {}, images: [REF], parts: [{ kind: "tool", iteration: 1, call_index: 1, tool: "read", status: "ok", images: [REF] }] },
    queued: [{ enqueued_id: "e3", prompt: "next", images: [REF] }],
  });
  assert.deepEqual(events.map((e) => e.images), [[REF], undefined, [REF], [REF]]);
});

test("a tool row keeps the image its tool read", () => {
  const model = newActivity();
  const row = addCompleted(model, { iteration: 1, call_index: 1, tool: "read", output: "[read]\nImage", images: [REF], activity: { status: "ok" } });
  assert.deepEqual(row.images, [REF]);
});
