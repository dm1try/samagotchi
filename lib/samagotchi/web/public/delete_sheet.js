// Deleting a link of a session chain (docs/sessions.md, Session chains →
// Deleting a link): Delete on a chained session asks which, instead of the
// browser's confirm. "Delete this link" (first, the default) undoes the
// newest link's continue or splits the chain at a middle one; "Delete the
// whole chain" takes every link. Each says what it leaves behind.
//
// The sheet's words come from GET /api/sessions/:id/delete_plan, the plan
// and refusals the server's delete itself runs (SessionChain::Delete::
// Preview), fetched as the sheet opens and only for a chained session: a
// session in no chain keeps today's confirm (session_actions.js). The
// confirmed digest is checked by the delete; a changed plan is re-read and
// shown for a fresh confirmation.
//
// Where it is drawn (a host): the ⋯ More panel turns into it, with ‹ More to
// go back (more_sheet.js' subview); a card's ✕ opens it at the card, on
// chip_popover.js' shell (createDeleteSheet): a bottom sheet on a phone, a
// popover on a wider window. Pure model and templates plus createDeleteSheet
// and runDeleteFlow, so the specs run them under node --test.

import { html, nothing, render } from "./vendor/lit-html.js";
import { createChipPopover } from "./chip_popover.js";
import { cardName, clip, normalize } from "./format.js";

const short = (id) => String(id ?? "").slice(0, 8);
const count = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

// A session is in a chain when it continues a link, or a listed one
// continues it (the page's list holds archived links too).
export function isChained(session, list = []) {
  if (!session) return false;
  if (session.continues) return true;
  return list.some((s) => s.continues === session.id);
}

// The session's name as today's confirm says it (format.js cardName).
function sessionName(session) {
  const name = normalize(session ? cardName(session) : "");
  return clip(name, 41);
}

// What this link's own delegates do (D7): stopped ones go, running ones stay.
function delegatesWords(deletes, running, { lead }) {
  const parts = [];
  if (deletes) parts.push(`${lead}${count(deletes, "stopped delegate")}`);
  const goes = parts.length ? `${parts.join("")}` : "";
  const stays = running ? `${count(running, "running delegate")} ${running === 1 ? "keeps" : "keep"} running on ${running === 1 ? "its" : "their"} own` : "";
  return { goes, stays };
}

function thisLinkLines(link) {
  const { goes, stays } = delegatesWords(link.deletes, link.left_running, { lead: "its " });
  if (link.previous_id) {
    const took = [link.moved && count(link.moved, "delegate"), link.notes && count(link.notes, "unread note")].filter(Boolean);
    const main = `Undoes the continue: ${short(link.previous_id)} comes back to the lists (not started)` +
      (took.length ? `, with what this link took over from it — its ${took.join(" and ")}.` : ".");
    const own = [goes ? `its turns and ${goes}` : "its turns"].join("");
    return [main, `What this link did itself goes: ${own}.${stays ? ` Its ${stays}.` : ""}`];
  }
  let main;
  if (link.next_id) {
    const earlier = link.earlier ? `${count(link.earlier, "earlier link")} ${link.earlier === 1 ? "stays" : "stay"} archived, and ` : "";
    main = `The chain splits: ${earlier}${short(link.next_id)} goes on as a chain of its own.`;
  } else {
    main = "The earlier links stay as they are.";
  }
  const rest = [goes && `${goes.charAt(0).toUpperCase()}${goes.slice(1)} ${link.deletes === 1 ? "goes" : "go"} with it.`,
                stays && `${stays.charAt(0).toUpperCase()}${stays.slice(1)}.`].filter(Boolean).join(" ");
  return [main, `Nothing is undone.${rest ? ` ${rest}` : ""}`];
}

function chainLines(plan) {
  const { chain } = plan;
  const delegates = chain.deletes ? ` and their ${count(chain.deletes, "stopped delegate")}` : "";
  const running = chain.left_running
    ? ` ${count(chain.left_running, "running delegate")} ${chain.left_running === 1 ? "keeps" : "keep"} running on ${chain.left_running === 1 ? "its" : "their"} own.`
    : "";
  const lines = [plan.cut_off
    ? `These ${count(chain.links, "link")}${delegates ? `, ${delegates.trim()}` : ""}.${running}`
    : `All ${count(chain.links, "link")}${delegates}.${running}`];
  return lines;
}

// Why a choice can't be taken now, in the sheet's words; a schedule says it
// once, above both.
function refusedWhy(refusal) {
  if (!refusal) return null;
  if (refusal.reason === "scheduled" || refusal.reason === "chain_scheduled") return "Not while a schedule runs the chain.";
  return refusal.message || "Not now.";
}

