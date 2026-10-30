// The owner's participants (docs/internals/participants.md): the info
// bar's chip (how many, someone here now) and its popover, the panel: each
// participant's state, expiry, spend against their cap, turns and when they
// were last seen, with Revoke and a new cap; Invite (name, person or agent,
// expiry, cap, and behind an auth proxy that names the signed-in user their
// email, which binds the link to that account) gives the link once, to
// copy, share (a phone's share sheet)
// or scan (its QR); and the participant view, the participant page as a
// participant sees this session (through the server's filter), in a new
// tab. The panel reads GET /api/sessions/:id/participants, again after
// every change and on a participants_changed event.
//
// The names it learns feed the author badges on participants' prompts
// (setParticipantNames). Pure but for the injected api and the popover
// shell, so the models and templates run under node --test.

import { html, nothing, render } from "./vendor/lit-html.js";
import { createChipPopover } from "./chip_popover.js";
import { authorColor, participantAuthor } from "./participant_model.js";
import { setParticipantNames } from "./participant_names.js";
import { stillOn } from "./latest.js";

// Seen this recently: here now (the chip's dot). The gate writes
// last_used_at at most once a minute, so two minutes.
export const PRESENT_MS = 2 * 60 * 1000;
export const EXPIRY_DAYS = [1, 3, 7, 30];
export const DEFAULT_EXPIRY_DAYS = 7;

const DAY_MS = 24 * 60 * 60 * 1000;

// "in 6 days", "in 3 hours", "in 12 minutes", "ended".
export function untilText(iso, now) {
  const at = Date.parse(iso || "");
  if (!Number.isFinite(at)) return "";
  const left = at - now;
  if (left <= 0) return "ended";
  if (left >= 2 * DAY_MS) return `in ${Math.round(left / DAY_MS)} days`;
  if (left >= 2 * 60 * 60 * 1000) return `in ${Math.floor(left / (60 * 60 * 1000))} hours`;
  return `in ${Math.max(1, Math.round(left / 60000))} minutes`;
}

// "just now", "5 min ago", "3 h ago", "2 days ago", "never".
export function agoText(iso, now) {
  const at = Date.parse(iso || "");
  if (!Number.isFinite(at)) return "never";
  const ago = Math.max(0, now - at);
  if (ago < 60000) return "just now";
  if (ago < 60 * 60000) return `${Math.floor(ago / 60000)} min ago`;
  if (ago < DAY_MS) return `${Math.floor(ago / (60 * 60000))} h ago`;
  return `${Math.floor(ago / DAY_MS)} days ago`;
}

export const money = (n) => `$${(Number(n) || 0).toFixed(2)}`;

// One participant's row: what the panel says of a grant (Grant#public_h,
// with spend and turns).
export function rowModel(grant, now) {
  const active = grant.state === "active";
  const seen = Date.parse(grant.last_used_at || "");
  const present = active && Number.isFinite(seen) && now - seen < PRESENT_MS;
  const spend = Number(grant.spend) || 0;
  const cap = Number(grant.cap) || 0;
  return {
    id: grant.id,
    name: grant.name,
    kind: grant.kind,
    identity: typeof grant.identity === "string" ? grant.identity : null,
    active,
    present,
    color: authorColor(participantAuthor(grant.id)),
    state: active ? (present ? "here now" : `seen ${agoText(grant.last_used_at, now)}`)
      : grant.state === "expired" ? "expired" : `revoked${grant.revoked_by ? ` (${grant.revoked_by})` : ""}`,
    expires: active ? `expires ${untilText(grant.expires_at, now)}` : "",
    spend: `${money(spend)} of ${money(cap)}`,
    capReached: active && cap > 0 && spend >= cap,
    turns: `${grant.turns || 0} turn${grant.turns === 1 ? "" : "s"}`,
    cap,
  };
}

// The chip: "participants · invite" with nobody yet, else the active
// participants' count and a dot while one is here.
export function chipModel(grants, now) {
  if (!Array.isArray(grants)) return null;
  const active = grants.map((g) => rowModel(g, now)).filter((row) => row.active);
  if (active.length === 0) {
    return { text: "participants · invite", count: 0, present: false, title: "Invite a participant to review this session" };
  }
  const present = active.filter((row) => row.present).map((row) => row.name);
  const names = active.map((row) => row.name).join(", ");
  return {
    text: `${active.length} participant${active.length === 1 ? "" : "s"}`,
    count: active.length,
    present: present.length > 0,
    title: `Participants: ${names}${present.length ? ` (here now: ${present.join(", ")})` : ""}. Open the list.`,
  };
}

