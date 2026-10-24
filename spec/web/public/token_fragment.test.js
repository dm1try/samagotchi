import test from "node:test";
import assert from "node:assert/strict";
import { fragmentCode, tradeFragmentCode } from "../../../lib/samagotchi/web/public/token_fragment.js";

test("fragmentCode: the #code= and the rest of the fragment, null without one (a #token= is no code)", () => {
  assert.deepEqual(fragmentCode("#code=chc_abc&s=123"), { code: "chc_abc", rest: "s=123" });
  assert.deepEqual(fragmentCode("#code=C"), { code: "C", rest: "" });
  assert.equal(fragmentCode("#token=T&s=1"), null);
  assert.equal(fragmentCode("#s=123"), null);
  assert.equal(fragmentCode(""), null);
  assert.equal(fragmentCode(undefined), null);
});

function fakes(answer) {
  const calls = [];
  const replaced = [];
  const reloads = [];
  const loc = { hash: "#code=chc_abc&s=123", pathname: "/", search: "?dir=/r", reload: () => reloads.push(1) };
  const hist = { replaceState: (_s, _t, url) => replaced.push(url) };
  const fetchImpl = async (path, opts) => { calls.push([path, opts]); return answer(); };
  return { calls, replaced, reloads, loc, hist, fetchImpl };
}

test("trades the fragment's code: the URL loses it first, POST /api/token as same-origin JSON, then a reload", async () => {
  const f = fakes(() => ({ ok: true, status: 204, json: async () => ({}) }));
  assert.equal(await tradeFragmentCode(f), true);
  assert.deepEqual(f.replaced, ["/?dir=/r#s=123"]);
  assert.equal(f.calls[0][0], "/api/token");
  assert.equal(f.calls[0][1].method, "POST");
  assert.equal(f.calls[0][1].credentials, "same-origin");
  assert.deepEqual(JSON.parse(f.calls[0][1].body), { code: "chc_abc" });
  assert.deepEqual(f.reloads, [1]);
});

test("a refused code says the server's words and doesn't reload", async () => {
  const f = fakes(() => ({ ok: false, status: 401, json: async () => ({ error: "unauthorized", detail: "no" }) }));
  const words = [];
  assert.equal(await tradeFragmentCode({ ...f, onRefused: (w) => words.push(w) }), false);
  assert.deepEqual(words, ["no"]);
  assert.deepEqual(f.reloads, []);
  assert.deepEqual(f.replaced, ["/?dir=/r#s=123"]);
});

test("nothing to trade without a #code=", async () => {
  const f = fakes(() => { throw new Error("no fetch"); });
  f.loc.hash = "#/s/abc";
  assert.equal(await tradeFragmentCode(f), false);
  assert.deepEqual(f.calls, []);
  assert.deepEqual(f.replaced, []);
});
