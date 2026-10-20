// Session chains on the page (docs/sessions.md, Session chains): a session
// that continues an earlier one (its summary's `continues`), "the next run of
// the same routine". The chain is derived from the list, never stored: back
// through `continues`, forward through the session whose `continues` names
// this one. The lists fold a chain into its latest listed link's card (a
// `#N` chip, its earlier links in a popover); the session page links the
// previous and the next link. Pure: lists_view.js places the chip and rows
// (lit-html templates) and app.js the toast's markup, and they bind them.
import { normalize, previewForCard, relativeTime } from "./format.js";
import { stoppedBadge, waitingBadge } from "./sessions_list.js";
import { waitingOn } from "./notify.js";
import { archivedBadge, rowBadgesTemplate, rowDotTemplate } from "./families_view.js";
import { html, nothing } from "./vendor/lit-html.js";

// The opener a new link's composer is filled with (never sent: the user
// edits or sends it) when the continue brings none of its own.
export const CONTINUE_OPENER = "Continue where we left off.";

// What a new link's composer is filled with: the continue's own opener
// (+created+, the 201: the previous link's first typed message, when that
// link continues one), else CONTINUE_OPENER. So whatever the user sent on
// the last link comes back on the next one.
export function openerText(created) {
  const own = created?.opener;
  return typeof own === "string" && own.trim() ? own : CONTINUE_OPENER;
}

// Whether +text+ (a title or a first message) is the opener and nothing
// else, trimmed: "Continue where we left off. Then fix X" is a title of its own.
export function isOpener(text) {
  return normalize(text) === CONTINUE_OPENER;
}

// A link's card title (format.js previewForCard), display only: a link
// whose title is the opener, as every link's first message is once sent,
// reads its chain's first link's title instead, so the links of a chain
// keep its name. Its own title when the first link isn't in +byId+ (id →
// session; deleted, or a walk a missing link cut short) or is the opener too.
// A link with a title of its own (/title; a new link inherits it) reads it,
// and a titled first link names its chain.
export function chainTitle(s, byId) {
  const own = previewForCard(s);
  if (s?.title || !s?.continues || !isOpener(s.first_preview || s.last_prompt)) return own;
  const seen = new Set([s.id]);
  let at = s;
  while (at.continues) {
    const prev = byId.get(at.continues);
    if (!prev || seen.has(prev.id)) return own;
    seen.add(prev.id);
    at = prev;
  }
  return !at.title && isOpener(at.first_preview || at.last_prompt) ? own : previewForCard(at);
}

