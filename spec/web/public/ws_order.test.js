import test from "node:test";
import assert from "node:assert/strict";
import { heldOrder, recencyOrder } from "../../../lib/samagotchi/web/public/ws_order.js";

const at = (turn, step = 0, row = 0) => ({ turn, step, row });
const item = (key, first, last = undefined, kind = "file") => ({ kind, key, label: key, ops: ["read"], at: first, ...(last ? { last } : {}), count: 1, state: "live" });
const keys = (items) => items.map((i) => i.key);

test("recencyOrder: newest last touch first, by turn, then step, then row; an item without last falls back to its at", () => {
  const items = [
    item("a", at(0, 0), at(2, 1)),
    item("b", at(0, 1)),
    item("c", at(1, 0), at(2, 1, 1)),
    item("d", at(1, 3), at(1, 3)),
    item("e", at(0, 2), at(2, 0, 5)),
  ];
  assert.deepEqual(keys(recencyOrder(items)), ["c", "a", "e", "d", "b"]);
  assert.deepEqual(keys(items), ["a", "b", "c", "d", "e"], "a copy: the list given is not changed");
});

test("recencyOrder: ties keep their order; items with no place (a preloaded memory, a used one) go after the rest, in their order", () => {
  const items = [
    item("p1", null, undefined, "memory"),
    item("x", at(1)),
    item("p2", null, undefined, "memory"),
    item("y", at(1)),
    item("z", at(0)),
  ];
  assert.deepEqual(keys(recencyOrder(items)), ["x", "y", "z", "p1", "p2"]);
  assert.deepEqual(recencyOrder(null), []);
});

test("heldOrder: without the open's keys, recencyOrder", () => {
  const items = [item("a", at(0)), item("b", at(1))];
  assert.deepEqual(keys(heldOrder(items, null)), ["b", "a"]);
  assert.deepEqual(keys(heldOrder(items, undefined)), ["b", "a"]);
});

test("heldOrder: the drawn rows hold their place when touched again; new items land on top, newest first", () => {
  const open = ["file:b", "file:a", "file:c"];
  // a is touched again (now the newest), d and e come.
  const items = [item("a", at(0), at(3)), item("b", at(1)), item("c", null), item("d", at(2)), item("e", at(3, 1))];
  assert.deepEqual(keys(heldOrder(items, open)), ["e", "d", "b", "a", "c"]);
});

test("heldOrder: an item that left the set (a rollback) is simply gone; a key twice in the set's kinds is told apart", () => {
  const open = ["file:b", "memory:a", "file:a"];
  const items = [item("a", at(0)), item("a", at(1), undefined, "memory")];
  assert.deepEqual(heldOrder(items, open).map((i) => `${i.kind}:${i.key}`), ["memory:a", "file:a"]);
  assert.deepEqual(heldOrder([], open), []);
});
