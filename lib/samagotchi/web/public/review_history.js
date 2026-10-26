// A participant's ↑/↓ in the comment box (participant.js over
// prompt_history.js): their own comments sent from this browser, newest
// last, in localStorage under one key per grant, never the owner's GET
// /api/history (the owner may open a link in the same browser, on the same
// origin: each grant's list and the owner's stay apart). Read and written
// through storage.js (guarded): a list that can't be read or written is just
// not there. A link that ends forgets its list.
import { readStored, removeStored, writeStored } from "./storage.js";

export const REVIEW_HISTORY_PREFIX = "chi_review_history:";
// How many comments a grant's list keeps (the oldest go first).
export const REVIEW_HISTORY_MAX = 50;

// The key for grant +grantId+'s list; null without one (an older server's
// review data): no history then.
export function reviewHistoryKey(grantId) {
  return grantId ? `${REVIEW_HISTORY_PREFIX}${grantId}` : null;
}

// The grant's comments, oldest first; [] when there are none or they can't
// be read.
export function readReviewHistory(grantId) {
  const key = reviewHistoryKey(grantId);
  if (!key) return [];
  try {
    const list = JSON.parse(readStored(key, "[]"));
    return Array.isArray(list) ? list.filter((entry) => typeof entry === "string") : [];
  } catch (_) {
    return [];
  }
}

// The list with +text+ added at the end (not twice in a row), at most
// REVIEW_HISTORY_MAX long. Pure.
export function withComment(list, text) {
  const entry = String(text || "").trim();
  if (!entry) return list;
  const next = list.at(-1) === entry ? list : [...list, entry];
  return next.slice(-REVIEW_HISTORY_MAX);
}

// A comment the server took: saved at the end of the grant's list.
export function recordReviewComment(grantId, text) {
  const key = reviewHistoryKey(grantId);
  if (!key) return;
  writeStored(key, JSON.stringify(withComment(readReviewHistory(grantId), text)));
}

export function forgetReviewHistory(grantId) {
  const key = reviewHistoryKey(grantId);
  if (key) removeStored(key);
}
