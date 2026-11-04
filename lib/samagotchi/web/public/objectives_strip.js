// The session's objectives above the conversation: the fold's current state
// (Objectives.view), from the session read (seed) and live from the stream's
// objectives_updated (update). No list: the element stays hidden, nothing on
// the page. A tap opens the edit list (chip_popover.js: a bottom sheet on a
// phone): add, done, drop, undo and a new text, each a /objectives line on the
// command route, the one way to an edit, so its refusals are the command's. No
// message and no turn; the worker's next event redraws (every tab's), and a
// mid-turn edit shows as waiting until the turn's end. A module of its own:
// static JS is cached at unversioned URLs.
import { createChipPopover, SHEET_TALL } from "./chip_popover.js";
import { addLine, DONE, editableText, headline, markLine, notYetText, pendingText, progress, rewordLine, stripItems } from "./objectives_model.js";
import { html, nothing, render } from "./vendor/lit-html.js";

// @param el the strip's element (index.html #objectivesStrip)
// @param session () the open session's id
// @param running () a turn runs
// @param sendLine (line) posts it as the session's command: a promise
// @param sendMessage (text) sends it as the user's message: a promise (Not yet)
// @param failed (error) a refused post, to tell the user
export function createObjectivesStrip({ el, session = () => null, running = () => false, sendLine = async () => {},
                                        sendMessage = async () => {}, failed = () => {}, doc = document, win = window }) {
  let list = null;
  // The item whose text is being edited; while a post is out.
  let editing = null;
  let busy = false;

  // +first+: the one chip a phone's one-line strip keeps (objectives.css).
  function chip(item, first) {
    return html`<button type="button" class=${`obj-chip obj-open ${item.status}${first ? " first" : ""}`} data-id=${item.id} title=${item.text} aria-expanded="false"><span class="obj-id">${item.id}</span><span class="obj-text">${item.status === DONE ? "✓ " : ""}${item.text}</span></button>`;
  }

  function draw() {
    el.hidden = !list;
    if (!list) {
      render(nothing, el);
      return;
    }
    const { done, total } = progress(list);
    const waiting = pendingText(list, running());
    render(html`<div class="obj-strip" role="group" aria-label="Objectives">
      <div class="obj-chips">${stripItems(list).map((item) => chip(item, item === headline(list)))}</div>
      ${waiting ? html`<span class="obj-waiting" role="status">${waiting}</span>` : nothing}
      <span class="obj-count">${done}/${total}</span>
      <button type="button" class="obj-edit obj-open" aria-expanded="false">Edit</button>
    </div>`, el);
  }

  function post(line) {
    if (!line || busy) return;
    busy = true;
    drawPanel();
    Promise.resolve(sendLine(line)).catch(failed).finally(() => {
      busy = false;
      drawPanel();
    });
  }

  function subline(item) {
    const parts = [];
    if (item.done_when) parts.push(html`<span>done when: ${item.done_when}</span>`);
    if (item.move) parts.push(html`<span>last move: ${item.move.note}${item.move.evidence ? ` (${item.move.evidence})` : ""}</span>`);
    return parts.length ? html`<div class="obj-row-sub">${parts}</div>` : nothing;
  }

  function actions(item) {
    const act = (name, label, title) => html`<button type="button" class="obj-act ghost" data-obj-act=${name} data-id=${item.id} title=${title} ?disabled=${busy}>${label}</button>`;
    if (item.status === "active") {
      const notYet = item.move ? [act("notyet", "Not yet", `Tell the agent: not yet on ${item.id}`)] : [];
      return [...notYet, act("done", "Done", `Mark ${item.id} done`), act("drop", "Drop", `Drop ${item.id}`)];
    }
    return [act("undo", "Undo", `Back to active: ${item.id}`)];
  }

  function row(item) {
    const klass = `obj-row ${item.status}`;
    if (editing === item.id) {
      return html`<form class=${klass} data-id=${item.id}>
        <span class="obj-id">${item.id}</span>
        <input class="obj-input" name="text" .value=${editableText(item)} aria-label=${`New text of ${item.id}`} autocomplete="off">
        <button type="submit" class="obj-act" ?disabled=${busy}>Save</button>
        <button type="button" class="obj-act ghost" data-obj-act="cancel">Cancel</button>
      </form>`;
    }
    return html`<div class=${klass} data-row=${item.id}>
      <span class="obj-id">${item.id}</span>
      <div class="obj-row-main">
        <button type="button" class="obj-row-text" data-obj-act="reword" data-id=${item.id} title=${`Edit the text of ${item.id}`}>${item.status === DONE ? "✓ " : ""}${item.text}</button>
        ${subline(item)}
      </div>
      <div class="obj-row-acts">${actions(item)}</div>
    </div>`;
  }

  const panelTemplate = () => {
    const waiting = pendingText(list, running());
    return html`<div class="ctx-pop-head"><span class="ctx-pop-kind">Objectives</span><button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>
      <div class="obj-rows">${list.items.map(row)}</div>
      <form class="obj-add" data-add="1">
        <input class="obj-input" name="text" placeholder="Add an objective" aria-label="Add an objective" autocomplete="off">
        <button type="submit" class="obj-act" ?disabled=${busy}>Add</button>
      </form>
      <div class="obj-note" role="status">${waiting || "No message, no turn: the agent reads the change before its next turn."}</div>`;
  };

  const shell = createChipPopover({
    id: "objectivesPanel", className: "ctx-popover obj-panel", width: 560, el, anchor: ".obj-open", summary: () => list,
    session, label: "Objectives", sheet: true, sheetShare: SHEET_TALL, doc, win,
    show: () => render(panelTemplate(), shell.pop),
    onOpen: () => {
      const id = shell.opener?.()?.dataset?.id;
      const target = id && shell.pop.querySelector(`[data-row="${id}"] .obj-row-text`);
      (target || shell.pop.querySelector(".obj-add .obj-input"))?.focus();
    },
    onClose: () => { editing = null; },
    onSubmit: (form) => {
      const text = form.elements.text.value;
      if (form.dataset.add) {
        post(addLine(text));
        form.reset();
        return;
      }
      const line = rewordLine(form.dataset.id, text);
      editing = null;
      post(line);
    },
  });

  function drawPanel() {
    if (shell.isOpen() && list) render(panelTemplate(), shell.pop);
  }

  shell.pop.addEventListener("click", (e) => {
    const button = e.target.closest("[data-obj-act]");
    if (!button) return;
    const { objAct: act, id } = button.dataset;
    if (act === "reword") {
      editing = id;
      drawPanel();
      const input = shell.pop.querySelector(`form[data-id="${id}"] .obj-input`);
      input?.focus();
      input?.select();
    } else if (act === "cancel") {
      editing = null;
      drawPanel();
    } else if (act === "notyet") {
      notYet(id);
    } else {
      post(markLine(act, id));
    }
  });
  // Esc in the text being edited takes that edit back, not the panel.
  shell.pop.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && editing && e.target.closest("form[data-id]")) {
      e.stopPropagation();
      editing = null;
      drawPanel();
    }
  });

  // One tap: a normal message the agent reads at its next step, or as the next
  // turn. Any tab's echo is the stream's.
  function notYet(id) {
    const item = list?.items.find((i) => i.id === id);
    if (item) Promise.resolve(sendMessage(notYetText(item))).catch(failed);
  }

  const take = (view) => {
    list = view && Array.isArray(view.items) ? view : null;
    draw();
    shell.refresh();
  };

  return {
    // A session read's list; none clears it.
    seed: take,
    // The stream's objectives_updated.
    update: take,
    // No session open.
    reset: () => {
      if (shell.isOpen()) shell.close();
      take(null);
    },
    notYet,
    // A turn started or ended: the waiting line's words.
    redraw: () => {
      draw();
      drawPanel();
    },
  };
}
