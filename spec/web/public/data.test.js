import test from "node:test";
import assert from "node:assert/strict";
import {
  api,
  listSessions,
  createIdleSession,
  getSession,
  sendTurn,
  cancelTurn,
  stopSession,
  stopTask,
  deleteSession,
  archiveSession,
  unarchiveSession,
  dismissQuestion,
  listModels,
  fetchHistory,
} from "../../../lib/samagotchi/web/public/data.js";

function okResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    statusText: "OK",
    json: async () => body,
  };
}

test("api wraps fetch and handles JSON responses", async () => {
  const body = { session: { id: "x" } };
  const calls = [];
  const result = await api("/api/sessions/1", {
    fetchImpl: (path, opts) => {
      calls.push([path, opts]);
      return Promise.resolve(okResponse(body));
    },
  });
  assert.ok(result.session.id === "x");
  assert.deepEqual(calls[0][0], "/api/sessions/1");
  assert.equal(calls[0][1].headers["Content-Type"], "application/json");
});

test("api raises on non-ok status", async () => {
  const body = { detail: "not_live" };
  await assert.rejects(
    () =>
      api("/api/sessions/1/stream", {
        fetchImpl: () => Promise.resolve(okResponse(body, 503)),
      }),
    /not_live \(503\)/,
  );
});

test("api errors carry the HTTP status (a 404 means the session is gone)", async () => {
  await assert.rejects(
    () => api("/api/sessions/nope", { fetchImpl: () => Promise.resolve(okResponse({ error: "not_found" }, 404)) }),
    (e) => e.status === 404 && /not_found \(404\)/.test(e.message),
  );
});

// The page matches on the code, never on the message's words: a turn's
// refused images are bad_images (not the upload's bad_image).
test("api errors carry the server's error code", async () => {
  const fail = (body, status) => api("/api/sessions/1/turn", { fetchImpl: () => Promise.resolve(okResponse(body, status)) });
  await assert.rejects(() => fail({ error: "bad_images", detail: "unknown image ref" }, 400),
    (e) => e.code === "bad_images" && e.status === 400 && e.message === "unknown image ref (400)");
  await assert.rejects(() => fail({ error: "owned_by_tui", detail: "open in a chi REPL" }, 409), (e) => e.code === "owned_by_tui");
  await assert.rejects(() => fail({}, 500), (e) => e.code === null);
});

test("listSessions builds sort and order query params", async () => {
  const calls = [];
  await listSessions("updated_at", "desc", {
    fetchImpl: (path) => {
      calls.push(String(path));
      return Promise.resolve(okResponse([]));
    },
  });
  assert.equal(calls[0], "/api/sessions?sort=updated_at&order=desc");
});

test("listSessions adds the scope folder only when there is one, never to fetch's options", async () => {
  const calls = [];
  await listSessions("updated_at", "desc", {
    dir: "/Users/me/my proj",
    fetchImpl: (path, opts) => {
      calls.push([String(path), "dir" in opts]);
      return Promise.resolve(okResponse([]));
    },
  });
  assert.deepEqual(calls[0], ["/api/sessions?sort=updated_at&order=desc&dir=%2FUsers%2Fme%2Fmy%20proj", false]);
});

test("createIdleSession sends the folder in the body when given", async () => {
  const bodies = [];
  const fetchImpl = (_path, opts) => {
    bodies.push(JSON.parse(opts.body));
    return Promise.resolve(okResponse({ id: "new" }));
  };
  await createIdleSession({ dir: "/r", fetchImpl });
  await createIdleSession({ fetchImpl });
  assert.deepEqual(bodies, [{ idle: true, dir: "/r" }, { idle: true }]);
});

test("createIdleSession sends the model and the preview in the body when given, not when blank", async () => {
  const bodies = [];
  const fetchImpl = (_path, opts) => {
    bodies.push(JSON.parse(opts.body));
    return Promise.resolve(okResponse({ id: "new" }));
  };
  await createIdleSession({ model: "box:gemma", preview: "hi", fetchImpl });
  await createIdleSession({ model: "", preview: "", fetchImpl });
  assert.deepEqual(bodies, [{ idle: true, model: "box:gemma", preview: "hi" }, { idle: true }]);
});

