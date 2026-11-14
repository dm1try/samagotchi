import { selectionClaim } from "./claim_link.js";
import { CLAIM_ROOTS } from "./owner_claim.js";
import { authorBadge } from "./participant_names.js";
import { sessionHash } from "./route.js";
import { CHECK_NOT_ON_PAGE, ownerCheckHash } from "./verdict_card.js";
import { freshURL, placeVerdictWithFresh, settleRunning } from "./verdict_fresh.js";
import { VERIFY_UNAVAILABLE, verifyWorkerUnavailable } from "./verify_preset.js";
import { OWNER_FINAL, verifyTurnOf } from "./verify_target.js";

// The owner page's Verify (used by app.js): its verdict cards in the history
// (a live verdict, a session's saved ones), Verify fresh on an unclear
// verdict's card (verdict_fresh.js), Verify's claim from a selection, and
// the composer's armed claim (anchor/set/clear: the one holder; the next
// send makes it a Verify turn).
//
// +historyEl+: #history. +store+: the page's session store (it writes
// current.verdicts and current.verifyFresh through store.update; reads
// selected, sessions, workerFeatures, bridgeUp). +api(path, opts)+: data.js's.
// +claim+: owner_claim.js's (its opts()). +liveTurn+: live_turn.js's (whether
// a turn runs, its id). +toast(text)+: the page's. +win+: the window (a
// verdict's check in another session opens by its hash).
export function createOwnerVerify({ historyEl, store, api, claim, liveTurn, toast, win = globalThis }) {
  // Verify fresh's failed starts, by check (verdict_fresh.js keeps them here).
  const freshErrors = {};
  // The composer's armed Verify claim ({turn_id, quote}) or null: set by the
  // Verify preset, a restored Verify turn's draft; let go by an emptied
  // composer, another session, the send's ack.
  let armed = null;

  function anchor() {
    return armed;
  }

  function set(next) {
    armed = next;
  }

  // clear() lets go of whatever is armed; clear(a) only of +a+ (a send's ack
  // for the claim it took, not one armed since).
  function clear(...only) {
    if (only.length && only[0] !== armed) return;
    armed = null;
  }

  // A verdict ({check_turn_id, verdict, fresh?, by?…}) onto its check's
  // card: into the session's list once, and a fresh one ends its check's
  // "verifying fresh".
  function placeVerdict(record) {
    if (!record) return;
    const known = (store.current.verdicts || []).some((item) => item.check_turn_id === record.check_turn_id);
    const patch = {};
    if (!known) patch.verdicts = [...(store.current.verdicts || []), record];
    // A fresh verdict ends its check's "verifying fresh" (the card shows it).
    if (record.fresh) patch.verifyFresh = settleRunning(store.current.verifyFresh, record);
    store.update({ current: patch });
    const badge = record.by && authorBadge(record.by);
    placeVerdictWithFresh(historyEl, record, {
      who: badge ? badge.name : "You",
      author: record.by || null,
      roots: CLAIM_ROOTS,
      opts: claim.opts(),
      onMissingCheck: (missing) => {
        const hash = ownerCheckHash(store.sessions, store.selected, missing.check_turn_id);
        if (hash) win.location.hash = hash;
        else toast(CHECK_NOT_ON_PAGE);
      },
    }, freshState());
  }

  // The owner's Verify fresh on an unclear verdict's card (verdict_fresh.js):
  // always theirs to start; its running check links to the child's session.
  function freshState() {
    const id = store.selected;
    const unavailable = verifyWorkerUnavailable(store.current.workerFeatures, store.current.bridgeUp);
    return {
      verdicts: store.current.verdicts || [],
      running: store.current.verifyFresh || [],
      errors: freshErrors,
      canStart: !!id && !unavailable,
      unavailableReason: unavailable ? VERIFY_UNAVAILABLE : null,
      start: async (of) => {
        try {
          const body = await api(freshURL(id, of), { method: "POST", body: "{}" });
          return { ok: true, child_id: body.child_id || null };
        } catch (error) {
          return { ok: false, error: error.message };
        }
      },
      childHref: (childId) => sessionHash(childId),
    };
  }

  // The session's saved verdicts, onto the history just drawn.
  function renderSaved() {
    for (const record of store.current.verdicts || []) placeVerdict(record);
  }

  // Verify's claim: a selection in an ended turn's final answer (the only
  // text TurnStages::VerifyAnchors#verified takes; verify_target.js), else null and no
  // Verify on the bar.
  function anchorFor({ source, range }) {
    if (source?.kind !== "answer" || !range) return null;
    const running = liveTurn.running ? { turnId: liveTurn.timing.turnId || null } : null;
    const turnId = verifyTurnOf(historyEl, source.root, OWNER_FINAL, { running });
    const quote = turnId ? selectionClaim(source.root, range, claim.opts()).q : "";
    return turnId && quote ? { turn_id: turnId, quote } : null;
  }

  return { placeVerdict, freshState, renderSaved, anchorFor, anchor, set, clear };
}
