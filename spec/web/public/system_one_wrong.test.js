import "./dom_shim.js";
import test from "node:test";
import assert from "node:assert/strict";
import { createSystemOneWrongAction } from "../../../lib/samagotchi/web/public/system_one_wrong.js";

function click(button) {
  let stopped = false;
  return {
    event: {
      target: button,
      preventDefault() {},
      stopPropagation() { stopped = true; },
    },
    stopped: () => stopped,
  };
}

test("the should-have-asked action posts the judgment id and marks its row", async () => {
  const row = document.createElement("div");
  row.className = "activity-row";
  const button = document.createElement("button");
  button.className = "system-one-wrong";
  button.dataset.judgmentId = "j1";
  row.append(button);
  let request;
  const handler = createSystemOneWrongAction({
    sessionId: () => "s1",
    mark: async (...args) => { request = args; },
  });
  const { event, stopped } = click(button);

  await handler(event);

  assert.deepEqual(request, ["s1", "j1"]);
  assert.equal(button.textContent, "should have asked");
  assert.equal(button.disabled, true);
  assert.equal(button.getAttribute("aria-pressed"), "true");
  assert.ok(row.classList.contains("guardrail-wrong"));
  assert.ok(stopped());
});

test("a failed request re-enables the button and reports the error", async () => {
  const button = document.createElement("button");
  button.className = "system-one-wrong";
  button.dataset.judgmentId = "j1";
  const errors = [];
  const handler = createSystemOneWrongAction({
    sessionId: () => "s1",
    mark: async () => { throw new Error("worker unavailable"); },
    alert: (message) => errors.push(message),
  });

  await handler(click(button).event);

  assert.equal(button.disabled, false);
  assert.deepEqual(errors, ["Could not mark auto-allow: worker unavailable"]);
});

test("clicks outside a should-have-asked button are ignored", async () => {
  const handler = createSystemOneWrongAction({ sessionId: () => "s1" });

  assert.equal(await handler({ target: document.createElement("div") }), false);
});
