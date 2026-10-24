import test from "node:test";
import assert from "node:assert/strict";
import { isQuestionTag, openPushKeys, pushSupported, subscribe, unsubscribe, urlBase64ToBytes } from "../../../lib/samagotchi/web/public/push.js";

function PushManager() {}
const standaloneMedia = (matches) => () => ({ matches });

test("push only in a standalone app with a service worker and PushManager on a secure context", () => {
  const win = { isSecureContext: true, PushManager, matchMedia: standaloneMedia(true) };
  const nav = { serviceWorker: {} };
  assert.equal(pushSupported({ win, nav }), true);
  // iOS's own flag, without the media query.
  assert.equal(pushSupported({ win: { ...win, matchMedia: standaloneMedia(false) }, nav: { ...nav, standalone: true } }), true);
  // A browser tab: the in-tab notifications instead.
  assert.equal(pushSupported({ win: { ...win, matchMedia: standaloneMedia(false) }, nav }), false);
  // The LAN's plain http, no service worker, no PushManager, nothing at all.
  assert.equal(pushSupported({ win: { ...win, isSecureContext: false }, nav }), false);
  assert.equal(pushSupported({ win, nav: {} }), false);
  assert.equal(pushSupported({ win: { ...win, PushManager: undefined }, nav }), false);
  assert.equal(pushSupported({ win: undefined, nav: undefined }), false);
  // A matchMedia that throws is no standalone app.
  assert.equal(pushSupported({ win: { ...win, matchMedia: () => { throw new Error("x"); } }, nav }), false);
});

test("urlBase64ToBytes reads base64url with or without padding", () => {
  assert.deepEqual([...urlBase64ToBytes("_-8")], [0xff, 0xef]);
  assert.deepEqual([...urlBase64ToBytes("YQ==")], [0x61]);
  assert.deepEqual([...urlBase64ToBytes("YQ")], [0x61]);
});

function fakeReg(existing = null) {
  const calls = [];
  const sub = (key, endpoint = "https://web.push.apple.com/new") => ({
    endpoint,
    options: { applicationServerKey: key && key.buffer },
    unsubscribe: async () => { calls.push(["unsubscribe", endpoint]); return true; },
    toJSON: () => ({ endpoint, keys: { p256dh: "P", auth: "A" } }),
  });
  let current = existing && sub(existing.key, existing.endpoint);
  const reg = {
    pushManager: {
      getSubscription: async () => current,
      subscribe: async (opts) => {
        calls.push(["subscribe", opts.userVisibleOnly, [...opts.applicationServerKey]]);
        current = sub(opts.applicationServerKey);
        return current;
      },
    },
  };
  return { reg, calls };
}

test("subscribe makes a subscription with chi web's key and posts its JSON", async () => {
  const { reg, calls } = fakeReg();
  const posted = [];
  const { answer } = await subscribe({ reg, key: "AQID", post: async (json) => { posted.push(json); return { id: "abcd1234" }; } });
  assert.deepEqual(calls, [["subscribe", true, [1, 2, 3]]]);
  assert.deepEqual(posted, [{ endpoint: "https://web.push.apple.com/new", keys: { p256dh: "P", auth: "A" } }]);
  assert.deepEqual(answer, { id: "abcd1234" });
});

test("subscribe keeps a subscription made with the same key, and replaces one made with another", async () => {
  const same = fakeReg({ key: new Uint8Array([1, 2, 3]), endpoint: "https://web.push.apple.com/kept" });
  const posted = [];
  await subscribe({ reg: same.reg, key: "AQID", post: async (json) => posted.push(json.endpoint) });
  assert.deepEqual(same.calls, []);
  assert.deepEqual(posted, ["https://web.push.apple.com/kept"]);

  const other = fakeReg({ key: new Uint8Array([9, 9, 9]), endpoint: "https://web.push.apple.com/old" });
  await subscribe({ reg: other.reg, key: "AQID", post: async () => ({}) });
  assert.deepEqual(other.calls, [["unsubscribe", "https://web.push.apple.com/old"], ["subscribe", true, [1, 2, 3]]]);
});

test("unsubscribe drops this device's subscription and tells chi web its endpoint", async () => {
  const { reg, calls } = fakeReg({ key: new Uint8Array([1]), endpoint: "https://web.push.apple.com/e" });
  const deleted = [];
  assert.equal(await unsubscribe({ reg, del: async (endpoint) => deleted.push(endpoint) }), true);
  assert.deepEqual(calls, [["unsubscribe", "https://web.push.apple.com/e"]]);
  assert.deepEqual(deleted, ["https://web.push.apple.com/e"]);
  assert.equal(await unsubscribe({ reg: fakeReg().reg, del: async () => assert.fail("nothing to delete") }), false);
});

test("openPushKeys: every pending approval or question (a hook's too), not a relayed one, a continue or none", () => {
  const byId = {
    a: { id: "a", pending_question: { id: "q1", kind: "approval" } },
    h: { id: "h", pending_question: { id: "h1", kind: "hook" } },
    r: { id: "r", pending_question: { id: "q2", kind: "approval", relayed_to: "p1234567" } },
    c: { id: "c", pending_question: { id: "c1", kind: "continue" } },
    n: { id: "n", pending_question: null },
    x: { id: "x", pending_question: { kind: "question" } },
  };
  assert.deepEqual(openPushKeys(byId), ["a:q1", "h:h1"]);
  assert.deepEqual(openPushKeys(undefined), []);
});

test("isQuestionTag: a pushed question's tag, never chi's own or a card's", () => {
  assert.equal(isQuestionTag("0b1c-uuid:9f2e-uuid"), true);
  assert.equal(isQuestionTag("chi:test"), false);
  assert.equal(isQuestionTag("chi:other"), false);
  assert.equal(isQuestionTag("s1:card:c1"), false);
  assert.equal(isQuestionTag(""), false);
  assert.equal(isQuestionTag(undefined), false);
});