export function chipTemplate(chip) {
  if (!chip) return nothing;
  return html`<button type="button" class=${`model participants-chip${chip.count ? "" : " none"}${chip.present ? " present" : ""}`}
    title=${chip.title} aria-label=${chip.title} aria-haspopup="dialog" aria-expanded="false"><span class="pc-dot" aria-hidden="true"></span>${chip.text}</button>`;
}

// A cap field's dollars (a leading $ allowed): {value}, {value: null} when
// empty (the Invite then leaves the default cap), or {error}. Both forms read
// it, so one rule and one wording.
// @return {{value: number|null}|{error: string}}
export const CAP_ERROR = "A cap is dollars, 0 to 1000.";
export function capValue(text) {
  const clean = String(text ?? "").trim();
  if (!clean) return { value: null };
  const value = Number(clean.replace(/^\$/, ""));
  if (!Number.isFinite(value) || value < 0 || value > 1000) return { error: CAP_ERROR };
  return { value };
}

// An email as chi binds a link to it (Grants.clean_identity, which has the
// last word): one @, no spaces, commas, quotes or angle brackets.
const EMAIL_RE = /^[^@\s,<>"\\]+@[^@\s,<>"\\]+$/;

// What POST …/participants gets from the Invite form's values. +identity+
// (behind a proxy that names the user): their email, which binds the link;
// the name defaults to its local part.
// @return {{body}|{error}}
export function inviteBody({ name, kind, days, cap, identity }) {
  const email = String(identity || "").trim().toLowerCase();
  if (email && !EMAIL_RE.test(email)) return { error: "An email is one address: name@domain." };
  const clean = String(name || "").trim() || email.split("@")[0];
  if (!clean) return { error: "Give them a name: it is what the model and the thread show." };
  const body = { name: clean, kind: kind === "agent" ? "agent" : "human" };
  if (email) body.identity = email;
  const d = Number(days);
  body.ttl = Math.round((EXPIRY_DAYS.includes(d) ? d : DEFAULT_EXPIRY_DAYS) * 24 * 60 * 60);
  const capped = capValue(cap);
  if (capped.error) return { error: capped.error };
  if (capped.value !== null) body.cap = capped.value;
  return { body };
}

// The toast for an invite whose panel closed before its answer came.
export function lateInviteText(name, sessionId) {
  return `${name}'s review link for ${String(sessionId).slice(0, 8)} is ready (the panel closed before it came); it shows only once.`;
}

// What Revoke asks first: it can't be undone (chi keeps only the link's
// digest), as a delete asks.
export function revokeConfirmText(name) {
  return `Revoke ${name}'s link? Their page and stream stop and their queued comments are dropped. This can't be undone: a new invite gives a new link.`;
}

// The participant view's address: the participant page as the owner sees it.
export function viewURL(sessionId) {
  return `/?as=participant#s=${encodeURIComponent(sessionId)}`;
}

