// Apply (the owner's page): under a participant's review turn's reply, a
// button that puts the owner's Apply turn in the composer: one line of the
// owner's and the proposal quoted (GET …/apply, ReviewApply on the server),
// never sent by itself. The owner reads it, edits it, sends it or not.
import { html } from "./vendor/lit-html.js";

// The row under a review turn's reply: +badge+ is authorBadge's
// ({author, name, color}).
export function applyRowTemplate(turnId, badge) {
  return html`<div class="review-apply" data-apply-turn=${turnId} style=${`--author-color:${badge.color}`}><button
    type="button" class="review-apply-btn" data-apply-turn=${turnId}
    title=${`Put an Apply turn in the composer: ${badge.name}'s proposal, quoted. You read it before you send it.`}>Apply</button
    ><span class="review-apply-note">${badge.name}'s proposal, quoted in your composer; you send it</span></div>`;
}

// The composer with the Apply turn: after what is typed there already.
export function applyComposerText(current, composed) {
  const typed = String(current || "").trimEnd();
  return typed ? `${typed}\n\n${composed}` : composed;
}

export function applyURL(sessionId, turnId) {
  return `/api/sessions/${encodeURIComponent(sessionId)}/apply?turn=${encodeURIComponent(turnId)}`;
}

// The Apply turn's text for review turn +turnId+, or an Error with the
// server's words.
export async function fetchApply(sessionId, turnId, fetchImpl = fetch) {
  const res = await fetchImpl(applyURL(sessionId, turnId), { credentials: "same-origin" });
  let json = null;
  try { json = await res.json(); } catch { json = null; }
  if (!res.ok || typeof json?.text !== "string") throw new Error(json?.detail || `Apply failed (HTTP ${res.status})`);
  return json.text;
}
