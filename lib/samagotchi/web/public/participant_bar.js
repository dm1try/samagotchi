// What the main page shows a participant in the owner's bar's places
// (the participant main page, scenes 1-5), as data and lit views, no page
// state: participant_main.js feeds it.
//
//   the top row   their name ("Alex · invited") and, on a desktop, when the
//                 link ends ("link ends 20 Nov")
//   the bottom    the composer card's footer: the status, context %, the
//   row           speed (the turn's time while one runs), their spending
//                 ("$0.42 of $2.00 used"), and on a desktop what their
//                 turns may do ("chi acts under the owner's rules")
//   the closed    the composer given way to one line: their limit reached,
//   line          the session stopped, the link ended
//
// Never the owner's cost, memories, the model or a path: only what the
// show's viewer (ParticipantShow#participant_main_viewer) and the
// session's numbers carry. See docs/internals/web-frontend.md (The
// participant's page).
import { html, nothing } from "./vendor/lit-html.js";
import { ctxBarText, speedText, costText } from "./ctx.js";
import { formatDuration } from "./timing.js";

// "20 Nov" (the viewer's locale's day and month) of an ISO time; "" when
// it doesn't parse.
export function endsText(iso) {
  const at = Date.parse(iso || "");
  if (!Number.isFinite(at)) return "";
  return new Date(at).toLocaleDateString(undefined, { day: "numeric", month: "short" });
}

// "$0.42 of $2.00 used", "$0.42 used" without a cap; "" when their grant's
// exposure doesn't show the spend.
export function spentText(usage) {
  const spent = Number(usage?.spent);
  if (usage?.spent == null || !Number.isFinite(spent)) return "";
  const shown = spent > 0 ? costText(spent) : "$0.00";
  const cap = Number(usage?.cap);
  return usage?.cap != null && Number.isFinite(cap) ? `${shown} of ${money(cap)} used` : `${shown} used`;
}

const money = (value) => `$${Number(value).toFixed(2)}`;

// What their turns may do, by the grant's mode (pair: they act; review:
// they only read).
export const RULES_TEXT = { pair: "chi acts under the owner's rules", review: "your turns only read" };

// The bottom row's items: [{key, text, tip}].
//   status   "idle" | "running" | "waiting"
//   ctxPct   the context's fill (store.current.ctxPct), windowSource its window's source
//   speed    {decode_tps, source} of the last generation, or null
//   turnMs   the running turn's time so far, or null
//   usage    the show's viewer.usage
//   mode     the show's viewer.mode
export function barItems({ status, ctxPct = null, windowSource = null, speed = null, turnMs = null, usage = null, mode = null }) {
  const items = [{ key: "status", text: status, tip: STATUS_TIPS[status] || "" }];
  items.push({ key: "ctx", text: ctxBarText(ctxPct, windowSource), tip: "How full the session's context is" });
  if (turnMs != null) items.push({ key: "time", text: formatDuration(turnMs), tip: "This turn's time so far" });
  else {
    const tps = speedText(speed?.decode_tps, speed?.source);
    if (tps) items.push({ key: "speed", text: tps, tip: "Decode speed of the last generation" });
  }
  const spent = spentText(usage);
  if (spent) items.push({ key: "spent", text: spent, tip: "What your turns have cost, of the limit the owner set for you" });
  const rules = RULES_TEXT[mode] || "";
  return { items, rules };
}

const STATUS_TIPS = {
  idle: "No turn runs now",
  running: "A turn runs now",
  waiting: "The running turn waits for the owner",
};

export function barTemplate({ items, rules }) {
  return html`${items.map((item) => html`<span class=${`pb-pill pp-${item.key}`} data-key=${item.key} title=${item.tip || nothing}>${item.text}</span>`)}<span class="pb-gap"></span>${rules ? html`<span class="pb-rules">${rules}</span>` : nothing}`;
}

// The top row's chip and the link's end.
// +color+: their author colour (participant_model.js authorColor), as their badges.
export function whoTemplate({ name, endsAt, color = null }) {
  const ends = endsText(endsAt);
  return html`<span class="pb-who" title="You were invited to this session by its owner" style=${color ? `--who-color:${color}` : nothing}><b>${name || "you"}</b> · invited</span>${ends ? html`<span class="pb-ends" title=${`This link stops working on ${ends}`}>link ends ${ends}</span>` : nothing}`;
}

// The closed composer's line, or null when the composer stays:
//   capReached  the show's viewer.cap_reached (or a send refused for it)
//   usage       the show's viewer.usage (the cap's amount)
//   refusal     {code, text}: the server's words for a send refused as
//               session_stopped, or the link that ended (token_revoked,
//               token_expired, token_outdated): shown as they are
// → {kind, title, text}
export function closedLine({ capReached = false, usage = null, refusal = null } = {}) {
  if (refusal?.text) {
    const text = String(refusal.text);
    return { kind: refusal.code || "refused", title: `${text[0].toUpperCase()}${text.slice(1)}${/[.!?]$/.test(text) ? "" : "."}`, text: "You can keep reading." };
  }
  if (!capReached) return null;
  const cap = Number(usage?.cap);
  const amount = usage?.cap != null && Number.isFinite(cap) ? `the ${money(cap)}` : "the limit";
  return { kind: "cap_reached", title: `You have used ${amount} the owner set for you.`, text: "You can keep reading. Ask the owner to raise the limit to send more." };
}

export function closedTemplate(line) {
  return html`<b>${line.title}</b>${line.text}`;
}

// The codes of a refused send that close the composer (the rest are a
// toast with the server's words): their state, not this message's.
export const CLOSING_CODES = Object.freeze(["cap_reached", "session_stopped", "token_revoked", "token_expired", "token_outdated"]);
