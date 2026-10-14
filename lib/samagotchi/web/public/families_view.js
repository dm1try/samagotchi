// A parent's card with its delegates folded in (docs/sessions.md, the web):
// the chip that opens the family's list, and the list's rows, as lit-html
// templates; lists_view.js places them (inline in all sessions, a popover
// over the strip) and binds the clicks. Attributes after a bound one are
// bound too, so they keep their order in the markup (lit sets bound ones
// after the static ones).
import { ownerBadge, previewForCard, relativeTime } from "./format.js";
import { familySummary, stoppedBadge, waitingBadge } from "./sessions_list.js";
import { html, nothing, render } from "./vendor/lit-html.js";
import { keepFocus } from "./keep_focus.js";

// The chip in a parent's meta row: "▸ 3 delegates · ● 1 live · 1 waiting"
// (a waiting one in the attention colour), its tooltip the delegates by
// state. nothing for a family with no members.
// @param open whether the list is open (aria-expanded; the arrow turns)
export function familyChipTemplate(f, { open = false } = {}) {
  const sum = familySummary(f);
  if (!sum) return nothing;
  const waiting = sum.counts.waiting;
  const live = sum.live ? html`<span class="fc-live"> · <span class="live-dot" aria-hidden="true"></span>${sum.live} live</span>` : nothing;
  const waitingT = waiting ? html` · <span class="fc-waiting">${waiting} waiting</span>` : nothing;
  return html`<button type="button" class=${`family-chip${waiting ? " waiting" : ""}`} aria-expanded=${open ? "true" : "false"}
    title=${sum.title}><span class="fc-arrow" aria-hidden="true">▸</span>${sum.total} ${sum.total === 1 ? "delegate" : "delegates"}${
    live}${waitingT}</button>`;
}

// A row's status dot (a family's or a chain's): the waiting title over the
// status when the session waits on the user.
export function rowDotTemplate(s, waiting) {
  const word = (waiting ? waiting.title : s.status) || "";
  return html`<span class=${`status dot ${s.status || ""}${waiting ? " waiting" : ""}`} title=${word} aria-label=${word}></span>`;
}

// A row's waiting or stopped badge, and the archived one.
export function rowBadgesTemplate(waiting, stopped) {
  return html`${waiting ? html`<span class=${`attn attn-${waiting.kind}`} title=${waiting.title}>${waiting.text}</span>` : nothing}${
    stopped ? html`<span class="stopped-badge" title=${stopped.title}>${stopped.text}</span>` : nothing}`;
}

export const archivedBadge = html`<span class="archived-badge" title="Archived: hidden from the lists, kept for good">archived</span>`;

// The family's list: one row per member, depth first, indented one step
// per depth (--depth): status dot, preview, time, the waiting / stopped
// badge, the owner badge, archived. A row's click opens that session.
// @param activeId the open session's id (its row is .active)
// @param matchIds a search's matching members (.match; the rest .dim), or
//   null without a search
// @param archivable an archive button per row (all sessions, not in select mode)
export function familyRowsTemplate(f, { activeId = null, matchIds = null, archivable = false, now = Date.now() } = {}) {
  const rows = f.members.map(({ session: s, depth }) => {
    const cls = ["family-row"];
    if (activeId && s.id === activeId) cls.push("active");
    if (matchIds) cls.push(matchIds.has(s.id) ? "match" : "dim");
    if (s.archived) cls.push("archived");
    const ts = s.updated_at || s.created_at || "";
    const waiting = waitingBadge(s, { inFamily: true });
    const stopped = waiting ? null : stoppedBadge(s);
    const owner = ownerBadge(s.owner, s.id);
    const ago = relativeTime(ts, now);
    const short = s.short_id || String(s.id).slice(0, 8);
    const arch = !archivable ? nothing : s.archived
      ? html`<button type="button" class="card-arch" data-arch=${s.id} title=${"Unarchive: back to the lists"} aria-label=${`Unarchive session ${short}`}></button>`
      : html`<button type="button" class="card-arch" data-arch=${s.id} title=${"Archive: hide from the lists, keep for good"} aria-label=${`Archive session ${short}`}></button>`;
    return html`<div class=${cls.join(" ")} data-id=${s.id} style=${`--depth:${depth}`} role=${"listitem"}><button type="button" class="fr-open"
      title=${`${s.id} · ${s.status || ""}`}>${rowDotTemplate(s, waiting)}<span class="fr-preview">${previewForCard(s)}</span>${
      rowBadgesTemplate(waiting, stopped)}${ago ? html`<span class="time">${ago}</span>` : nothing}${
      owner ? html`<span class=${`owner ${owner.kind}`} title=${owner.title}>${owner.text}</span>` : nothing}${
      s.archived ? archivedBadge : nothing}</button>${arch}</div>`;
  });
  return html`<div class="family-rows" role="list">${rows}</div>`;
}

