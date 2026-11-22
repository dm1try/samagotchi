// The delete sheet (docs/sessions.md, Deleting a session; Session chains →
// Deleting a link): Delete on any session says, before anything happens,
// what goes, what is stopped first and what stays, with one button that
// names the outcome (removal_sheet_model.js has the words). A chained
// session keeps its two choices: "Delete this link" (first, the default)
// undoes the newest link's continue or splits the chain at a middle one;
// "Delete the whole chain" takes every link; each carries its own rows and
// button words. Archive asks in the same sheet when its 409 says background
// tasks still run, or why it can't happen now.
//
// The sheet's words come from GET /api/sessions/:id/delete_plan, the plan
// and refusals the server's delete itself runs (SessionChain::Delete::
// Preview), fetched as the sheet opens. The tap sends the shown choice's
// digest (expect) and, when the choice lists any task, stop_tasks with the
// running ones' ids: the server stops only those. A changed plan (409
// plan_changed) or a task that started since (409 tasks_running) is re-read
// and shown for a fresh tap.
//
// Where it is drawn (a host): the ⋯ More panel turns into it, with ‹ More to
// go back (more_sheet.js' subview); a card's ✕ (or archive) opens it at the
// card, on chip_popover.js' shell (createDeleteSheet): a bottom sheet on a
// phone, a popover on a wider window. Templates plus createDeleteSheet and
// runDeleteFlow, so the specs run them under node --test.

import { html, nothing, render } from "./vendor/lit-html.js";
import { createChipPopover, SHEET_TALL } from "./chip_popover.js";
import { archiveSheetModel, buttonWords, cantModel, choiceTail, sessionSheetModel, sheetTitle,
         stopTasksOptions, stopsFirst } from "./removal_sheet_model.js";

const short = (id) => String(id ?? "").slice(0, 8);
const count = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

// A session is in a chain when it continues a link, or a listed one
// continues it (the page's list holds archived links too). Unused since every
// delete reads its plan; kept while an older cached session_actions.js may
// import it (web-frontend.md, removing an export).
export function isChained(session, list = []) {
  if (!session) return false;
  if (session.continues) return true;
  return list.some((s) => s.continues === session.id);
}

// The link's own first lines (what comes back, how the chain splits, what
// goes), then what is stopped first and what stays (choiceTail).
function thisLinkLines(link, id) {
  const goes = { cls: "dim", text: `Goes: its turns${link.deletes ? ` and its ${count(link.deletes, "stopped delegate")}` : ""}.` };
  let main;
  if (link.previous_id) {
    const took = [link.moved && count(link.moved, "delegate"), link.notes && count(link.notes, "unread note")].filter(Boolean);
    main = `Undoes the continue: ${short(link.previous_id)} comes back to the lists (not started)` +
      (took.length ? `, with its ${took.join(" and ")}.` : ".");
  } else if (link.next_id) {
    const earlier = link.earlier ? `${count(link.earlier, "earlier link")} ${link.earlier === 1 ? "stays" : "stay"} archived, and ` : "";
    main = `The chain splits: ${earlier}${short(link.next_id)} goes on as a chain of its own. Nothing is undone.`;
  } else {
    main = "The earlier links stay as they are. Nothing is undone.";
  }
  return [{ cls: "", text: main }, goes, ...choiceTail(link, id)];
}

function chainLines(plan, id) {
  const { chain } = plan;
  const delegates = chain.deletes ? ` and their ${count(chain.deletes, "stopped delegate")}` : "";
  const text = plan.cut_off ? `Goes: these ${count(chain.links, "link")}${delegates}.` : `Goes: all ${count(chain.links, "link")}${delegates}.`;
  return [{ cls: "dim", text }, ...choiceTail(chain, id)];
}

// The stopped delegates a choice deletes with it (its ids; an older plan's
// count): its button counts them (case 2's rule, every session the tap takes).
function stoppedDelegates(choice) {
  const ids = choice?.delegates?.delete;
  return Array.isArray(ids) ? ids.length : choice?.deletes || 0;
}

