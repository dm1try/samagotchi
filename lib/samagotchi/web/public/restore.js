// Pure helpers for a failed turn's prompt handed back (prompt_restored):
// what goes back into this tab's composer, and when (a restore that comes
// before its /turn ack waits for it). Split out of turn_events.js.

import { clientLabel, isOwn, withImages } from "./turn_events.js";

// What a prompt_restored (the worker rolled a failed turn back and handed its
// prompt back) does in this tab: `refill` is the text for an empty composer,
// only for a prompt this page sent (`sentIds`, its acks' enqueued_ids), so a
// replay after a reload never refills stale text, with a Verify turn's claim
// (`verify`) so a resend still records a verdict; `own`/`label` mark the
// failed bubble shown again after the resync.
export function restoreAction(event, { myId, sentIds, composerEmpty }) {
  const origin = event?.origin || {};
  const own = isOwn(origin.client_id, myId);
  const sent = own && !!origin.enqueued_id && sentIds.has(origin.enqueued_id);
  // The images go back as chips with the text, and its Verify claim.
  const back = sent && composerEmpty;
  return withImages({
    refill: back ? event.prompt : null,
    own,
    label: own ? null : clientLabel(origin.client_id),
    ...(back && event.verify ? { verify: event.verify } : {}),
    // A Revise turn's draft ({turn_id}): its composer chip comes back.
    ...(back && event.revises?.turn_id ? { revises: { turn_id: event.revises.turn_id } } : {}),
  }, back ? event.images : null);
}

// A turn that fails fast can have its prompt_restored come over the stream
// before the /turn ack names its enqueued_id: `early` (a Map) keeps such a
// restore of this tab's own prompt by that id, and the ack takes it back
// (restoreOnAck), so the prompt goes into the composer the ack would clear.
export function keepEarlyRestore(event, early, { myId, sentIds }) {
  const origin = event?.origin || {};
  const id = origin.enqueued_id;
  if (!isOwn(origin.client_id, myId) || !id || sentIds.has(id)) return false;
  early.set(id, event);
  return true;
}

// The ack's enqueued_id (already in sentIds) was restored early: what the
// composer gets back (as restoreAction for an empty composer), else null.
export function restoreOnAck(enqueuedId, early, { myId, sentIds }) {
  const event = enqueuedId && early.get(enqueuedId);
  if (!event) return null;
  early.delete(enqueuedId);
  return restoreAction(event, { myId, sentIds, composerEmpty: true });
}

// The /turn this kept entry was for failed: no ack comes, so nothing would
// take it back. The whole map goes: this tab sends one turn at a time, so
// every entry waits for an ack that is now never coming (an older one is
// left over from a send that failed the same way).
export function dropEarlyRestores(early) {
  const count = early.size;
  early.clear();
  return count;
}

// The composer's text with a restored prompt put back into it: the restored
// text alone when nothing is typed, else the typed text with the restored
// prompt under it (the user typed between the restore and the ack; their
// text must not be replaced).
export function restoreInto(refill, current) {
  const restored = String(refill ?? "");
  const typed = String(current ?? "");
  if (!restored) return typed;
  if (!typed.trim()) return restored;
  return `${typed.replace(/\n+$/, "")}\n${restored}`;
}

// What the composer holds once a /turn ack lands (4.13): the composer still
// carries the text that was just sent, so that text goes (it is the history's
// now) — but text typed since the send stays, and a prompt restored before
// this ack (restoreOnAck's refill) is put back without replacing it. The
// sent text is trimmed (turnText), so the composer's is too before they are
// compared: a trailing newline or space must not keep the message; and an
// image-only send (placeholders sent) leaves nothing worth keeping.
// @param sent the text the turn was sent with
// @param current the composer's text as the ack lands
// @param refill the prompt an early restore handed back, if any
export function composerAfterAck({ sent = "", current = "", refill = "" } = {}) {
  const typed = String(current ?? "").trim();
  const kept = !typed || typed === String(sent ?? "").trim() ? "" : current;
  return restoreInto(refill, kept);
}
