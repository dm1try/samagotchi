// The page's per-browser choices in localStorage, guarded: storage can be
// missing or throw (a private window, blocked site data, a full quota), and
// a choice that can't be read or written is just not remembered. Reads
// globalThis.localStorage at each call, never at import (the specs install
// their own).

// The same guards on sessionStorage: this tab only, so a reload or a resync
// of it keeps what is written, and another tab or device never sees it.
// Reads globalThis.sessionStorage at each call (the specs install their own).

// The stored string, or +fallback+ when there is none or it can't be read.
export function readSession(key, fallback = null) {
  try {
    const value = globalThis.sessionStorage?.getItem(key);
    return value == null ? fallback : value;
  } catch (_) {
    return fallback;
  }
}

export function writeSession(key, value) {
  try { globalThis.sessionStorage?.setItem(key, value); } catch (_) {}
}

export function removeSession(key) {
  try { globalThis.sessionStorage?.removeItem(key); } catch (_) {}
}

// The stored string, or +fallback+ when there is none or it can't be read.
export function readStored(key, fallback = null) {
  try {
    const value = globalThis.localStorage.getItem(key);
    return value === null ? fallback : value;
  } catch (_) {
    return fallback;
  }
}

export function writeStored(key, value) {
  try { globalThis.localStorage.setItem(key, value); } catch (_) {}
}

export function removeStored(key) {
  try { globalThis.localStorage.removeItem(key); } catch (_) {}
}

// The stored keys that start with +prefix+ ([] when they can't be read), a
// copy: removing one while walking them is safe.
export function storedKeys(prefix) {
  try {
    const storage = globalThis.localStorage;
    const keys = [];
    for (let i = 0; i < storage.length; i++) {
      const key = storage.key(i);
      if (typeof key === "string" && key.startsWith(prefix)) keys.push(key);
    }
    return keys;
  } catch (_) {
    return [];
  }
}