// Why a choice can't be taken now, in the sheet's words; a schedule says it
// once, above both.
function refusedWhy(refusal) {
  if (!refusal) return null;
  if (refusal.reason === "scheduled" || refusal.reason === "chain_scheduled") return "Not while a schedule runs the chain.";
  return refusal.message || "Not now.";
}

// The sheet's model for +session+ from its delete plan (the route's JSON);
// +sessions+ the page's list (it names the delegates).
// A session in no chain: removal_sheet_model.js sessionSheetModel ({title,
// groups, button, stops, foot, tasks}, or the Can't delete view {title, sub,
// close}). A chained one: {title, sub, banner, choices: [{act, label, lines,
// warn, disabled, why, primary, stops, tasks}], foot}.
export function deleteChoices(session, plan, sessions = []) {
  const id = session?.id ?? plan.session_id;
  if (!plan.chained) return sessionSheetModel(session ?? { id }, plan, sessions);
  const link = plan.link || {};
  const chain = plan.chain || {};
  // The chain's words first: they say the schedule runs this chain.
  const scheduled = [chain.refusal, link.refusal].find((r) => r && /scheduled$/.test(r.reason));
  return {
    title: sheetTitle("Delete", id, session),
    sub: `It is link ${plan.position} of ${plan.size} of its chain. This can't be undone.`,
    banner: scheduled ? `${scheduled.message.charAt(0).toUpperCase()}${scheduled.message.slice(1)}.` : null,
    choices: [
      { act: "this", label: buttonWords(link, { object: "this link", sessions: 1 + stoppedDelegates(link) }), lines: thisLinkLines(link, id), primary: true,
        disabled: !!link.refusal && link.refusal.reason !== "delegate_unmovable", why: refusedWhy(link.refusal),
        stops: stopsFirst(link), tasks: link.tasks || null },
      { act: "chain", label: buttonWords(chain, { object: "the whole chain", sessions: (chain.links || 0) + stoppedDelegates(chain) }), lines: chainLines(plan, id),
        warn: plan.cut_off ? "Earlier links, cut off by a deleted link, are kept (archived)." : null,
        disabled: !!chain.refusal, why: refusedWhy(chain.refusal), stops: stopsFirst(chain), tasks: chain.tasks || null },
    ],
    foot: "Running workers are stopped first.",
  };
}

function lineTemplate(line, i) {
  if (typeof line === "string") return html`<span class=${i ? "ds-line dim" : "ds-line"}>${line}</span>`;
  return html`<span class=${line.cls ? `ds-line ${line.cls}` : "ds-line"}>${line.text}</span>`;
}

function choiceTemplate(choice) {
  const cls = `ds-choice${choice.primary ? " primary" : ""}`;
  if (choice.disabled) {
    return html`<button type="button" class=${cls} data-act=${`del:${choice.act}`} disabled
      ><span class="ds-label">${choice.label}</span><span class="ds-line">${choice.why}</span></button>`;
  }
  return html`<button type="button" class=${cls} data-act=${`del:${choice.act}`}
    ><span class="ds-label">${choice.label}</span>${choice.lines.map(lineTemplate)
    }${choice.warn ? html`<span class="ds-line warn">${choice.warn}</span>` : nothing}</button>`;
}

// The back row: ‹ More in the More panel, a close × on a card's.
function headTemplate(back) {
  // The More panel's grip stays on top, as on its list (more-grip).
  return back
    ? html`<div class="more-grip" aria-hidden="true"></div><div class="ds-head"><button type="button" class="ds-back" data-act="del:back">‹ More</button></div>`
    : html`<div class="ds-head"><span></span><button type="button" class="ctx-pop-close" data-act="del:cancel" aria-label="Close">×</button></div>`;
}

// A row's line: its parts (a string, {b} bold, {dim}).
function partsTemplate(parts) {
  return parts.map((part) => {
    if (typeof part === "string") return part;
    if (part.b) return html`<b>${part.b}</b>`;
    return html`<span class="dim">${part.dim}</span>`;
  });
}

