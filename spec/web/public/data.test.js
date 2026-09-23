import test from "node:test";
import assert from "node:assert/strict";
import {
  api,
  listSessions,
  createSession,
  getSession,
  sendTurn,
  cancelTurn,
  stopSession,
  deleteSession,
  dismissQuestion,
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

test("createSession posts a JSON prompt", async () => {
  const calls = [];
  await createSession("hello", {
    fetchImpl: (path, opts) => {
      calls.push([path, opts.method, opts.body]);
      return Promise.resolve(okResponse({ id: "new" }));
    },
  });
  assert.deepEqual(calls[0], ["/api/sessions", "POST", JSON.stringify({ prompt: "hello" })]);
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