// The open session's title (app.js updateSessionTitle: the top bar and the
// tab) from +first+, its first message: it follows its card. A chain link
// (+shown+, its summary, has continues) reads +cardTitle+(shown) whatever
// its first message: a web link inherits its chain's title, and its first
// message is an opener (the constant or the user's own). Else +first+,
// unless it is the opener. A titled session (/title) reads its card's too.
// +shown+ null: not listed yet, +first+.
export function openTitle({ shown, first, cardTitle }) {
  if (shown && (shown.title || shown.continues || isOpener(first))) return cardTitle(shown);
  return first;
}

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
// make ends where it started. +nexts+ and +byId+ (id → session): a caller
// walking many chains of one list builds them once (foldChains).
export function chainLinks(list, id, nexts = nextsOf(list), byId = new Map(list.map((s) => [s.id, s]))) {
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
// or null. +continues+: the open session's own `continues`, when the list
// may not have caught up with it. A previous link the list doesn't hold
// (deleted) is null: its link would open a not-found page.
export function chainNeighbours(list, id, { continues = null } = {}) {
  const self = list.find((s) => s.id === id);
  const prevId = self?.continues || continues || null;
  const prevSession = prevId && prevId !== id ? list.find((s) => s.id === prevId) : null;
  const prev = prevSession ? { id: prevId, session: prevSession } : null;
  const nextSession = nextsOf(list).get(id) || null;
  const next = nextSession ? { id: nextSession.id, session: nextSession } : null;
  return { prev, next };
}

const pad = (n) => String(n).padStart(2, "0");
const localDate = (iso) => {
  const d = new Date(iso || "");
  return Number.isNaN(d.getTime()) ? null : d;
};

// A link's day as the carry note writes its date: the local YYYY-MM-DD of
// its start; "" when it has none.
export function chainDate(iso) {
  const d = localDate(iso);
  return d ? `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}` : "";
}

// A link's start as a local HH:MM; "" when it has none.
export function chainClock(iso) {
  const d = localDate(iso);
  return d ? `${pad(d.getHours())}:${pad(d.getMinutes())}` : "";
}

// A link's start as a chain list shows it: its date (chainDate), with its
// HH:MM when one of +otherIsos+ (the chain's other links' starts) is on the
// same local day, so two links of one day tell apart. "" when it has none.
export function chainStamp(iso, otherIsos = []) {
  const date = chainDate(iso);
  if (!date) return "";
  return otherIsos.some((o) => chainDate(o) === date) ? `${date} ${chainClock(iso)}` : date;
}

// The families (sessions_list.js families) with the chains folded in: a
// family whose head is an earlier link of a chain whose later link heads a
// listed family is left out (it is in that card's chain list), whatever
// its archived state, its delegates with it; a family whose head is in a
// chain of two or more carries chain: {links, at, folded} (at: the head's
// index). +all+: every session the page holds, archived ones too (the links
// the list leaves out). The same array when no chain is in it.
// @param fold false: every family stays (each link's card carries its
//   chip, "#1 of 3"; folded false), for a search or the archived ones
export function foldChains(fams, all, { fold = true } = {}) {
  if (!all.some((s) => s.continues)) return fams;
  const nexts = nextsOf(all);
  const byId = new Map(all.map((s) => [s.id, s]));
  const heads = new Set(fams.map((f) => f.head.id));
  const out = [];
  let changed = false;
  for (const f of fams) {
    const links = chainLinks(all, f.head.id, nexts, byId);
    if (links.length < 2) {
      out.push(f);
      continue;
    }
    changed = true;
    const at = links.findIndex((s) => s.id === f.head.id);
    if (fold && links.slice(at + 1).some((s) => heads.has(s.id))) continue;
    out.push({ ...f, chain: { links, at, folded: fold } });
  }
  return changed ? out : fams;
}

// The all view's families: folded (foldChains) unless a search is typed or
// the archived ones are included. Then every link is a card of its own
// (with its chip), so a search finds an earlier link, and an earlier
// link's delegates fold into its own card as anywhere else.
export function allViewChains(fams, all, { query = "", includeArchived = false } = {}) {
  return foldChains(fams, all, { fold: !query && !includeArchived });
}

// The links a family's chain list shows: the chain but its head, newest
// first, each {session, n} (n: its 1-based place in the chain).
function chainOthers(f) {
  const links = f?.chain?.links || [];
  return links.map((session, i) => ({ session, n: i + 1 }))
    .filter(({ session }) => session.id !== f.head.id)
    .reverse();
}

// The chip in a chain's card: "#3" (the head's place; "#2 of 3" when
// later links aren't listed), with a live dot / "waiting" when one of the
// other links has a worker / waits on the user (typing in an archived link
// brings it back, but it stays folded here). nothing for a family in no
// chain. A lit-html template, as families_view.js's chip.
// @param open whether the list is open (aria-expanded)
export function chainChipTemplate(f, { open = false } = {}) {
  if (!f?.chain) return nothing;
  const { links, at } = f.chain;
  const others = chainOthers(f);
  const live = others.filter(({ session: s }) => s.owner === "worker").length;
  const waiting = others.filter(({ session: s }) => waitingOn(s)).length;
  const n = at + 1;
  const text = n === links.length ? `#${n}` : `#${n} of ${links.length}`;
  const earlier = at;
  const later = links.length - 1 - at;
  const parts = [earlier ? `${earlier} earlier ${earlier === 1 ? "link" : "links"}` : "", later ? `${later} later` : ""].filter(Boolean);
  const title = `Session chain: link ${n} of ${links.length} (${parts.join(", ")}); open the list`;
  const liveT = live ? html`<span class="cc-live"> · <span class="live-dot" aria-hidden="true"></span>${live} live</span>` : nothing;
  const waitingT = waiting ? html` · <span class="cc-waiting">${waiting} waiting</span>` : nothing;
  return html`<button type="button" class=${`chain-chip${waiting ? " waiting" : ""}`} aria-expanded=${open ? "true" : "false"}
    title=${title}><span class="cc-arrow" aria-hidden="true">↩</span>${text}${liveT}${waitingT}</button>`;
}

// The chain's list (the chip's popover): one row per other link, newest
// first: status dot, "#N", its date (with its HH:MM when another link of
// the chain, the head too, started the same day: chainStamp), its own title (/title) when it
// differs from the head's (a link inherits its chain's: the card says it), else its recap's
// first sentence, else its preview, the waiting / stopped badge, archived. A row's click opens
// that link (families_view.js's popover binds .family-row[data-id]).
// @param activeId the open session's id (its row is .active)
// A chain row's words: a name of its own (not the one it shares with the
// head), else what tells the link apart: its recap, else its preview (an
// opener's read as the chain's, chainTitle, with its own title left out).
function rowTitle(s, headTitle, byId) {
  if (s.title && s.title !== headTitle) return s.title;
  return s.recap || chainTitle({ ...s, title: null }, byId);
}

export function chainRowsTemplate(f, { activeId = null, now = Date.now() } = {}) {
  const links = f?.chain?.links || [];
  const byId = new Map(links.map((s) => [s.id, s]));
  const headTitle = (byId.get(f?.head?.id) || f?.head)?.title || null;
  const rows = chainOthers(f).map(({ session: s, n }) => {
    const cls = ["family-row", "chain-row"];
    if (activeId && s.id === activeId) cls.push("active");
    if (s.archived) cls.push("archived");
    const waiting = waitingBadge(s, { inFamily: true });
    const stopped = waiting ? null : stoppedBadge(s);
    const date = chainStamp(s.created_at, links.filter((l) => l !== s).map((l) => l.created_at));
    const ago = relativeTime(s.updated_at || s.created_at || "", now);
    const tip = `${s.id} · ${s.status || ""}${ago ? ` · updated ${ago}` : ""}`;
    return html`<div class=${cls.join(" ")} data-id=${s.id} style=${"--depth:1"} role=${"listitem"}><button type="button" class="fr-open"
      title=${tip}>${rowDotTemplate(s, waiting)}<span class="cr-n">#${n}</span>${
      date ? html`<span class=${date.length > 10 ? "cr-date timed" : "cr-date"}>${date}</span>` : nothing}<span class="fr-preview">${rowTitle(s, headTitle, byId)}</span>${
      rowBadgesTemplate(waiting, stopped)}${s.archived ? archivedBadge : nothing}</button></div>`;
  });
  return html`<div class="family-rows chain-rows" role="list">${rows}</div>`;
}

// What the page does with a refused continue (POST /api/sessions
// continues, api()'s error with the answer's body): "open" the link that
// continues it already (409 continued, next_id), "children" naming the
// delegates still open that can't move (409 open_children, ids: {id, short, text} each,
// the text its preview and why it is open: the server's word from its
// detail, "<short> (running)", else its state here), or "error" with the
// server's words.
export function continueRefusal(error, sessions = []) {
  const body = error?.body || {};
  if (error?.code === "continued" && body.next_id) return { kind: "open", id: body.next_id };
  const text = String(error?.message || "refused");
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

// The open-children refusal as the toast shows it: the open delegates the
// continue can't move to the next link (an older chi's worker, a chi
// REPL), each a link to its session with what to do about it.
// @param hrefFor (id) → its page's href
export function openChildrenTemplate(prevId, children, hrefFor) {
  const n = children.length;
  const items = children.map((c) => html`<li><a href=${hrefFor(c.id)} class=${"cr-child"}>${c.short}</a>${c.text ? ` ${c.text}` : nothing}</li>`);
  const line = `Can't continue ${String(prevId).slice(0, 8)}: ${n} open ${n === 1 ? "delegate" : "delegates"} can't move to the next link. ` +
    `Do what ${n === 1 ? "it says" : "each says"}, or wait for ${n === 1 ? "it" : "them"}, then continue.`;
  return html`<div class="continue-refused"><div>${line}</div><ul>${items}</ul></div>`;
}

// The toast after a continue: the new link, the previous one archived (when
// the page shows the new one), how many open delegates moved to it (the
// answer's moved), and the model fallback's warning (model_warning: the
// previous link's host is gone, the link starts on the default).
export function continuedText(prevId, created, { opened = true } = {}) {
  const short = String(prevId).slice(0, 8);
  const moved = Array.isArray(created?.moved) ? created.moved.length : 0;
  const parts = [`Continued ${short} in ${String(created?.id || "").slice(0, 8)}`];
  if (opened) parts.push(`${short} is archived`);
  if (moved) parts.push(`${moved} open ${moved === 1 ? "delegate" : "delegates"} moved`);
  const warning = typeof created?.model_warning === "string" ? created.model_warning.trim() : "";
  if (warning) parts.push(warning);
  return parts.join("; ");
}

// A fresh link: a chain link (its `continues`) with no turn yet, so its
// composer offers the model picker (a pick runs /model in it). However the
// link was made (continue →, chi send --continues, a reload). Not fresh once
// a turn started (+state.turnStarted+, set live before the timing re-read
// brings its record; a failed or canceled first turn counts too), while one
// runs, when a terminal chi owns it (sending is refused there) or when it is
// +continued+ itself (a /model there would wake an archived link).
export function freshLink(state, { running = false, continued = false } = {}) {
  if (!state?.continues || running || continued || state.turnStarted) return false;
  if (state.owner === "tui") return false;
  const timing = state.timing || {};
  return !(timing.turnRecords || []).length && !timing.activeTurn;
}
