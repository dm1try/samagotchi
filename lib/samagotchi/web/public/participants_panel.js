// The owner's participants (docs/internals/participants.md): the info
// bar's chip (how many, someone here now) and its popover, the panel: each
// participant's state, expiry, spend against their cap, turns and when they
// were last seen, with Revoke and a new cap; Invite (name, person or agent,
// expiry, cap) gives the link once, to copy, share (a phone's share sheet)
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
import { authorColor } from "./participant_model.js";
import { setParticipantNames } from "./participant_names.js";

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
    active,
    present,
    color: authorColor(`p:${grant.id}`),
    state: active ? (present ? "here now" : `seen ${agoText(grant.last_used_at, now)}`)
      : grant.state === "expired" ? "expired" : `revoked${grant.revoked_by ? ` (${grant.revoked_by})` : ""}`,
    expires: active ? `expires ${untilText(grant.expires_at, now)}` : "",
    spend: `${money(spend)} of ${money(cap)}`,
    capReached: active && cap > 0 && spend >= cap,
    turns: `${grant.turns || 0} turn${grant.turns === 1 ? "" : "s"}`,
    cap,
  };
}

// The chip: "invite" with nobody yet, else the active participants' count
// and a dot while one is here.
export function chipModel(grants, now) {
  if (!Array.isArray(grants)) return null;
  const active = grants.map((g) => rowModel(g, now)).filter((row) => row.active);
  if (active.length === 0) {
    return { text: "invite", count: 0, present: false, title: "Invite a participant to review this session" };
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
    title=${chip.title} aria-label=${chip.title} aria-haspopup="dialog"><span class="pc-dot" aria-hidden="true"></span>${chip.text}</button>`;
}

// What POST …/participants gets from the Invite form's values.
// @return {{body}|{error}}
export function inviteBody({ name, kind, days, cap }) {
  const clean = String(name || "").trim();
  if (!clean) return { error: "Give them a name: it is what the model and the thread show." };
  const body = { name: clean, kind: kind === "agent" ? "agent" : "human" };
  const d = Number(days);
  body.ttl = Math.round((EXPIRY_DAYS.includes(d) ? d : DEFAULT_EXPIRY_DAYS) * 24 * 60 * 60);
  const capText = String(cap ?? "").trim();
  if (capText) {
    const value = Number(capText.replace(/^\$/, ""));
    if (!Number.isFinite(value) || value < 0 || value > 1000) return { error: "A cap is dollars, 0 to 1000." };
    body.cap = value;
  }
  return { body };
}

// The participant view's address: the participant page as the owner sees it.
export function viewURL(sessionId) {
  return `/?as=participant#s=${encodeURIComponent(sessionId)}`;
}

function rowTemplate(row, { capFor }) {
  const actions = row.active ? html`<span class="pp-actions">${capFor === row.id
    ? html`<form class="pp-cap-form" data-id=${row.id}><input name="cap" type="text" inputmode="decimal" autocomplete="off"
        aria-label=${`New cap for ${row.name}, dollars`} .value=${String(row.cap)}><button type="submit">Set</button></form>`
    : html`<button type="button" data-act="cap" data-id=${row.id}>Cap</button>`}<button type="button" class="pp-revoke"
      data-act="revoke" data-id=${row.id} title=${`End ${row.name}'s link: their page and stream stop, their queued comments are dropped`}>Revoke</button></span>`
    : nothing;
  return html`<li class=${`pp-row${row.active ? "" : " ended"}`} style=${`--author-color:${row.color}`}>
    <div class="pp-who"><span class=${`pp-dot${row.present ? " present" : ""}`} aria-hidden="true"></span><b>${row.name}</b>${
      row.kind === "agent" ? html`<span class="pp-tag">agent</span>` : nothing}<span class="pp-state">${row.state}</span></div>
    <div class="pp-meta"><span class=${row.capReached ? "pp-capped" : ""}>${row.spend}</span> · ${row.turns}${
      row.expires ? html` · ${row.expires}` : nothing}</div>${actions}</li>`;
}

function inviteTemplate(invite, { canShare }) {
  if (!invite) return nothing;
  return html`<div class="pp-invite-done">
    <div class="ctx-pop-meta">${invite.name}'s link: shown once (chi keeps only its digest). It opens this session only.${
      invite.lan ? nothing : " This chi web has no LAN address: the link opens on this machine only."}</div>
    <div class="pp-link"><input readonly .value=${invite.link} aria-label="The review link" @focus=${(e) => e.target.select()}><button
      type="button" data-act="copy">${invite.copied ? "Copied ✓" : "Copy"}</button>${canShare
      ? html`<button type="button" data-act="share">Share…</button>` : nothing}</div>
    ${invite.qr_svg ? html`<div class="pp-qr" .innerHTML=${invite.qr_svg}></div>` : nothing}</div>`;
}

// The popover's content: the participants, the Invite form (or the link it
// gave), the participant view.
export function panelTemplate(grants, { now, sessionId, invite = null, error = null, capFor = null, canShare = false,
                                        busy = false } = {}) {
  const rows = (grants || []).map((g) => rowModel(g, now));
  const active = rows.filter((row) => row.active);
  const ended = rows.filter((row) => !row.active);
  return html`<div class="ctx-pop-head"><strong>Participants</strong><span class="ctx-pop-kind">this session</span
    ><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>
    ${active.length ? html`<ul class="pp-list">${active.map((row) => rowTemplate(row, { capFor }))}</ul>`
      : html`<div class="ctx-pop-meta">Nobody yet. Invite a person (or an agent) to review: their comments become read-only review turns; you see and approve everything.</div>`}
    ${ended.length ? html`<details class="pp-ended"><summary>Ended (${ended.length})</summary><ul class="pp-list">${
      ended.map((row) => rowTemplate(row, { capFor }))}</ul></details>` : nothing}
    <div class="ctx-pop-error" ?hidden=${!error}>${error || ""}</div>
    ${invite ? inviteTemplate(invite, { canShare }) : html`<form class="pp-invite">
      <div class="pp-invite-row"><input name="name" type="text" placeholder="Name (Alex)" autocomplete="off" aria-label="Their name" maxlength="64"
      ><select name="kind" aria-label="A person or an agent"><option value="human">person</option><option value="agent">agent</option></select></div>
      <div class="pp-invite-row"><label>Expires <select name="days">${EXPIRY_DAYS.map((d) => html`<option value=${d}
        ?selected=${d === DEFAULT_EXPIRY_DAYS}>${d === 1 ? "1 day" : `${d} days`}</option>`)}</select></label
      ><label>Cap $<input name="cap" type="text" inputmode="decimal" placeholder="2" autocomplete="off" aria-label="Spending cap, dollars"></label
      ><button type="submit" class="pp-invite-btn" ?disabled=${busy}>Invite</button></div></form>`}
    <div class="ctx-pop-actions pp-foot">${invite ? html`<button type="button" data-act="another">Invite another</button>` : nothing}<a
      class="pp-view" href=${viewURL(sessionId)} target="_blank" rel="noopener"
      title="The participant page for this session, as a participant sees it: through the same filter">Participant view ↗</a></div>`;
}

// The control: el (#infoText, where the chip is drawn), session() the open
// session's id, api {list(id), invite(id, body), revoke(id, pid), cap(id,
// pid, cap)}, onChange() (the chip's count or presence changed: redraw the
// bar), toast(text).
export function createParticipantsControl({ el, session, api, onChange = () => {}, toast = () => {},
                                            clock = () => Date.now(), doc = document, win = window }) {
  let grants = null;
  let loadedFor = null;
  let invite = null;
  let error = null;
  let capFor = null;
  let busy = false;

  const shell = createChipPopover({
    id: "participantsPopover", className: "ctx-popover participants-popover", width: 380, el, anchor: ".participants-chip",
    summary: () => (session() && grants ? grants : null), session, sheet: true, doc, win,
    show: () => draw(),
    onClose: () => { invite = null; error = null; capFor = null; },
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
                                   canShare: typeof win.navigator?.share === "function" }), shell.pop);
    shell.replace();
  }

  async function load(id = session()) {
    if (!id) {
      grants = null;
      loadedFor = null;
      onChange();
      return;
    }
    try {
      const body = await api.list(id);
      if (id !== session()) return;
      grants = Array.isArray(body.participants) ? body.participants : [];
      loadedFor = id;
      setParticipantNames(grants);
    } catch {
      if (id !== session()) return;
      grants = grants && loadedFor === id ? grants : [];
    }
    onChange();
    if (shell.isOpen()) draw();
  }

  async function submitInvite(form) {
    const values = Object.fromEntries(["name", "kind", "days", "cap"].map((k) => [k, form.elements[k]?.value]));
    const { body, error: problem } = inviteBody(values);
    if (problem) {
      error = problem;
      return draw();
    }
    busy = true;
    draw();
    try {
      const answer = await api.invite(session(), body);
      invite = { name: answer.participant?.name || body.name, link: answer.link, qr_svg: answer.qr_svg, lan: answer.lan, copied: false };
      error = null;
    } catch (err) {
      error = err.message;
    } finally {
      busy = false;
    }
    await load();
    draw();
  }

  async function submitCap(form) {
    const value = Number(String(form.elements.cap.value).trim().replace(/^\$/, ""));
    if (!Number.isFinite(value)) {
      error = "A cap is dollars, 0 to 1000.";
      return draw();
    }
    try {
      await api.cap(session(), form.dataset.id, value);
      capFor = null;
      error = null;
    } catch (err) {
      error = err.message;
    }
    await load();
  }

  async function act(name) {
    if (name === "cap") {
      capFor = actId;
      return draw();
    }
    if (name === "revoke" && actId) {
      try {
        await api.revoke(session(), actId);
        error = null;
      } catch (err) {
        error = err.message;
      }
      return load();
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
    close: () => shell.close(),
    isOpen: () => shell.isOpen(),
  };
}
