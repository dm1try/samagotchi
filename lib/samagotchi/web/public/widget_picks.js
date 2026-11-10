// A chi-ui picks (docs/internals/inline-widgets.md): rows of things to decide,
// each with its options as chips, the recommended one marked and picked to
// start with, a "+ note" per row, and one "Fill reply" that puts the picks in
// the composer as plain text ("1: fix now (today) · D4: B"). It never sends:
// the composer text is the widget's only way out, and the owner reads it
// before sending. Ported from eval 0013's viewer.
//
// The data is P1a's normalised JSON (InlineWidgets). Its strings are the
// model's: they go in as textContent or attributes only, never markup. The
// picks live here, in the widget: a rewrite of the bubble starts over.
//
// A module of its own: static JS is cached at unversioned URLs.

// What a row starts with: its recommended option picked, no note.
export function initialPicks(rows) {
  return (rows || []).map((r) => ({ pick: r.recommended != null ? String(r.recommended) : null, note: "" }));
}

// What a row's id may not start with in the reply: a shell line's ! and a
// session command's / (and the spaces between them). The server's normaliser
// drops them already (InlineWidgets#row_id); this holds to it here too, as
// the reply leads the composer (audit r19, R4).
const COMMAND_LEAD = /^[!/\s]+/;

// A row's id as the page shows it and as the reply leads with: the raw id
// without its leading ! / and the spaces between them, or the row's number
// when nothing is left. One rule, so the chip's label and the filled reply
// never disagree.
function rowId(row, k) {
  return String(row.id ?? "").replace(COMMAND_LEAD, "") || String(k + 1);
}

// The reply the picks make: "id: option (note)" per picked row, " · " between
// them; a row with no pick is left out. It never starts with ! or /: an id's
// leading ones are dropped, and an id of only those is its row's number.
export function replyText(rows, picks) {
  return (rows || [])
    .map((r, k) => {
      const { pick, note } = picks[k] || {};
      if (!pick) return null;
      const said = String(note ?? "").replace(/\s+/g, " ").trim();
      return `${rowId(r, k)}: ${pick}${said ? ` (${said})` : ""}`;
    })
    .filter(Boolean)
    .join(" · ");
}

// The composer's text with +reply+: after a draft on a line of its own, the
// draft kept as typed.
export function withDraft(draft, reply) {
  const typed = String(draft ?? "").trimEnd();
  return typed ? `${typed}\n${reply}` : reply;
}

function el(doc, tag, className, text) {
  const node = doc.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = String(text);
  return node;
}

function button(doc, className, text) {
  const node = el(doc, "button", className, text);
  node.type = "button";
  return node;
}

// The picks as an element, for a widget host's shadow root.
// @param fill (reply) => puts +reply+ in the composer (never sends)
export function drawPicks(picks, { fill, doc = document }) {
  const rows = picks.rows || [];
  const state = initialPicks(rows);

  const box = el(doc, "div", "w picks");
  box.setAttribute("role", "group");
  box.setAttribute("aria-label", `Picks: ${picks.title || "choices"}`);
  const head = el(doc, "div", "w-head");
  const count = el(doc, "span", "w-count");
  head.append(el(doc, "span", "w-kind", "Picks"), el(doc, "span", "w-title", picks.title || ""), count);
  const body = el(doc, "div", "w-body");
  box.append(head, body);

  const list = el(doc, "div", "wp-list");
  const chips = rows.map((r, k) => {
    const id = rowId(r, k);
    const row = el(doc, "div", "wp-row");
    const text = el(doc, "div", "wp-text");
    text.append(el(doc, "div", null, r.text || ""));
    if (r.why) text.append(el(doc, "div", "wp-why", r.why));
    const add = button(doc, "wp-addnote", "+ note");
    add.addEventListener("click", () => {
      const input = el(doc, "input", "wp-note");
      input.type = "text";
      input.placeholder = "a word for this row";
      input.setAttribute("aria-label", `Note for ${id}`);
      input.addEventListener("input", () => { state[k].note = input.value; });
      add.replaceWith(input);
      input.focus();
    });
    text.append(add);
    const opts = el(doc, "div", "wp-opts");
    opts.setAttribute("role", "group");
    opts.setAttribute("aria-label", `Options for ${id}`);
    const own = (r.options || []).map((option) => {
      const o = String(option);
      const b = button(doc, "wp-opt", o);
      if (r.recommended != null && String(r.recommended) === o) {
        b.append(el(doc, "span", "rec", "rec"));
        b.title = "recommended";
      }
      b.addEventListener("click", () => {
        state[k].pick = state[k].pick === o ? null : o;
        paint();
      });
      opts.append(b);
      return [o, b];
    });
    row.append(el(doc, "span", "wp-id", id), text, opts);
    list.append(row);
    return own;
  });

  const foot = el(doc, "div", "wp-foot");
  const fillBtn = button(doc, "wp-fill", "Fill reply");
  fillBtn.title = "Put the picks in the composer; you send it";
  foot.append(fillBtn, el(doc, "span", "hint", "fills the composer, never sends"));
  body.append(list, foot);

  fillBtn.addEventListener("click", () => {
    const reply = replyText(rows, state);
    if (reply) fill(reply);
  });

  function paint() {
    chips.forEach((own, k) => {
      for (const [o, b] of own) b.setAttribute("aria-pressed", String(state[k].pick === o));
    });
    const picked = state.filter((s) => s.pick).length;
    count.textContent = `${picked} of ${rows.length} picked`;
    fillBtn.disabled = picked === 0;
  }

  paint();
  return box;
}