// The sheet's model for +session+ from its delete plan (the route's JSON).
// @return {title, sub, banner, choices: [{act, label, lines, warn, disabled, why, primary}], foot}
export function deleteChoices(session, plan) {
  const id = session?.id ?? plan.session_id;
  const name = sessionName(session);
  const link = plan.link || {};
  const chain = plan.chain || {};
  // The chain's words first: they say the schedule runs this chain.
  const scheduled = [chain.refusal, link.refusal].find((r) => r && /scheduled$/.test(r.reason));
  return {
    title: `Delete ${short(id)}${name ? ` — "${name}"` : ""}?`,
    sub: `It is link ${plan.position} of ${plan.size} of its chain. This can't be undone.`,
    banner: scheduled ? `${scheduled.message.charAt(0).toUpperCase()}${scheduled.message.slice(1)}.` : null,
    choices: [
      { act: "this", label: "Delete this link", lines: thisLinkLines(link), primary: true,
        disabled: !!link.refusal && link.refusal.reason !== "delegate_unmovable", why: refusedWhy(link.refusal) },
      { act: "chain", label: `Delete the whole chain · ${count(chain.links, "session")}`, lines: chainLines(plan),
        warn: plan.cut_off ? "Earlier links, cut off by a deleted link, are kept (archived)." : null,
        disabled: !!chain.refusal, why: refusedWhy(chain.refusal) },
    ],
    foot: "Running workers are stopped first.",
  };
}

function unchainedChoices(session, plan) {
  const id = session?.id ?? plan?.session_id;
  const name = sessionName(session);
  return {
    title: `Delete ${short(id)}${name ? ` — "${name}"` : ""}?`,
    sub: "This session is no longer in a chain. This can't be undone.",
    banner: null,
    choices: [{ act: "this", label: "Delete this session", lines: ["Its turns and session data will be permanently deleted."],
                primary: true }],
    foot: "This can't be undone.",
  };
}

function choiceTemplate(choice) {
  const cls = `ds-choice${choice.primary ? " primary" : ""}`;
  if (choice.disabled) {
    return html`<button type="button" class=${cls} data-act=${`del:${choice.act}`} disabled
      ><span class="ds-label">${choice.label}</span><span class="ds-line">${choice.why}</span></button>`;
  }
  return html`<button type="button" class=${cls} data-act=${`del:${choice.act}`}
    ><span class="ds-label">${choice.label}</span>${choice.lines.map((line, i) => html`<span class=${i ? "ds-line dim" : "ds-line"}>${line}</span>`)
    }${choice.warn ? html`<span class="ds-line warn">${choice.warn}</span>` : nothing}</button>`;
}

// The back row: ‹ More in the More panel, a close × on a card's.
function headTemplate(back) {
  // The More panel's grip stays on top, as on its list (more-grip).
  return back
    ? html`<div class="more-grip" aria-hidden="true"></div><div class="ds-head"><button type="button" class="ds-back" data-act="del:back">‹ More</button></div>`
    : html`<div class="ds-head"><span></span><button type="button" class="ctx-pop-close" data-act="del:cancel" aria-label="Close">×</button></div>`;
}

// The choices (a lit-html template). +busy+: a delete under way (every
// button off); +back+: drawn in the More panel.
export function deleteSheetTemplate(model, { back = false, busy = false, notice = null } = {}) {
  const allOff = model.choices.every((c) => c.disabled);
  return html`<div class=${`delete-sheet${busy ? " busy" : ""}`}>${headTemplate(back)}
    <div class="ds-title">${model.title}</div>
    <div class="ds-sub">${model.sub}</div>
    ${notice ? html`<div class="ds-banner">${notice}</div>` : nothing}
    ${model.banner ? html`<div class="ds-banner">${model.banner}</div>` : nothing}
    <div class="ds-choices" ?inert=${busy}>${model.choices.map(choiceTemplate)}</div>
    <div class="ds-foot">${allOff ? html`<span></span>` : html`<span class="ds-note">${busy ? "Deleting…" : model.foot}</span>`}
      <button type="button" class="ds-cancel" data-act="del:cancel" ?disabled=${busy}>${allOff ? "Close" : "Cancel"}</button></div>
  </div>`;
}

// While the plan is read.
export function loadingTemplate({ back = false } = {}) {
  return html`<div class="delete-sheet">${headTemplate(back)}<div class="ds-sub">Reading what this delete would do…</div></div>`;
}