function rowTemplate(row, { capFor }) {
  const actions = row.active ? html`<span class="pp-actions">${capFor === row.id
    ? html`<form class="pp-cap-form" data-id=${row.id}><input name="cap" type="text" inputmode="decimal" autocomplete="off"
        aria-label=${`New cap for ${row.name}, dollars`} .value=${String(row.cap)}><button type="submit">Set</button></form>`
    : html`<button type="button" data-act="cap" data-id=${row.id} aria-label=${`Cap ${row.name}'s spending`}>Cap</button>`}<button
      type="button" class="pp-revoke" data-act="revoke" data-id=${row.id} aria-label=${`Revoke ${row.name}'s link`}
      title=${`End ${row.name}'s link: their page and stream stop, their queued comments are dropped`}>Revoke</button></span>`
    : nothing;
  return html`<li class=${`pp-row${row.active ? "" : " ended"}`} style=${`--author-color:${row.color}`}>
    <div class="pp-who"><span class=${`pp-dot${row.present ? " present" : ""}`} aria-hidden="true"></span><b>${row.name}</b>${
      row.kind === "agent" ? html`<span class="pp-tag">agent</span>` : nothing}<span class="pp-state">${row.state}</span></div>
    <div class="pp-meta"><span class=${row.capReached ? "pp-capped" : ""}>${row.spend}</span> · ${row.turns}${
      row.expires ? html` · ${row.expires}` : nothing}${row.identity ? html` · <span class="pp-bound">bound to ${row.identity}</span>` : nothing}</div>${actions}</li>`;
}

function inviteTemplate(invite, { canShare }) {
  if (!invite) return nothing;
  return html`<div class="pp-invite-done">
    <div class="ctx-pop-meta">${invite.name}'s link: shown once (chi keeps only its digest). It opens this session only${
      invite.identity ? `, for ${invite.identity} only` : ""}.${
      invite.lan ? nothing : " This chi web has no LAN address: the link opens on this machine only."}</div>
    ${invite.warning ? html`<div class="pp-warning" role="note">${invite.warning}</div>` : nothing}
    <div class="pp-link"><input readonly .value=${invite.link} aria-label="The review link" @focus=${(e) => e.target.select()}><button
      type="button" data-act="copy">${invite.copied ? "Copied ✓" : "Copy"}</button>${canShare
      ? html`<button type="button" data-act="share">Share…</button>` : nothing}</div>
    ${invite.qr_svg ? html`<div class="pp-qr" .innerHTML=${invite.qr_svg}></div>` : nothing}</div>`;
}

// The empty list's line, by the session's mode.
export const EMPTY_REVIEW = "Nobody yet. Invite a person (or an agent) to review: their comments become read-only review turns; you see and approve everything.";
export const EMPTY_PAIR = "Nobody yet. Invite a person (or an agent) to work with you here: their turns act with this session's tools under your guardrails, and their asks come to you.";

// The popover's content: the participants, the Invite form (or the link it
// gave), the participant view.
// +working+: the server's warning for a session that isn't a review session
// (shown before the Invite, with Start a review of it), null for one.
// +pair+: a participant invited now gets pair turns (the list's mode: a
// working session on a worker with pair turns): the empty list says their
// turns act; otherwise (a review session, an older worker) that they read.
// +identityHeader+: the header chi web's auth proxy names the signed-in
// user in (the list's identity_header), null without one: then the Invite
// has no email field (a bound link could never open).
export function panelTemplate(grants, { now, sessionId, invite = null, error = null, capFor = null, canShare = false,
                                        busy = false, working = null, reviewing = false, identityHeader = null,
                                        pair = false } = {}) {
  const rows = (grants || []).map((g) => rowModel(g, now));
  const active = rows.filter((row) => row.active);
  const ended = rows.filter((row) => !row.active);
  return html`<div class="ctx-pop-head"><strong>Participants</strong><span class="ctx-pop-kind">this session</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>
    ${active.length ? html`<ul class="pp-list">${active.map((row) => rowTemplate(row, { capFor }))}</ul>`
      : html`<div class="ctx-pop-meta">${pair ? EMPTY_PAIR : EMPTY_REVIEW}</div>`}
    ${ended.length ? html`<details class="pp-ended"><summary>Ended (${ended.length})</summary><ul class="pp-list">${
      ended.map((row) => rowTemplate(row, { capFor }))}</ul></details>` : nothing}
    <div class="ctx-pop-error" role="alert" ?hidden=${!error}>${error || ""}</div>
    ${working && !invite ? html`<div class="pp-warning pp-working" role="note">${working}<button type="button"
      data-act="start-review" ?disabled=${reviewing}>${reviewing ? "Starting…" : "Start a review of it"}</button></div>` : nothing}
    ${invite ? inviteTemplate(invite, { canShare }) : html`<form class="pp-invite">
      <div class="pp-invite-row"><input name="name" type="text" placeholder="Name (Alex)" autocomplete="off" aria-label="Their name" maxlength="64"
      ><span class="select-wrap"><select name="kind" aria-label="A person or an agent"><option value="human">person</option><option value="agent">agent</option></select></span></div>
      ${identityHeader ? html`<div class="pp-invite-row"><input name="identity" type="email" placeholder="Their email (alex@example.com)"
        autocomplete="off" aria-label="Their email: the link opens only for that account"></div>
      <div class="ctx-pop-meta pp-bind-note">With their email the link opens only for them, signed in through the proxy.
        Without one, anyone the proxy lets in who gets the link can open it.</div>` : nothing}
      <div class="pp-invite-row"><label>Expires <span class="select-wrap"><select name="days">${EXPIRY_DAYS.map((d) => html`<option value=${d}
        ?selected=${d === DEFAULT_EXPIRY_DAYS}>${d === 1 ? "1 day" : `${d} days`}</option>`)}</select></span></label
      ><label>Cap $<input name="cap" type="text" inputmode="decimal" placeholder="2" autocomplete="off" aria-label="Spending cap, dollars"></label
      ><button type="submit" class="pp-invite-btn" ?disabled=${busy}>Invite</button></div></form>`}
    <div class="ctx-pop-actions pp-foot">${invite ? html`<button type="button" data-act="another">Invite another</button>` : nothing}<a
      class="pp-view" href=${viewURL(sessionId)} target="_blank" rel="noopener"
      title="The participant page for this session, as a participant sees it: through the same filter">Participant view ↗</a></div>`;
}

// The control: el (#infoText, where the chip is drawn), session() the open
// session's id, api {list(id), invite(id, body), revoke(id, pid), cap(id,
// pid, cap)}, onChange() (the chip's count or presence changed: redraw the
// bar), toast(text, action, {sticky}) (app.js showToast), onNames() (the participants' names changed: name the
// badges drawn before them, participant_names.js nameUnnamedBadges).
// startReview({onError}): Start a review of it (a review fork of the open
// session): the created session, or null (its refusal to onError(text), true
// when the panel showed it); reviewing(): one is under way for the open
// session (session_actions.js keeps the one-per-session guard).
export function createParticipantsControl({ el, session, api, onChange = () => {}, toast = () => {}, startReview = null,
                                            reviewing = () => false, onNames = () => {}, clock = () => Date.now(), doc = document, win = window }) {
  let grants = null;
  // The open session's share warning (GET …/participants), null for a
  // review session.
  let working = null;
  // What a participant invited now gets (GET …/participants mode: "pair" or
  // "review", the server's ReviewStart.share_terms), never guessed from the warning.
  let inviteMode = null;
  // The header chi web's proxy names the user in (GET …/participants), null
  // without one: the Invite's email field.
  let identityHeader = null;
  // Where a participant's link opens, no token (GET …/participants
  // link_base): a claim link's base (claimTarget).
  let linkBase = null;
  let loadedFor = null;
  let invite = null;
  let error = null;
  let capFor = null;
  let busy = false;
  // Bumped by each close: an invite, cap or revoke answered after its panel
  // closed (or another session opened) is dropped, so a one-time link never
  // shows in a later panel, another session's.
  let visit = 0;
  const ask = () => ({ id: session(), visit });
  const stillOpen = (asked) => asked.id === session() && asked.visit === visit;
  // A dropped answer still moves the chip (a count, a spend) of its session.
  const dropped = (asked) => (asked.id === session() ? load() : undefined);

  const shell = createChipPopover({
    id: "participantsPopover", className: "ctx-popover participants-popover", width: 380, el, anchor: ".participants-chip",
    label: "Participants",
    summary: () => (session() && grants ? grants : null), session, sheet: true, doc, win,
    show: () => draw(),
    onClose: () => { visit += 1; invite = null; error = null; capFor = null; },
    onSubmit: (form) => (form.classList.contains("pp-cap-form") ? submitCap(form) : submitInvite(form)),
    onAct: (name) => act(name),
  });
  // Opening the panel reads the list again (last seen, spend and turns
  // move while it is closed); the open form redraws when it comes.
  el.addEventListener("click", (e) => { if (e.target.closest(".participants-chip")) load(); });
  // The act's participant: the clicked row's id (data-id).
  let actId = null;
  shell.pop.addEventListener("click", (e) => { actId = e.target.closest("[data-id]")?.dataset.id || null; }, true);

  function draw() {
    render(panelTemplate(grants, { now: clock(), sessionId: session(), invite, error, capFor, busy,
                                   working: startReview ? working : null, pair: inviteMode === "pair", reviewing: reviewing(), identityHeader,
                                   canShare: typeof win.navigator?.share === "function" }), shell.pop);
    shell.replace();
  }

  async function load(id = session()) {
    if (!id) {
      grants = null;
      working = null;
      inviteMode = null;
      linkBase = null;
      loadedFor = null;
      setParticipantNames([]);
      onChange();
      return;
    }
    const still = stillOn(session, id);
    try {
      const body = await api.list(id);
      if (!still()) return;
      grants = Array.isArray(body.participants) ? body.participants : [];
      working = typeof body.warning === "string" ? body.warning : null;
      inviteMode = typeof body.mode === "string" ? body.mode : null;
      identityHeader = typeof body.identity_header === "string" && body.identity_header ? body.identity_header : null;
      linkBase = typeof body.link_base === "string" && body.link_base ? body.link_base : null;
      loadedFor = id;
      if (setParticipantNames(grants)) onNames();
    } catch {
      if (!still()) return;
      // Another session's list and warning are not this one's.
      if (loadedFor !== id) {
        grants = [];
        working = null;
        inviteMode = null;
        linkBase = null;
        setParticipantNames([]);
      }
    }
    onChange();
    if (shell.isOpen()) draw();
  }

  async function submitInvite(form) {
    const values = Object.fromEntries(["name", "kind", "days", "cap", "identity"].map((k) => [k, form.elements[k]?.value]));
    const { body, error: problem } = inviteBody(values);
    if (problem) {
      error = problem;
      return draw();
    }
    busy = true;
    draw();
    const asked = ask();
    try {
      const answer = await api.invite(asked.id, body);
      if (!stillOpen(asked)) {
        lateInvite(asked, answer.participant?.name || body.name, answer.link);
        return dropped(asked);
      }
      invite = { name: answer.participant?.name || body.name, link: answer.link, qr_svg: answer.qr_svg, lan: answer.lan,
                 warning: answer.warning || null, identity: answer.participant?.identity || null, copied: false };
      error = null;
    } catch (err) {
      if (!stillOpen(asked)) return dropped(asked);
      error = err.message;
    } finally {
      busy = false;
    }
    await load();
    if (shell.isOpen()) draw();
  }

  // An invite answered after its panel closed: the grant exists and its link
  // shows only once, so a sticky toast keeps it (Copy link; a failed copy
  // shows the link itself to select), never a later panel.
  function lateInvite(asked, name, link) {
    if (!link) return;
    const copy = async () => {
      try {
        await win.navigator.clipboard.writeText(link);
        toast(`${name}'s review link copied`);
      } catch {
        toast(`${name}'s review link: ${link}`, null, { sticky: true });
      }
    };
    toast(lateInviteText(name, asked.id), { label: "Copy link", run: copy }, { sticky: true });
  }

  async function submitCap(form) {
    // A cleared field is no cap to set (Number("") would be a $0 cap).
    const { value, error: problem } = capValue(form.elements.cap.value);
    if (problem || value == null) {
      error = CAP_ERROR;
      return draw();
    }
    const asked = ask();
    try {
      await api.cap(asked.id, form.dataset.id, value);
      if (!stillOpen(asked)) return dropped(asked);
      capFor = null;
      error = null;
    } catch (err) {
      if (!stillOpen(asked)) return dropped(asked);
      error = err.message;
    }
    await load();
  }

  async function act(name) {
    // The cap's field takes the focus (the Cap button it replaced is gone).
    if (name === "cap") {
      capFor = actId;
      draw();
      shell.pop.querySelector(".pp-cap-form input")?.focus();
      return;
    }
    if (name === "revoke" && actId) {
      const who = (grants || []).find((g) => g.id === actId)?.name || "this participant";
      if (!win.confirm(revokeConfirmText(who))) return;
      const asked = ask();
      try {
        await api.revoke(asked.id, actId);
        if (!stillOpen(asked)) return dropped(asked);
        error = null;
      } catch (err) {
        if (!stillOpen(asked)) return dropped(asked);
        error = err.message;
      }
      return load();
    }
    // Closed once the review is made; a refusal stays in the panel.
    if (name === "start-review" && startReview) {
      const asked = ask();
      const showError = (text) => {
        if (!stillOpen(asked) || !shell.isOpen()) return false;
        error = text;
        return true;
      };
      const started = startReview({ onError: showError });
      draw();
      const created = await started;
      if (created) shell.close();
      else if (stillOpen(asked) && shell.isOpen()) draw();
      return;
    }
    if (name === "another") {
      invite = null;
      return draw();
    }
    if (name === "copy" && invite) {
      try {
        await win.navigator.clipboard.writeText(invite.link);
        invite = { ...invite, copied: true };
      } catch {
        toast("Couldn't copy: select the link and copy it");
      }
      return draw();
    }
    if (name === "share" && invite) {
      try {
        await win.navigator.share({ title: "chi review", text: `${invite.name}'s review link`, url: invite.link });
      } catch {
        // dismissed
      }
    }
  }

  return {
    load,
    // A participants_changed event, or a session's own refresh.
    reload: () => load(),
    chip: () => (session() && loadedFor === session() ? chipModel(grants, clock()) : null),
    // A claim link's target (claim_link.js): {base, names} the open
    // session's participant link base and its active people's names (an
    // agent has no browser to open it in); null without either (an older
    // chi web, no person invited).
    claimTarget: () => {
      if (!session() || loadedFor !== session() || !linkBase) return null;
      const names = (grants || []).filter((g) => g.state === "active" && g.kind === "human").map((g) => g.name);
      return names.length ? { base: linkBase, names } : null;
    },
    close: () => shell.close(),
    isOpen: () => shell.isOpen(),
  };
}