function groupsTemplate(groups) {
  return html`<ul class="ds-groups">${groups.map((g) => html`<li class="ds-group" data-group=${g.key}
    ><span class=${`ds-k ${g.key}`}>${g.label}</span><span class="ds-v">${g.lines.map((line, i) => html`${i ? html`<br>` : nothing}${partsTemplate(line)}`)}</span></li>`)}</ul>`;
}

// One session's sheet (a session in no chain, archive's ask) or the Can't …
// view. +busy+: the tap under way (its button says Stopping… / Deleting…).
function singleTemplate(model, { back, busy, notice, act }) {
  const going = model.warn ? "Archiving…" : "Deleting…";
  return html`<div class=${`delete-sheet${busy ? " busy" : ""}`}>${headTemplate(back)}
    <div class="ds-title">${model.title}</div>
    ${model.sub ? html`<div class="ds-sub">${model.sub}</div>` : nothing}
    ${notice ? html`<div class="ds-banner">${notice}</div>` : nothing}
    ${model.groups ? groupsTemplate(model.groups) : nothing}
    <div class="ds-acts">${model.close ? nothing : html`<button type="button" class=${`ds-go ${model.warn ? "warn" : "danger"}`}
      data-act=${`del:${act}`} ?disabled=${busy}>${busy ? (model.stops ? "Stopping…" : going) : model.button}</button>`
      }<button type="button" class="ds-cancel" data-act="del:cancel" ?disabled=${busy}>${model.close ? "Close" : "Cancel"}</button></div>
    ${model.foot ? html`<div class="ds-foot"><span class="ds-note">${model.foot}</span></div>` : nothing}
  </div>`;
}

// The sheet (a lit-html template) for deleteChoices' model, or archive's.
// +busy+: a delete under way (every button off); +back+: drawn in the More
// panel; +notice+: a banner above (the plan changed); +act+: the one
// button's data-act name ("this"; "archive" for archive's).
export function deleteSheetTemplate(model, { back = false, busy = false, notice = null, act = "this", stopping = false } = {}) {
  if (!model.choices) return singleTemplate(model, { back, busy, notice, act });
  const allOff = model.choices.every((c) => c.disabled);
  return html`<div class=${`delete-sheet${busy ? " busy" : ""}`}>${headTemplate(back)}
    <div class="ds-title">${model.title}</div>
    <div class="ds-sub">${model.sub}</div>
    ${notice ? html`<div class="ds-banner">${notice}</div>` : nothing}
    ${model.banner ? html`<div class="ds-banner">${model.banner}</div>` : nothing}
    <div class="ds-choices" ?inert=${busy}>${model.choices.map(choiceTemplate)}</div>
    <div class="ds-acts"><button type="button" class="ds-cancel" data-act="del:cancel" ?disabled=${busy}>${allOff ? "Close" : "Cancel"}</button></div>
    ${allOff ? nothing : html`<div class="ds-foot"><span class="ds-note">${busy ? (stopping ? "Stopping…" : "Deleting…") : model.foot}</span></div>`}
  </div>`;
}

// While the plan is read.
export function loadingTemplate({ back = false } = {}) {
  return html`<div class="delete-sheet">${headTemplate(back)}<div class="ds-sub">Reading what this delete would do…</div></div>`;
}

// A refused delete, in the sheet: a moved delegate that can't go back
// (delegate_unmovable: "Stop its worker, then delete" only when the page
// can stop it, not a one-turn run's), or any other refusal's own words.
// @param refusal {reason, message, ids, stoppable, sessionId}
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

export function refusalTemplate(model, { back = false, busy = false } = {}) {
  return html`<div class="delete-sheet">${headTemplate(back)}
    <div class="ds-title">${model.title}</div>
    <div class="ds-sub">${model.text}</div>
    ${model.stop ? html`<div class="ds-choices"><button type="button" class="ds-choice primary" data-act="del:stop"
      ?disabled=${busy}><span class="ds-label">${busy ? "Stopping…" : model.stop.label}</span><span class="ds-line dim">${model.stop.line}</span></button></div>` : nothing}
    <div class="ds-acts"><button type="button" class="ds-cancel" data-act="del:cancel" ?disabled=${busy}>${model.stop ? "Cancel" : "Close"}</button></div>
  </div>`;
}