// The widest window index.html lays out as a phone (@media (max-width:600px)).
const PHONE_MAX_PX = 600;

// The status dots' pulse in +root+ on the document timeline's clock (each
// animation's start time 0), the phase the cards' --pulse-delay gives
// theirs (lists_view.js cardAnimStyle): a popover keeps its row nodes
// across draws, reused by position, so a dot that moves to another node
// or starts pulsing there (a member inserted above, a status flip) would
// otherwise start its pulse over, out of step with the rest.
export function syncPulses(root) {
  root.querySelectorAll(".dot").forEach((dot) => {
    for (const a of dot.getAnimations?.() || []) {
      if (a.startTime !== 0) a.startTime = 0;
    }
  });
}

// The strip's family popover: one #familyPop in body (position: fixed, so
// the strip's sideways scroll on a phone doesn't clip it), under the chip
// it was opened from and as wide as that card (300 px at least, inside the
// window; on a phone, the window less 16 px gutters). The strip draws again
// on every hub event: refresh() then finds the new chip for the same head,
// draws the rows again (lit writes only what changed: a row keeps its
// nodes, reused by position, so keepFocus keeps the focus on its session)
// and closes when the family is gone.
// @param rowsFor (headId) → the rows' template, or null when the family
//   has no members (any more)
// @param anchorFor (headId) → its chip in the strip, or null
// @param onPick (id) a row's click
// @param onClose () after it closed (the strip's held order catches up)
// @param id the element's id (a chain's popover, chains.js, is another one)
export function createFamilyPop({ id = "familyPop", doc, win, rowsFor, anchorFor, onPick, onClose = () => {} }) {
  let el = null;
  let headId = null;

  const element = () => {
    if (el) return el;
    el = doc.createElement("div");
    el.id = id;
    el.className = "family-pop";
    el.hidden = true;
    el.addEventListener("click", (e) => {
      const row = e.target?.closest?.(".family-row[data-id]");
      if (row) onPick(row.dataset.id);
    });
    doc.body.appendChild(el);
    return el;
  };

  const place = (anchor) => {
    const chip = anchor.getBoundingClientRect();
    const card = (anchor.closest(".card") || anchor).getBoundingClientRect();
    const vw = win.innerWidth;
    // A phone (index.html's 600 px layout): the width minus 16 px gutters.
    const phone = vw <= PHONE_MAX_PX;
    const width = phone ? vw - 32 : Math.max(300, Math.round(card.width));
    const left = phone ? 16 : Math.max(8, Math.min(Math.round(card.left), vw - width - 8));
    el.style.top = `${Math.round(chip.bottom + 6)}px`;
    el.style.left = `${left}px`;
    el.style.width = `${width}px`;
  };

  // Draws the open family again: false (and closed) when it is gone.
  const draw = () => {
    const rows = rowsFor(headId);
    const anchor = rows == null ? null : anchorFor(headId);
    if (!anchor) {
      close();
      return false;
    }
    // A row inserted before the focused one: the focus stays on its session.
    keepFocus(el, "data-id", () => render(rows, el));
    syncPulses(el);
    anchor.setAttribute("aria-expanded", "true");
    place(anchor);
    return true;
  };

  function open(id) {
    if (headId && headId !== id) close();
    headId = id;
    element().hidden = false;
    draw();
  }

  function close() {
    if (!headId) return;
    anchorFor(headId)?.setAttribute("aria-expanded", "false");
    headId = null;
    el.hidden = true;
    render(nothing, el);
    onClose();
  }

  return {
    open,
    close,
    toggle: (id) => (headId === id ? close() : open(id)),
    isOpen: () => headId != null,
    openHead: () => headId,
    // After the strip drew again.
    refresh: () => { if (headId) draw(); },
    // The page scrolled or resized under it.
    reposition: () => {
      const anchor = headId && anchorFor(headId);
      if (anchor) place(anchor);
    },
    // Esc closes it, before any other Esc handler (app.js listens in the
    // capture phase): true when it did.
    onKeydown(e) {
      if (!headId || e.key !== "Escape") return false;
      const id = headId;
      e.preventDefault();
      e.stopImmediatePropagation();
      e.stopPropagation();
      close();
      anchorFor(id)?.focus(); // the chip as drawn after close() (a held strip catches up)
      return true;
    },
    // A pointer down outside it and its chip closes it.
    onPointerDown(e) {
      if (!headId || el.contains(e.target)) return;
      if (anchorFor(headId)?.contains(e.target)) return;
      close();
    },
  };
}