test("listModels reads /api/models", async () => {
  const calls = [];
  const payload = { default: "a", models: [{ name: "a", host: "default", id: "a" }] };
  const got = await listModels({
    fetchImpl: (path) => {
      calls.push(String(path));
      return Promise.resolve(okResponse(payload));
    },
  });
  assert.deepEqual(calls, ["/api/models"]);
  assert.deepEqual(got, payload);
});

test("getSession hits the detail route", async () => {
  const calls = [];
  await getSession("abc", {
    fetchImpl: (path) => {
      calls.push(String(path));
      return Promise.resolve(okResponse({ session: { id: "abc" } }));
    },
  });
  assert.equal(calls[0], "/api/sessions/abc");
});

test("getSession({ tail: true }) asks for the lighter end-of-turn answer, never passing tail to fetch", async () => {
  const calls = [];
  await getSession("abc", {
    tail: true,
    fetchImpl: (path, opts) => {
      calls.push([String(path), "tail" in opts]);
      return Promise.resolve(okResponse({ session: { id: "abc" } }));
    },
  });
  assert.deepEqual(calls[0], ["/api/sessions/abc?tail=1", false]);
});

test("getSession({ parts: true }) asks for what each saved step did (the turn view's reload), never passing parts to fetch", async () => {
  const calls = [];
  const fetchImpl = (path, opts) => {
    calls.push([String(path), "parts" in opts]);
    return Promise.resolve(okResponse({ session: { id: "abc" } }));
  };
  await getSession("abc", { parts: true, fetchImpl });
  await getSession("abc", { parts: false, fetchImpl });
  assert.deepEqual(calls, [["/api/sessions/abc?parts=1", false], ["/api/sessions/abc", false]]);
});

test("getSession({ cards: true }) asks for the cards alone (their rendered bodies)", async () => {
  const calls = [];
  const fetchImpl = (path, opts) => {
    calls.push([String(path), "cards" in opts]);
    return Promise.resolve(okResponse({ cards: [] }));
  };
  await getSession("abc", { cards: true, fetchImpl });
  assert.deepEqual(calls, [["/api/sessions/abc?cards=1", false]]);
});

test("getSession({ tail, recent, turnId }) asks for the newest turn's timing and that turn's answer, never passing them to fetch", async () => {
  const calls = [];
  const fetchImpl = (path, opts) => {
    calls.push([String(path), ["tail", "recent", "turnId", "timing"].some((k) => k in opts)]);
    return Promise.resolve(okResponse({ session: { id: "abc" } }));
  };
  await getSession("abc", { tail: true, recent: true, fetchImpl });
  await getSession("abc", { tail: true, recent: true, turnId: "t 1/2", fetchImpl });
  await getSession("abc", { tail: true, turnId: "", fetchImpl });
  // Only with tail: a full read ignores them.
  await getSession("abc", { recent: true, turnId: "t1", fetchImpl });
  assert.deepEqual(calls, [
    ["/api/sessions/abc?tail=1&recent=1", false],
    ["/api/sessions/abc?tail=1&recent=1&turn_id=t%201%2F2", false],
    ["/api/sessions/abc?tail=1", false],
    ["/api/sessions/abc", false],
  ]);
});

test("getSession({ timing: true }) asks for the whole timing alone, never passing timing to fetch", async () => {
  const calls = [];
  const fetchImpl = (path, opts) => {
    calls.push([String(path), "timing" in opts]);
    return Promise.resolve(okResponse({ timing: {} }));
  };
  await getSession("abc", { timing: true, fetchImpl });
  assert.deepEqual(calls, [["/api/sessions/abc?timing=1", false]]);
});

test("sendTurn posts the prompt to the turn route", async () => {
  const calls = [];
  await sendTurn("abc", "prompt text", {
    fetchImpl: (path, opts) => {
      calls.push([path, opts.method, opts.body]);
      return Promise.resolve(okResponse({}));
    },
  });
  assert.deepEqual(calls[0], [
    "/api/sessions/abc/turn",
    "POST",
    JSON.stringify({ prompt: "prompt text" }),
  ]);
});

test("sendTurn sends the tab's client_id when given", async () => {
  const calls = [];
  await sendTurn("abc", "hi", {
    clientId: "web:tab1",
    fetchImpl: (path, opts) => {
      calls.push(opts);
      return Promise.resolve(okResponse({}));
    },
  });
  assert.deepEqual(JSON.parse(calls[0].body), { prompt: "hi", client_id: "web:tab1" });
  assert.equal(calls[0].clientId, undefined);
});

