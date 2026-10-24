import test from "node:test";
import assert from "node:assert/strict";
import {
  AUTH_LOST_TEXT, AUTH_RELOAD_KEY, AUTH_RELOAD_MS, authProbe, createAuthLost, lostAnswer,
} from "../../../lib/samagotchi/web/public/auth_lost.js";
import { api, onAuthLost } from "../../../lib/samagotchi/web/public/data.js";
import { Window } from "happy-dom";

const headers = (type) => ({ get: (name) => (name.toLowerCase() === "content-type" ? type : null) });
const res = (status, { type = "application/json", redirected = false, kind = "basic", body = {} } = {}) => ({
  ok: status >= 200 && status < 300, status, statusText: "", redirected, type: kind, headers: headers(type),
  json: async () => body,
});

test("lostAnswer: chi's 401, the proxy's 401 {}, a redirect, an HTML sign-in page, an opaque redirect", () => {
  assert.equal(lostAnswer(res(401, { body: { error: "unauthorized" } })), true);
  assert.equal(lostAnswer(res(401)), true);
  assert.equal(lostAnswer(res(200, { redirected: true, type: "text/html" })), true);
  assert.equal(lostAnswer(res(200, { type: "text/html; charset=utf-8" })), true);
  assert.equal(lostAnswer(res(0, { kind: "opaqueredirect", type: "" })), true);
  assert.equal(lostAnswer(res(200)), false);
  assert.equal(lostAnswer(res(403)), false);
  assert.equal(lostAnswer(res(204, { type: "" })), false);
});

test("authProbe asks /api/info as JSON without following a redirect: lost, ok, or down", async () => {
  const calls = [];
  const state = await authProbe(async (path, opts) => { calls.push([path, opts]); return res(0, { kind: "opaqueredirect", type: "" }); });
  assert.equal(state, "lost");
  assert.deepEqual(calls[0][0], "/api/info");
  assert.equal(calls[0][1].redirect, "manual");
  assert.equal(calls[0][1].headers.Accept, "application/json");
  assert.equal(await authProbe(async () => res(200)), "ok");
  assert.equal(await authProbe(async () => { throw new TypeError("Failed to fetch"); }), "down");
});

function page({ stamp = null, throws = false, at = 1_000_000 } = {}) {
  const window = new Window();
  const store = new Map(stamp === null ? [] : [[AUTH_RELOAD_KEY, String(stamp)]]);
  const storage = () => {
    if (throws) throw new Error("blocked");
    return { getItem: (k) => store.get(k) ?? null, setItem: (k, v) => store.set(k, v) };
  };
  const reloads = [];
  const authLost = createAuthLost({ doc: window.document, storage, reload: () => reloads.push(1), now: () => at, log: () => {} });
  return { window, store, reloads, authLost };
}

test("authLost reloads once (the proxy's sign-in brings the user back), stamping the time", () => {
  const { reloads, store, authLost, window } = page();
  authLost("401 /api/sessions");
  authLost("again");
  assert.deepEqual(reloads, [1]);
  assert.equal(store.get(AUTH_RELOAD_KEY), "1000000");
  assert.equal(window.document.getElementById("authLost"), null);
});

test("authLost within a minute of the last reload shows the banner with Reload instead (no reload loop)", () => {
  const { reloads, authLost, window } = page({ stamp: 1_000_000 - AUTH_RELOAD_MS + 1 });
  authLost("events");
  assert.deepEqual(reloads, []);
  const bar = window.document.getElementById("authLost");
  assert.equal(bar.getAttribute("role"), "alert");
  assert.match(bar.textContent, new RegExp(AUTH_LOST_TEXT.replace(/[().]/g, "\\$&")));
  bar.querySelector("button").click();
  assert.deepEqual(reloads, [1]);
});

test("authLost with storage that throws shows the banner, never a reload it can't count (no reload loop)", () => {
  const { reloads, authLost, window } = page({ throws: true });
  authLost("x");
  assert.deepEqual(reloads, []);
  assert.notEqual(window.document.getElementById("authLost"), null);
});

test("api sends Accept: application/json and tells authLost about a 401, a redirect or HTML, not a 404", async () => {
  const lost = [];
  onAuthLost((reason) => lost.push(reason));
  try {
    const seen = [];
    await api("/api/sessions", { fetchImpl: async (path, opts) => { seen.push(opts.headers); return res(200, { body: [] }); } });
    assert.equal(seen[0].Accept, "application/json");
    assert.equal(seen[0]["Content-Type"], "application/json");

    await assert.rejects(api("/api/a", { fetchImpl: async () => res(401) }));
    await assert.rejects(api("/api/b", { fetchImpl: async () => res(401, { body: { error: "unauthorized", detail: "x" } }) }));
    await api("/api/c", { fetchImpl: async () => res(200, { redirected: true, type: "text/html" }) });
    await assert.rejects(api("/api/d", { fetchImpl: async () => res(404, { body: { error: "not_found" } }) }));
    assert.deepEqual(lost, ["401 /api/a", "401 /api/b", "200 /api/c"]);
  } finally {
    onAuthLost(null);
  }
});

test("api's fetch TypeError asks authProbe: a sign-in redirect is authLost, chi web down is not", async () => {
  const lost = [];
  onAuthLost((reason) => lost.push(reason));
  const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
  try {
    const failing = (probe) => async (path) => {
      if (path === "/api/info") return probe();
      throw new TypeError("Failed to fetch");
    };
    await assert.rejects(api("/api/x", { fetchImpl: failing(async () => res(0, { kind: "opaqueredirect", type: "" })) }), TypeError);
    await settle();
    assert.deepEqual(lost, ["fetch /api/x"]);
    await assert.rejects(api("/api/y", { fetchImpl: failing(async () => { throw new TypeError("down"); }) }), TypeError);
    await settle();
    assert.deepEqual(lost, ["fetch /api/x"]);
  } finally {
    onAuthLost(null);
  }
});
