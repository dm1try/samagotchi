import test from "node:test";
import assert from "node:assert/strict";
import { modelNames, pickModel, MODEL_KEY } from "../../../lib/samagotchi/web/public/model_pick.js";

const payload = {
  default: "Gemma-4B-it",
  models: [
    { name: "Gemma-4B-it", host: "default", id: "Gemma-4B-it" },
    { name: "Qwen3-14B", host: "default", id: "Qwen3-14B" },
    { name: "box:gemma4-26b", host: "box", id: "gemma4-26b" },
  ],
};

test("modelNames keeps the server's order and spelling, and copes with a bad payload", () => {
  assert.deepEqual(modelNames(payload), ["Gemma-4B-it", "Qwen3-14B", "box:gemma4-26b"]);
  assert.deepEqual(modelNames({}), []);
  assert.deepEqual(modelNames(null), []);
  assert.deepEqual(modelNames({ models: [{ name: "" }, { id: "x" }, { name: "a" }] }), ["a"]);
});

test("pickModel prefers the remembered choice while it is offered, else the default", () => {
  const names = modelNames(payload);
  assert.equal(pickModel(names, "Gemma-4B-it", "box:gemma4-26b"), "box:gemma4-26b");
  assert.equal(pickModel(names, "Gemma-4B-it", "BOX:GEMMA4-26B"), "box:gemma4-26b");
  assert.equal(pickModel(names, "Gemma-4B-it", "gone:model"), "Gemma-4B-it");
  assert.equal(pickModel(names, "Gemma-4B-it", null), "Gemma-4B-it");
  assert.equal(pickModel(names, "Gemma-4B-it", ""), "Gemma-4B-it");
});

test("pickModel falls back to the default even when no host lists it, then to the first name", () => {
  assert.equal(pickModel(["a", "b"], "zzz", null), "zzz");
  assert.equal(pickModel(["a", "b"], null, null), "a");
  assert.equal(pickModel([], null, "x"), "");
});

test("the storage key is stable", () => {
  assert.equal(MODEL_KEY, "chi_model");
});
