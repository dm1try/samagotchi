import test from "node:test";
import assert from "node:assert/strict";
import { methodApi } from "../../../lib/samagotchi/web/public/method_api.js";
import { onAuthLost } from "../../../lib/samagotchi/web/public/data.js";

const headers = (type) => ({ get: (name) => (name.toLowerCase() === "content-type" ? type : null) });
const res = (status, body = {}, type = "application/json") => ({
  ok: status >= 200 && status < 300, status, statusText: "", redirected: false, type: "basic", headers: headers(type),
  json: async () => body,
});

test("the method, path and JSON body go through the page's api", async () => {
  const seen = [];
  const answer = await methodApi("PATCH", "/api/push/subscriptions/x", { prefs: { done: true } }, {
    fetchImpl: async (path, opts) => { seen.push([path, opts.method, opts.body]); return res(200, { ok: true }); },
  });
  assert.deepEqual(answer, { ok: true });
  assert.deepEqual(seen, [["/api/push/subscriptions/x", "PATCH", JSON.stringify({ prefs: { done: true } })]]);
});

test("no body: none is sent", async () => {
  const seen = [];
  await methodApi("GET", "/api/push", undefined, { fetchImpl: async (path, opts) => { seen.push("body" in opts); return res(200); } });
  assert.deepEqual(seen, [false]);
});

test("a signed-out proxy answer reports auth_lost; a refusal throws the server's words", async () => {
  const lost = [];
  onAuthLost((reason) => lost.push(reason));
  try {
    await assert.rejects(methodApi("GET", "/api/push", undefined, { fetchImpl: async () => res(401) }));
    await assert.rejects(methodApi("DELETE", "/api/push/subscriptions/y", undefined,
                                   { fetchImpl: async () => res(404, { error: "not_found", detail: "no such device" }) }),
                         { message: "no such device", status: 404, code: "not_found" });
    assert.deepEqual(lost, ["401 /api/push"]);
  } finally {
    onAuthLost(null);
  }
});