// The list after a delete: the deleted ids gone, the ones back in the lists
// not archived (session_actions.js' markArchived's flip).
export function listAfterDelete(list, result) {
  const gone = new Set(result.deleted || [result.session_id]);
  const back = new Set(result.unarchived || []);
  return list.filter((s) => !gone.has(s.id)).map((s) => (back.has(s.id) ? { ...s, archived: false } : s));
}

const CHANGED = { delete: "What this deletes changed; check again.", archive: "What this archives changed; check again." };

// The flow in a +host+ ({show(template), close(), back: whether it is the
// More panel}): reads the plan, shows the sheet, runs the choice tapped, and
// shows a refusal in place. +act+ is wired by the host to the returned
// handler. Hooks: api {deletePlan, deleteSession, deleteChain, stopSession;
// archive(id, opts) for +archive+}; done(which, result, plan) after a
// delete (which: "this", "chain", "archive"); +sessions+ the page's list
// (names). +archive+: archive's ask from its first 409 (+archive.refusal+):
// no plan is read, the button archives stopping the named tasks.
// failed(error): a plan that can't be read, said in the sheet too; or a tap
// refused after its sheet was closed, drawn nowhere.
// @return {act(name)} the host's handler for its data-act="del:*"
export function runDeleteFlow({ id, session, host, api, done, failed = () => {}, sessions = [], archive = null }) {
  let plan = null;
  let model = null;
  let notice = null;
  let refusal = null;
  let busy = false;
  let stopping = false;
  const back = !!host.back;
  const op = archive ? "archive" : "delete";
  // Whether +host+ still shows this flow: another session's sheet opened in
  // the same shell since (a second card's ✕, the More panel on another
  // session) takes it, and this flow then draws and acts on nothing.
  const live = () => (host.live ? host.live() : true);
  const show = (tpl) => { if (live()) host.show(tpl); };

  const list = () => (typeof sessions === "function" ? sessions() : sessions);
  const showSheet = () => show(deleteSheetTemplate(model, { back, busy, notice, stopping, act: archive ? "archive" : "this" }));
  const showRefusal = (busyRefusal = false) =>
    show(refusalTemplate(refusalModel(refusal, plan?.link?.previous_id), { back, busy: busyRefusal }));
  // A plan that can't be read: why, in the sheet, and only Close.
  const cant = (error) => {
    busy = false;
    model = cantModel(op, id, error);
    notice = null;
    showSheet();
    failed(error);
  };

  if (archive) {
    model = archiveSheetModel(session ?? { id }, archive.refusal, list());
    showSheet();
  } else {
    show(loadingTemplate({ back }));
    api.deletePlan(id).then((read) => {
      if (!live()) return;
      plan = read;
      model = deleteChoices(session, plan, list());
      showSheet();
    }, (error) => { if (live()) cant(error); });
  }

  // The refusal as the delete's 409 says it; whether the page can stop a
  // moved delegate's worker is its +stoppable+, as the delete saw it.
  function refused(error) {
    refusal = { reason: error.code, message: error.message, ids: error.body?.ids || [], stoppable: error.body?.stoppable === true,
                sessionId: id };
    busy = false;
    showRefusal();
  }

  // The choice tapped (+which+), what it shows: its digest and its tasks.
  function chosen(which) {
    if (!model) return null;
    if (!model.choices) return model.close ? null : { tasks: model.tasks, stops: model.stops, digest: plan?.link?.digest };
    const choice = model.choices.find((c) => c.act === which);
    if (!choice || choice.disabled) return null;
    return { tasks: choice.tasks, stops: choice.stops, digest: which === "chain" ? plan?.chain?.digest : plan?.link?.digest };
  }

  async function sendDelete(which) {
    const choice = chosen(which);
    if (!choice) return;
    busy = true;
    stopping = !!choice.stops;
    showSheet();
    const tasks = stopTasksOptions(choice.tasks);
    try {
      let result;
      if (archive) result = await api.archive(id, tasks);
      else {
        const opts = { expect: choice.digest, ...tasks };
        result = which === "chain" ? await api.deleteChain(id, opts) : await api.deleteSession(id, opts);
      }
      if (live()) host.close();
      done(which, result, plan);
    } catch (error) {
      // The sheet was closed while the tap ran (×, ‹ More, Esc): nothing
      // happened, and the caller says why (session_actions.js: a sticky toast).
      if (!live()) {
        busy = false;
        failed(error);
        return;
      }
      if (error.code === "plan_changed" || error.code === "tasks_running") {
        await refreshPlan(error);
        return;
      }
      if (archive) {
        busy = false;
        model = archiveSheetModel(session ?? { id }, error, list());
        notice = null;
        showSheet();
        return;
      }
      refused(error);
    }
  }

  async function run(which) {
    if (busy || !live()) return;
    await sendDelete(which);
  }

  // The sheet as it is now, with "changed; check again" on top: the plan
  // read again (a delete), or the 409's own tasks (an archive's).
  async function refreshPlan(error) {
    if (archive) {
      busy = false;
      model = archiveSheetModel(session ?? { id }, error, list());
      notice = CHANGED.archive;
      showSheet();
      return;
    }
    show(loadingTemplate({ back }));
    try {
      const read = await api.deletePlan(id);
      if (!live()) return;
      plan = read;
      model = deleteChoices(session, plan, list());
      notice = CHANGED.delete;
      busy = false;
      showSheet();
    } catch (readError) {
      if (live()) cant(readError);
    }
  }

  // "Stop its worker, then delete": the delete again only once each worker
  // reads stopped (the stop route's released, after its bounded wait);
  // still running, the refusal says so, and nothing loops.
  async function stopThenDelete() {
    if (busy || !live()) return;
    const ids = refusal?.ids || [];
    busy = true;
    showRefusal(true);
    for (const child of ids) {
      let released = false;
      try {
        released = (await api.stopSession(child))?.released === true;
      } catch (_) { released = false; }
      if (!released) {
        busy = false;
        const message = `${short(child)}'s worker is still running; try again in a moment.`;
        if (!live()) {
          failed(Object.assign(new Error(message), { code: "still_stopping", body: { ids } }));
          return;
        }
        refusal = { reason: "still_stopping", message, ids };
        showRefusal();
        return;
      }
    }
    await sendDelete("this");
  }

  return {
    act(name) {
      if (!live()) return;
      if (name === "cancel") host.close();
      else if (name === "this" || name === "chain" || name === "archive") run(name);
      else if (name === "stop") stopThenDelete();
    },
  };
}