test("sendTurn keeps an image-only send out of the history (history: false)", async () => {
  const calls = [];
  const fetchImpl = (path, opts) => {
    calls.push(JSON.parse(opts.body));
    return Promise.resolve(okResponse({}));
  };
  await sendTurn("abc", "[image: cat.png]", { history: false, fetchImpl });
  await sendTurn("abc", "typed", { history: true, fetchImpl });
  assert.deepEqual(calls, [{ prompt: "[image: cat.png]", history: false }, { prompt: "typed" }]);
});

test("fetchHistory gets the shared prompt history's entries", async () => {
  const calls = [];
  const entries = await fetchHistory({
    fetchImpl: (path, opts) => {
      calls.push([path, opts.method]);
      return Promise.resolve(okResponse({ entries: ["one", "two"] }));
    },
  });
  assert.deepEqual(entries, ["one", "two"]);
  assert.deepEqual(calls, [["/api/history", undefined]]);
});

test("dismissQuestion posts the question id to the dismiss route", async () => {
  const calls = [];
  await dismissQuestion("abc", "q1", {
    fetchImpl: (path, opts) => {
      calls.push([path, opts.method, opts.body]);
      return Promise.resolve(okResponse({ status: "dismissed" }));
    },
  });
  assert.deepEqual(calls[0], [
    "/api/sessions/abc/question/dismiss",
    "POST",
    JSON.stringify({ id: "q1" }),
  ]);
});

test("cancelTurn posts a user reason", async () => {
  const calls = [];
  await cancelTurn("abc", {
    fetchImpl: (path, opts) => {
      calls.push([path, opts.method, opts.body]);
      return Promise.resolve(okResponse({}));
    },
  });
  assert.deepEqual(calls[0], [
    "/api/sessions/abc/cancel",
    "POST",
    JSON.stringify({ reason: "user" }),
  ]);
});

test("stopTask posts to the task's stop route", async () => {
  const calls = [];
  await stopTask("abc", "20261004120000-0a1b2c3d", {
    fetchImpl: (path, opts) => {
      calls.push([path, opts.method, opts.body]);
      return Promise.resolve(okResponse({}));
    },
  });
  assert.deepEqual(calls[0], ["/api/sessions/abc/tasks/20261004120000-0a1b2c3d/stop", "POST", "{}"]);
});

test("stopSession posts to the stop route", async () => {
  const calls = [];
  await stopSession("abc", {
    fetchImpl: (path, opts) => {
      calls.push([path, opts.method, opts.body]);
      return Promise.resolve(okResponse({}));
    },
  });
  assert.deepEqual(calls[0], ["/api/sessions/abc/stop", "POST", "{}"]);
});
import { sendCommand } from "../../../lib/samagotchi/web/public/data.js";

test("sendCommand posts a session command line with this tab's id", async () => {
  const calls = [];
  await sendCommand("abc", "/model x", {
    clientId: "web:me",
    fetchImpl: (path, opts) => {
      calls.push([path, opts.method, opts.body]);
      return Promise.resolve(okResponse({ command_id: "c1" }));
    },
  });
  assert.deepEqual(calls[0], ["/api/sessions/abc/command", "POST", JSON.stringify({ line: "/model x", client_id: "web:me" })]);
});

test("deleteSession sends DELETE to the session's URL", async () => {
  const calls = [];
  const result = await deleteSession("3fa2 b", {
    fetchImpl: (path, opts) => {
      calls.push([path, opts.method]);
      return Promise.resolve(okResponse({ status: "deleted", session_id: "3fa2 b", stopped: false }));
    },
  });
  assert.deepEqual(calls, [["/api/sessions/3fa2%20b", "DELETE"]]);
  assert.equal(result.status, "deleted");
});

test("archiveSession and unarchiveSession POST to the session's archive routes", async () => {
  const calls = [];
  const fetchImpl = (path, opts) => {
    calls.push([path, opts.method]);
    return Promise.resolve(okResponse({ status: "ok" }));
  };
  await archiveSession("3fa2", { fetchImpl });
  await unarchiveSession("3fa2", { fetchImpl });
  assert.deepEqual(calls, [["/api/sessions/3fa2/archive", "POST"], ["/api/sessions/3fa2/unarchive", "POST"]]);
});
