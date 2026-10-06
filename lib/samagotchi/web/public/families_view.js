// A parent's card with its delegates folded in (docs/sessions.md, the web):
// the chip that opens the family's list, and the list's rows. Pure string
// builders; app.js places them (inline in all sessions, a popover over the
// strip) and binds the clicks.
import { escapeHtml, ownerBadge, previewForCard, relativeTime } from "./format.js";
import { familySummary, stoppedBadge, waitingBadge } from "./sessions_list.js";

// The chip in a parent's meta row: "▸ 3 delegates · ● 1 live · 1 waiting"
// (a waiting one in the attention colour), its tooltip the delegates by
// state. "" for a family with no members.
// @param open whether the list is open (aria-expanded; the arrow turns)
export function familyChipHtml(f, { open = false } = {}) {
  const sum = familySummary(f);
  if (!sum) return "";
  const waiting = sum.counts.waiting;
  const liveHtml = sum.live ? `<span class="fc-live"> · <span class="live-dot" aria-hidden="true"></span>${sum.live} live</span>` : "";
  const waitingHtml = waiting ? ` · <span class="fc-waiting">${waiting} waiting</span>` : "";
  return `<button type="button" class="family-chip${waiting ? " waiting" : ""}" aria-expanded="${open ? "true" : "false"}" title="${escapeHtml(sum.title)}"><span class="fc-arrow" aria-hidden="true">▸</span>${sum.total} ${sum.total === 1 ? "delegate" : "delegates"}${liveHtml}${waitingHtml}</button>`;
}

// The family's list: one row per member, depth first, indented one step
// per depth (--depth): status dot, preview, time, the waiting / stopped
// badge, the owner badge, archived. A row's click opens that session.
// @param activeId the open session's id (its row is .active)
// @param matchIds a search's matching members (.match; the rest .dim), or
//   null without a search
// @param archivable an archive button per row (all sessions, not in select mode)
export function familyRowsHtml(f, { activeId = null, matchIds = null, archivable = false, now = Date.now() } = {}) {
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
    const dotWord = waiting ? waiting.title : s.status;
    const parts = [
      `<span class="status dot ${escapeHtml(s.status || "")}${waiting ? " waiting" : ""}" title="${escapeHtml(dotWord || "")}" aria-label="${escapeHtml(dotWord || "")}"></span>`,
      `<span class="fr-preview">${escapeHtml(previewForCard(s))}</span>`,
      waiting ? `<span class="attn attn-${waiting.kind}" title="${escapeHtml(waiting.title)}">${escapeHtml(waiting.text)}</span>` : "",
      stopped ? `<span class="stopped-badge" title="${escapeHtml(stopped.title)}">${escapeHtml(stopped.text)}</span>` : "",
      ago ? `<span class="time">${escapeHtml(ago)}</span>` : "",
      owner ? `<span class="owner ${owner.kind}" title="${escapeHtml(owner.title)}">${escapeHtml(owner.text)}</span>` : "",
      s.archived ? `<span class="archived-badge" title="Archived: hidden from the lists, kept for good">archived</span>` : "",
    ].join("");
    const short = escapeHtml(s.short_id || String(s.id).slice(0, 8));
    const arch = !archivable ? "" : s.archived
      ? `<button type="button" class="card-arch" data-arch="${escapeHtml(s.id)}" title="Unarchive: back to the lists" aria-label="Unarchive session ${short}"></button>`
      : `<button type="button" class="card-arch" data-arch="${escapeHtml(s.id)}" title="Archive: hide from the lists, keep for good" aria-label="Archive session ${short}"></button>`;
    return `<div class="${cls.join(" ")}" data-id="${escapeHtml(s.id)}" style="--depth:${depth}" role="listitem"><button type="button" class="fr-open" title="${escapeHtml(`${s.id} · ${s.status || ""}`)}">${parts}</button>${arch}</div>`;
  });
  return `<div class="family-rows" role="list">${rows.join("")}</div>`;
}
