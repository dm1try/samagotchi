// Session chains on the page (docs/sessions.md, Session chains): a session
// that continues an earlier one (its summary's `continues`), "the next day of
// the same routine". The chain is derived from the list, never stored: back
// through `continues`, forward through the session whose `continues` names
// this one. The lists fold a chain into its latest listed link's card (a
// `day N` chip, its earlier links in a popover); the session page links the
// previous and the next link. Pure: app.js places the markup and binds it.
import { escapeHtml, previewForCard, relativeTime } from "./format.js";
import { stoppedBadge, waitingBadge } from "./sessions_list.js";
import { waitingOn } from "./notify.js";

// The opener a new link's composer is filled with (never sent: the user
// edits or sends it). The same for every chain.
export const CONTINUE_OPENER = "Continue where we left off.";

const createdMs = (s) => {
  const ms = Date.parse(s?.created_at || "");
  return Number.isNaN(ms) ? 0 : ms;
};

// session id → the session that continues it: the first created, as the
// server's next_of picks (a link is continued once; a hand-edited second
// one doesn't fork the chain).
function nextsOf(list) {
  const nexts = new Map();
  for (const s of list.slice().sort((a, b) => createdMs(a) - createdMs(b))) {
    if (s.continues && s.continues !== s.id && !nexts.has(s.continues)) nexts.set(s.continues, s);
  }
  return nexts;
}

// The chain +id+ is in, earliest link first, as far as +list+ holds it (a
// link that isn't listed ends the walk there). [] for an id not listed; a
// session in no chain is a chain of one. A loop a hand-edited file could
// make ends where it started.
export function chainLinks(list, id, nexts = nextsOf(list)) {
  const byId = new Map(list.map((s) => [s.id, s]));
  const self = byId.get(id);
  if (!self) return [];
  const links = [self];
  const seen = new Set([id]);
  for (let at = byId.get(self.continues); at && !seen.has(at.id); at = byId.get(at.continues)) {
    seen.add(at.id);
    links.unshift(at);
  }
  for (let at = nexts.get(id); at && !seen.has(at.id); at = nexts.get(at.id)) {
    seen.add(at.id);
    links.push(at);
  }
  return links;
}

// The session page's neighbours of +id+: {prev, next}, each {id, session}
// (session null when the list doesn't hold it) or null. +continues+: the
// open session's own `continues`, when the list may not have caught up.
export function chainNeighbours(list, id, { continues = null } = {}) {
  const self = list.find((s) => s.id === id);
  const prevId = self?.continues || continues || null;
  const prev = prevId && prevId !== id ? { id: prevId, session: list.find((s) => s.id === prevId) || null } : null;
  const nextSession = nextsOf(list).get(id) || null;
  const next = nextSession ? { id: nextSession.id, session: nextSession } : null;
  return { prev, next };
}

