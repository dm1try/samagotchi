import test from "node:test";
import assert from "node:assert/strict";
import { fragmentToken, tradeFragmentToken } from "../../../lib/samagotchi/web/public/token_fragment.js";

test("fragmentToken: the #token= and the rest of the fragment, null without one", () => {
  assert.deepEqual(fragmentToken("#token=chp_abc&s=123"), { token: "chp_abc", rest: "s=123" });
  assert.deepEqual(fragmentToken("#token=T"), { token: "T", rest: "" });
  assert.equal(fragmentToken("#s=123"), null);
  assert.equal(fragmentToken(""), null);
  assert.equal(fragmentToken(undefined), null);
});

function fakes(answer) {
  const calls = [];
  const replaced = [];
  const reloads = [];
  const loc = { hash: "#token=chp_abc&s=123", pathname: "/", search: "?dir=/r", reload: () => reloads.push(1) };
  const hist = { replaceState: (_s, _t, url) => replaced.push(url) };
  const fetchImpl = async (path, opts) => { calls.push([path, opts]); return answer(); };
  return { calls, replaced, reloads, loc, hist, fetchImpl };
}

test("trades the fragment's token: the URL loses it first, POST /api/token as same-origin JSON, then a reload", async () => {
  const f = fakes(() => ({ ok: true, status: 204, json: async () => ({}) }));
  assert.equal(await tradeFragmentToken(f), true);
  assert.deepEqual(f.replaced, ["/?dir=/r#s=123"]);
  assert.equal(f.calls[0][0], "/api/token");
  assert.equal(f.calls[0][1].method, "POST");
  assert.equal(f.calls[0][1].credentials, "same-origin");
  assert.deepEqual(JSON.parse(f.calls[0][1].body), { token: "chp_abc" });
  assert.deepEqual(f.reloads, [1]);
});

test("a refused token says the server's words and doesn't reload", async () => {
  const f = fakes(() => ({ ok: false, status: 401, json: async () => ({ error: "token_expired", detail: "This link expired" }) }));
  const words = [];
  assert.equal(await tradeFragmentToken({ ...f, onRefused: (w) => words.push(w) }), false);
  assert.deepEqual(words, ["This link expired"]);
  assert.deepEqual(f.reloads, []);
  assert.deepEqual(f.replaced, ["/?dir=/r#s=123"]);
});

test("nothing to trade without a #token=", async () => {
  const f = fakes(() => { throw new Error("no fetch"); });
  f.loc.hash = "#/s/abc";
  assert.equal(await tradeFragmentToken(f), false);
  assert.deepEqual(f.calls, []);
  assert.deepEqual(f.replaced, []);
});