// A refused delete, in the sheet: a moved delegate that can't go back
// (delegate_unmovable: "Stop its worker, then delete" only when the page
// can stop it, not a one-turn run's), or any other refusal's own words.
// @param refusal {reason, message, ids, stoppable}
// @param previousId the link the delegate would go back to
export function refusalModel(refusal, previousId = null) {
  if (refusal?.reason === "delegate_unmovable") {
    const id = (refusal.ids || [])[0];
    const back = previousId ? short(previousId) : "the previous link";
    const why = refusal.stoppable
      ? "runs on an older chi worker that can't be moved back"
      : "is in a one-turn chi --non-interactive run; let it finish first";
    return {
      title: `Can't give ${short(id)} back`,
      text: `The delegate ${short(id)}, which this link took over from ${back}, ${why}. Nothing was deleted.`,
      stop: refusal.stoppable
        ? { label: "Stop its worker, then delete",
            line: `Its old worker stops (a running turn ends as stopped); it goes back to ${back} and starts on this chi next time.` }
        : null,
    };
  }
  return { title: "Not deleted", text: refusal?.message || "The delete was refused.", stop: null };
}

export function refusalTemplate(model, { back = false } = {}) {
  return html`<div class="delete-sheet">${headTemplate(back)}
    <div class="ds-title">${model.title}</div>
    <div class="ds-sub">${model.text}</div>
    ${model.stop ? html`<div class="ds-choices"><button type="button" class="ds-choice primary" data-act="del:stop"
      ><span class="ds-label">${model.stop.label}</span><span class="ds-line dim">${model.stop.line}</span></button></div>` : nothing}
    <div class="ds-foot"><span></span><button type="button" class="ds-cancel" data-act="del:cancel">${model.stop ? "Cancel" : "Close"}</button></div>
  </div>`;
}

// The toast after a delete (D1/D5's words). +which+: "this" or "chain";
// +result+: the route's 200; +plan+: the sheet's.
// @return {text, back} (back: the link to offer opening, or null)
export function deleteToast(which, result, plan, id) {
  if (which === "chain") {
    const left = (result.left || []).length;
    const links = Math.max(0, (plan.chain?.links ?? 0) - left);
    const delegates = Math.max(0, (result.deleted || []).length - links);
    let text = `Deleted the chain: ${count(links, "session")}${delegates ? ` and ${count(delegates, "delegate")}` : ""}.`;
    const running = (result.left_running || []).length;
    if (running) text += ` ${count(running, "running delegate")} ${running === 1 ? "was" : "were"} left on ${running === 1 ? "its" : "their"} own.`;
    if (left) text += ` ${count(left, "link")} kept: ${result.refusal}`;
    return { text, back: null };
  }
  const back = (result.unarchived || [])[0] || null;
  if (!back) return { text: `Deleted ${short(id)}.`, back: null };
  // The sheet's count (each moved delegate with its subtree) when it had one.
  const moved = (result.moved_back || []).length ? (plan.link?.moved || result.moved_back.length) : 0;
  const took = [moved && count(moved, "delegate"),
                plan.link?.notes && count(plan.link.notes, "note")].filter(Boolean);
  return { text: `Deleted ${short(id)}. ${short(back)} is back${took.length ? `, with ${took.join(" and ")}` : ""}.`, back };
}

// The list after a delete: the deleted ids gone, the ones back in the lists
// not archived (session_actions.js' markArchived's flip).
export function listAfterDelete(list, result) {
  const gone = new Set(result.deleted || [result.session_id]);
  const back = new Set(result.unarchived || []);
  return list.filter((s) => !gone.has(s.id)).map((s) => (back.has(s.id) ? { ...s, archived: false } : s));
}