// A link's day as the carry note writes it: the local YYYY-MM-DD of its
// start; "" when it has none.
export function chainDate(iso) {
  const d = new Date(iso || "");
  if (Number.isNaN(d.getTime())) return "";
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

// The families (sessions_list.js families) with the chains folded in: a
// family whose head is an earlier link of a chain whose later link heads a
// listed family is left out (it is in that card's chain list), whatever
// its archived state, its delegates with it; a family whose head is in a
// chain of two or more carries chain: {links, at} (at: the head's index).
// +all+: every session the page holds, archived ones too (the links the
// list leaves out). The same array when no chain is in it.
export function foldChains(fams, all) {
  if (!all.some((s) => s.continues)) return fams;
  const nexts = nextsOf(all);
  const heads = new Set(fams.map((f) => f.head.id));
  const out = [];
  let changed = false;
  for (const f of fams) {
    const links = chainLinks(all, f.head.id, nexts);
    if (links.length < 2) {
      out.push(f);
      continue;
    }
    changed = true;
    const at = links.findIndex((s) => s.id === f.head.id);
    if (links.slice(at + 1).some((s) => heads.has(s.id))) continue;
    out.push({ ...f, chain: { links, at } });
  }
  return changed ? out : fams;
}

// The links a family's chain list shows: the chain but its head, newest
// first, each {session, day} (day: its 1-based place in the chain).
export function chainOthers(f) {
  const links = f?.chain?.links || [];
  return links.map((session, i) => ({ session, day: i + 1 }))
    .filter(({ session }) => session.id !== f.head.id)
    .reverse();
}

// The chip in a chain's card: "day 3" (the head's place; "day 2 of 3" when
// later links aren't listed), with a live dot / "waiting" when one of the
// other links has a worker / waits on the user (typing in an archived link
// brings it back, but it stays folded here). "" for a family in no chain.
// @param open whether the list is open (aria-expanded)
export function chainChipHtml(f, { open = false } = {}) {
  if (!f?.chain) return "";
  const { links, at } = f.chain;
  const others = chainOthers(f);
  const live = others.filter(({ session: s }) => s.owner === "worker").length;
  const waiting = others.filter(({ session: s }) => waitingOn(s)).length;
  const day = at + 1;
  const text = day === links.length ? `day ${day}` : `day ${day} of ${links.length}`;
  const earlier = at;
  const later = links.length - 1 - at;
  const parts = [earlier ? `${earlier} earlier ${earlier === 1 ? "link" : "links"}` : "", later ? `${later} later` : ""].filter(Boolean);
  const title = `Session chain: day ${day} of ${links.length} (${parts.join(", ")}); open the list`;
  const liveHtml = live ? `<span class="cc-live"> · <span class="live-dot" aria-hidden="true"></span>${live} live</span>` : "";
  const waitingHtml = waiting ? ` · <span class="cc-waiting">${waiting} waiting</span>` : "";
  return `<button type="button" class="chain-chip${waiting ? " waiting" : ""}" aria-expanded="${open ? "true" : "false"}" title="${escapeHtml(title)}"><span class="cc-arrow" aria-hidden="true">↩</span>${escapeHtml(text)}${liveHtml}${waitingHtml}</button>`;
}

// The chain's list (the chip's popover): one row per other link, newest
// first: status dot, "day N", its date, its recap's first sentence (else
// its preview), the waiting / stopped badge, archived. A row's click opens
// that link (families_view.js's popover binds .family-row[data-id]).
// @param activeId the open session's id (its row is .active)
export function chainRowsHtml(f, { activeId = null, now = Date.now() } = {}) {
  const rows = chainOthers(f).map(({ session: s, day }) => {
    const cls = ["family-row", "chain-row"];
    if (activeId && s.id === activeId) cls.push("active");
    if (s.archived) cls.push("archived");
    const waiting = waitingBadge(s, { inFamily: true });
    const stopped = waiting ? null : stoppedBadge(s);
    const dotWord = waiting ? waiting.title : s.status;
    const date = chainDate(s.created_at);
    const ago = relativeTime(s.updated_at || s.created_at || "", now);
    const parts = [
      `<span class="status dot ${escapeHtml(s.status || "")}${waiting ? " waiting" : ""}" title="${escapeHtml(dotWord || "")}" aria-label="${escapeHtml(dotWord || "")}"></span>`,
      `<span class="cr-day">day ${day}</span>`,
      date ? `<span class="cr-date">${escapeHtml(date)}</span>` : "",
      `<span class="fr-preview">${escapeHtml(s.recap || previewForCard(s))}</span>`,
      waiting ? `<span class="attn attn-${waiting.kind}" title="${escapeHtml(waiting.title)}">${escapeHtml(waiting.text)}</span>` : "",
      stopped ? `<span class="stopped-badge" title="${escapeHtml(stopped.title)}">${escapeHtml(stopped.text)}</span>` : "",
      s.archived ? `<span class="archived-badge" title="Archived: hidden from the lists, kept for good">archived</span>` : "",
    ].join("");
    const tip = `${s.id} · ${s.status || ""}${ago ? ` · updated ${ago}` : ""}`;
    return `<div class="${cls.join(" ")}" data-id="${escapeHtml(s.id)}" style="--depth:1" role="listitem"><button type="button" class="fr-open" title="${escapeHtml(tip)}">${parts}</button></div>`;
  });
  return `<div class="family-rows chain-rows" role="list">${rows.join("")}</div>`;
}

// What the page does with a refused continue (POST /api/sessions
// continues, api()'s error with the answer's body): "open" the link that
// continues it already (409 continued, next_id), "children" naming the
// delegates still open (409 open_children, ids: {id, short, text} each,
// the text its preview and why it is open: the server's word from its
// detail, "<short> (running)", else its state here), or "error" with the
// server's words.
export function continueRefusal(error, sessions = []) {
  const body = error?.body || {};
  if (error?.code === "continued" && body.next_id) return { kind: "open", id: body.next_id };
  const text = String(error?.message || "refused").replace(/\s*\(\d{3}\)$/, "");
  if (error?.code === "open_children" && Array.isArray(body.ids) && body.ids.length) {
    const byId = new Map(sessions.map((s) => [s.id, s]));
    const children = body.ids.map((id) => {
      const s = byId.get(id);
      const short = String(id).slice(0, 8);
      const said = text.split(short + " (")[1]?.split(")")[0];
      const why = said || (s ? (waitingOn(s) ? "waiting" : s.status || "") : "");
      const preview = s ? previewForCard(s) : "";
      return { id, short, text: [preview, why ? `(${why})` : ""].filter(Boolean).join(" ") };
    });
    return { kind: "children", children, text };
  }
  return { kind: "error", text };
}

// The open-children refusal as the toast shows it: the delegates named,
// each a link to its session.
// @param hrefFor (id) → its page's href
export function openChildrenHtml(prevId, children, hrefFor) {
  const n = children.length;
  const items = children.map((c) => `<li><a href="${escapeHtml(hrefFor(c.id))}" class="cr-child">${escapeHtml(c.short)}</a>${c.text ? ` ${escapeHtml(c.text)}` : ""}</li>`).join("");
  return `<div class="continue-refused"><div>Can't continue ${escapeHtml(String(prevId).slice(0, 8))}: ${n} ${n === 1 ? "delegate is" : "delegates are"} still open. Wait for ${n === 1 ? "it" : "them"}, stop or archive ${n === 1 ? "it" : "them"}, then continue.</div><ul>${items}</ul></div>`;
}