// A card's ✕ (or its archive): the flow on a popover of its own at the
// card (a bottom sheet on a phone); ⋯ when the open session's. One shell for every card: +openFor+ is the session it shows,
// and only the newest host is live (a ✕ on another card while one's plan is
// read takes the shell; the first flow's late answer draws nothing).
// @return {host(anchorEl, id): a host for runDeleteFlow, close, isOpen, pop}
export function createDeleteSheet({ doc = globalThis.document, win = globalThis.window, el = doc.createElement("span") } = {}) {
  let view = null;
  let handler = null;
  let current = null;
  let openFor = null;
  // Focus on the way out, so a stray Enter never deletes or archives: the ×
  // while the plan is read, then Cancel once it shows (once per open).
  let toCancel = false;
  const settleFocus = () => {
    if (!toCancel) return;
    const cancel = shell.pop.querySelector(".ds-cancel:not([disabled])");
    if (cancel) toCancel = false;
    (cancel || shell.pop.querySelector(".ctx-pop-close"))?.focus();
  };
  const shell = createChipPopover({
    id: "deleteSheet", className: "ctx-popover delete-pop", width: 420, el, anchor: "[data-del]", openers: "[data-del], #infoDeleteBtn",
    summary: () => view, sheet: true, sheetShare: SHEET_TALL, label: "Delete or archive the session", doc, win,
    show: (tpl) => render(tpl, shell.pop),
    onOpen: () => { toCancel = true; settleFocus(); },
    onClose: () => { view = null; handler = null; current = null; openFor = null; toCancel = false; },
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
        if (shell.isOpen()) {
          render(tpl, shell.pop);
          settleFocus();
        } else shell.open(anchorEl);
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
