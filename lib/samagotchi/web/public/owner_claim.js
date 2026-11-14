import { ownerClaimHash, participantClaimLink, selectionClaim, showClaim, turnIdOf } from "./claim_link.js";
import { sessionHash } from "./route.js";

// Where a claim's text can be on the owner's page: answers, own messages, steps.
export const CLAIM_ROOTS = ".bubble.output, .bubble.user .user-message, .gen-text";

// The owner page's claim links (used by app.js; claim_link.js does the text
// and DOM work): a claim link opened on this page (#/s/<id>?t=…&q=…, or the
// participant's #s=<id>&t=… opened in this browser) shown once its session is
// drawn, and annotate's "Copy link" for a selection. A participant's page has
// its own copies on purpose (docs/internals/web-frontend.md, Two pages).
//
// +historyEl+: #history. +store+: the page's session store (selected,
// current.dir, sessions; read only). +claimTarget()+: participants_panel.js's
// (the people a link would open for, or null). +toast(text, action,
// options)+, +copyText(text)+ (copy.js), +allViewOpen()+: the page's.
// +home+: the home folder the page shows as ~ (body data-home). +win+: the
// window (location, history).
export function createOwnerClaim({
  historyEl, store, claimTarget, toast, copyText, allViewOpen, home = "", win = globalThis,
}) {
  // A claim link waiting for its session to be drawn (selectFromHash sets it).
  let pendingClaim = null;

  // How a participant's page shows this page's text (claim_link.js).
  function opts() {
    return { home, cwd: store.current.dir || "" };
  }

  function pending(claim) {
    pendingClaim = claim;
  }

  // The claim link's quote scrolled to and marked, its text read as the
  // participant page shows it (the session's folder relative, home ~); a
  // quote not found marks its turn; neither found: the top, and a toast.
  // The hash is the session's again (select() already set it when it
  // switched), so the same link opened again is a hashchange.
  function showPending() {
    const claim = pendingClaim;
    if (!claim || claim.sessionId !== store.selected) return;
    pendingClaim = null;
    const { location, history } = win;
    if (!allViewOpen() && location.hash !== sessionHash(store.selected)) {
      history.replaceState(null, "", location.pathname + location.search + sessionHash(store.selected));
    }
    if (showClaim(historyEl, claim, { roots: CLAIM_ROOTS, opts: opts() })) return;
    historyEl.scrollTop = 0;
    toast("The linked turn isn't in this session.");
  }

  // Annotate's "Copy link" for a selection in a turn's answer, step or own
  // message: a participant's page's link when the session has a person
  // active (it opens in the browser their invite link was opened in: one
  // link per browser, the cookie), else this page's own.
  function linkFor(source, range) {
    // Not in a Revise stack's switched copy (revise_switch.js: view only, no claim key; Verify isn't offered there either).
    if (!store.selected || !["answer", "step", "user"].includes(source.kind) || !historyEl.contains(source.root)
        || source.root.closest("[data-stack-view]")) return null;
    const turnId = turnIdOf(historyEl, source.root);
    if (!turnId) return null;
    const claim = { turnId, ...selectionClaim(source.root, range, opts()) };
    if (!claim.q) return null;
    const target = claimTarget();
    if (!target) {
      const { location } = win;
      return { url: `${location.origin}${location.pathname}${location.search}${ownerClaimHash(store.selected, claim)}`,
               title: "A link to this on your page (no person is invited to this session)" };
    }
    const whose = target.names.map((name) => `${name}'s`).join(" or ");
    return { url: participantClaimLink(target.base, store.selected, claim),
             title: `A link to this for ${whose} browser: it opens where their invite link was opened (one link per browser). Opened here, it shows your page.` };
  }

  async function copyLink({ url }) {
    if (await copyText(url)) toast("Link copied");
    else toast(`Couldn't copy: ${url}`, null, { sticky: true });
  }

  return { opts, pending, showPending, linkFor, copyLink };
}
