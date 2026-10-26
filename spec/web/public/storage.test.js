import test from "node:test";
import assert from "node:assert/strict";
import { readStored, removeStored, storedKeys, writeStored } from "../../../lib/samagotchi/web/public/storage.js";

// A Map-backed stand-in, installed for one test and put back after it
// (npm test shares one globalThis across the files).
function withStorage(storage, fn) {
  const before = Object.getOwnPropertyDescriptor(globalThis, "localStorage");
  Object.defineProperty(globalThis, "localStorage", { value: storage, configurable: true, writable: true });
  try {
    fn();
  } finally {
    if (before) Object.defineProperty(globalThis, "localStorage", before);
    else delete globalThis.localStorage;
  }
}

function mapStorage() {
  const map = new Map();
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
    get length() { return map.size; },
    key: (i) => [...map.keys()][i] ?? null,
  };
}

test("readStored / writeStored / removeStored: the stored string, else the fallback", () => {
  withStorage(mapStorage(), () => {
    assert.equal(readStored("k"), null);
    assert.equal(readStored("k", "[]"), "[]");
    writeStored("k", "1");
    assert.equal(readStored("k", "0"), "1");
    removeStored("k");
    assert.equal(readStored("k", "0"), "0");
  });
});

test("storage that throws: reads give the fallback, writes and removes do nothing", () => {
  const boom = () => { throw new Error("SecurityError"); };
  withStorage({ getItem: boom, setItem: boom, removeItem: boom }, () => {
    assert.equal(readStored("k"), null);
    assert.equal(readStored("k", "x"), "x");
    assert.doesNotThrow(() => writeStored("k", "1"));
    assert.doesNotThrow(() => removeStored("k"));
  });
});

test("no storage at all: the fallback", () => {
  withStorage(undefined, () => {
    assert.equal(readStored("k", "x"), "x");
    assert.doesNotThrow(() => writeStored("k", "1"));
  });
});

test("storedKeys: the keys with a prefix, a copy safe to remove from; [] when storage throws or is missing", () => {
  withStorage(mapStorage(), () => {
    writeStored("a:1", "x");
    writeStored("a:2", "y");
    writeStored("b:1", "z");
    const keys = storedKeys("a:");
    assert.deepEqual(keys, ["a:1", "a:2"]);
    keys.forEach(removeStored);
    assert.deepEqual(storedKeys(""), ["b:1"]);
  });
  const boom = () => { throw new Error("SecurityError"); };
  withStorage({ get length() { return boom(); }, key: boom }, () => assert.deepEqual(storedKeys("a:"), []));
  withStorage(undefined, () => assert.deepEqual(storedKeys("a:"), []));
});