// The flow in a +host+ ({show(template), close(), back: whether it is the
// More panel}): reads the plan, shows the choices, runs the one chosen, and
// shows a refusal in place. +act+ is wired by the host to the returned
// handler. Hooks: api {deletePlan, deleteSession, deleteChain, stopSession};
// done(which, result, plan) after a delete; plain() when the plan says no
// chain (today's confirm); failed(error) when the plan can't be read.
// @return {act(name)} the host's handler for its data-act="del:*"
export function runDeleteFlow({ id, session, host, api, done, plain, failed }) {
  let plan = null;
  let model = null;
  let notice = null;
  let refusal = null;
  let busy = false;
  const back = !!host.back;
  // Whether +host+ still shows this flow: another session's sheet opened in
  // the same shell since (a second card's ✕, the More panel on another
  // session) takes it, and this flow then draws and acts on nothing.
  const live = () => (host.live ? host.live() : true);
  const show = (tpl) => { if (live()) host.show(tpl); };

  const showChoices = () => show(deleteSheetTemplate(model, { back, busy, notice }));
  const showRefusal = () => show(refusalTemplate(refusalModel(refusal, plan?.link?.previous_id), { back }));

  show(loadingTemplate({ back }));
  api.deletePlan(id).then((read) => {
    if (!live()) return;
    if (!read?.chained) { host.close(); plain(); return; }
    plan = read;
    model = deleteChoices(session, plan);
    showChoices();
  }, (error) => { if (live()) { host.close(); failed(error); } });

  // The refusal as the delete's 409 says it; whether the page can stop a
  // moved delegate's worker is its +stoppable+, as the delete saw it.
  function refused(error) {
    refusal = { reason: error.code, message: error.message, ids: error.body?.ids || [], stoppable: error.body?.stoppable === true };
    busy = false;
    showRefusal();
  }

  async function run(which) {
    if (busy || !live()) return;
    busy = true;
    showChoices();
    try {
      const digest = which === "chain" ? plan?.chain?.digest : plan?.link?.digest;
      const result = which === "chain" ? await api.deleteChain(id, { expect: digest }) : await api.deleteSession(id, { expect: digest });
      if (live()) host.close();
      done(which, result, plan);
    } catch (error) {
      if (error.code === "plan_changed") {
        await refreshPlan();
        return;
      }
      refused(error);
    }
  }

  async function refreshPlan() {
    show(loadingTemplate({ back }));
    try {
      const read = await api.deletePlan(id);
      if (!live()) return;
      plan = read;
      model = read?.chained ? deleteChoices(session, plan) : unchainedChoices(session, plan);
      notice = "What this deletes changed; check again";
      busy = false;
      showChoices();
    } catch (error) {
      busy = false;
      if (live()) { host.close(); failed(error); }
    }
  }

  // "Stop its worker, then delete": the delete again only once each worker
  // reads stopped (the stop route's released, after its bounded wait);
  // still running, the refusal says so, and nothing loops.
  async function stopThenDelete() {
    if (busy || !live()) return;
    const ids = refusal?.ids || [];
    busy = true;
    for (const child of ids) {
      let released = false;
      try {
        released = (await api.stopSession(child))?.released === true;
      } catch (_) { released = false; }
      if (!released) {
        refusal = { reason: "still_stopping", message: `${short(child)}'s worker is still running; try again in a moment.`, ids };
        busy = false;
        showRefusal();
        return;
      }
    }
    busy = false;
    run("this");
  }

  return {
    act(name) {
      if (!live()) return;
      if (name === "cancel") host.close();
      else if (name === "this" || name === "chain") run(name);
      else if (name === "stop") stopThenDelete();
    },
  };
}

// A card's ✕: the flow on a popover of its own at the card (a bottom sheet
// on a phone). One shell for every card: +openFor+ is the session it shows,
// and only the newest host is live (a ✕ on another card while one's plan is
// read takes the shell; the first flow's late answer draws nothing).
// @return {host(anchorEl, id): a host for runDeleteFlow, close, isOpen, pop}
export function createDeleteSheet({ doc = globalThis.document, win = globalThis.window, el = doc.createElement("span") } = {}) {
  let view = null;
  let handler = null;
  let current = null;
  let openFor = null;
  const shell = createChipPopover({
    id: "deleteSheet", className: "ctx-popover delete-pop", width: 420, el, anchor: "[data-del]", openers: "[data-del]",
    summary: () => view, sheet: true, label: "Delete the session?", doc, win,
    show: (tpl) => render(tpl, shell.pop),
    onOpen: () => shell.pop.querySelector(".ds-choice:not([disabled]), .ds-cancel")?.focus(),
    onClose: () => { view = null; handler = null; current = null; openFor = null; },
    onAct: (act) => {
      const [what, name] = act.split(":");
      if (what === "del") handler?.act(name);
    },
  });

  function host(anchorEl, id) {
    if (shell.isOpen() && openFor !== id) shell.close();
    const me = {
      back: false,
      live: () => current === me,
      show(tpl) {
        if (current !== me) return;
        view = tpl;
        if (shell.isOpen()) render(tpl, shell.pop);
        else shell.open(anchorEl);
      },
      close() { if (current === me) shell.close(); },
      wire(next) { if (current === me) handler = next; },
    };
    current = me;
    openFor = id;
    return me;
  }

  return { host, close: () => shell.close(), isOpen: shell.isOpen, pop: shell.pop, openFor: () => openFor };
}
