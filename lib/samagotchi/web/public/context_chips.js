// The session bar's attached context (chi context): a chip per source the
// open session sees (name · age; a dot for a change the agent hasn't read,
// red for a failing refresh), and a popover with its summary, hint link,
// text and detach. The chips refresh when a context note arrives in the
// stream and when the page gets focus (no event of their own), and their
// ages tick every minute. A "+ URL" chip (when an installed bundle's
// provider can attach one: GET …/context's can_add_url) opens a form that
// attaches a URL (a GitHub PR); the web never adds a command.

// "now", "3m", "2h", "4d" since an ISO time; "" for none.
export function ageText(iso, now = Date.now()) {
  const at = Date.parse(iso || "");
  if (Number.isNaN(at)) return "";
  const s = Math.max(0, Math.round((now - at) / 1000));
  if (s < 60) return "now";
  if (s < 3600) return `${Math.floor(s / 60)}m`;
  if (s < 86400) return `${Math.floor(s / 3600)}h`;
  return `${Math.floor(s / 86400)}d`;
}

// A hint the popover may link to: http(s) only.
export function hintUrl(hint) {
  const text = String(hint || "").trim();
  return /^https?:\/\/\S+$/i.test(text) ? text : null;
}

// GET …/context's rows as chips: the muted ones left out. state: "error"
// (the last refresh failed), "unread" (a text the agent hasn't read),
// "empty" (no text yet) or "ok".
export function chipModel(rows, now = Date.now()) {
  return (rows || []).filter((row) => row && !row.muted).map((row) => {
    const state = row.error ? "error" : !row.has_text ? "empty" : row.unread ? "unread" : "ok";
    const age = ageText(row.fetched_at, now);
    const why = { error: `last refresh failed: ${row.error}`, unread: "changed; the agent hasn't read it yet",
                  empty: "no text yet", ok: "the agent has read the latest" }[state];
    const title = [row.summary, why].filter(Boolean).join(" · ");
    return { name: row.name, label: age ? `${row.name} · ${age}` : row.name, state, title };
  });
}

// addUrl: end with the "+ URL" chip.
export function chipsHtml(chips, escapeHtml, { addUrl = false } = {}) {
  return chips.map((chip) => `<button type="button" class="ctx-chip ${chip.state}" data-name="${escapeHtml(chip.name)}" ` +
    `title="${escapeHtml(chip.title)}" aria-haspopup="dialog">` +
    `${chip.state === "unread" ? '<span class="ctx-dot" aria-hidden="true"></span>' : ""}${escapeHtml(chip.label)}</button>`).join("") +
    (addUrl ? '<button type="button" class="ctx-chip ctx-add" data-act="add" title="Attach a URL (a GitHub PR) the agent can read and hears about when it changes" aria-haspopup="dialog">+ URL</button>' : "");
}

// The "+ URL" popover: the URL, an optional why, Attach; +url+ and +error+
// after a try that failed.
export function addFormHtml(escapeHtml, { url = "", error = null } = {}) {
  return `<form class="ctx-add-form"><div class="ctx-pop-head"><strong>Attach a URL</strong>` +
    `<button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>` +
    `<div class="ctx-pop-meta">A link an installed bundle knows (github-pr: a pull request). The agent gets a note when it changes.</div>` +
    `<input class="ctx-add-input" name="url" type="url" inputmode="url" placeholder="https://github.com/owner/repo/pull/123" value="${escapeHtml(url)}" required autocomplete="off">` +
    `<input class="ctx-add-input" name="why" type="text" placeholder="why (optional)" maxlength="300" autocomplete="off">` +
    (error ? `<div class="ctx-pop-error" role="alert">${escapeHtml(error)}</div>` : "") +
    `<div class="ctx-pop-actions"><button type="submit" class="ctx-add-submit">Attach</button></div></form>`;
}

// The popover's inside for one row (GET …/context's).
export function popoverHtml(row, escapeHtml, now = Date.now()) {
  const kind = row.kind === "cmd" ? `runs every ${row.every_seconds ? `${row.every_seconds}s` : "few minutes"}` : "pushed";
  const url = hintUrl(row.hint);
  const hint = url
    ? `<a class="ctx-pop-hint" href="${escapeHtml(url)}" target="_blank" rel="noopener noreferrer">${escapeHtml(url)}</a>`
    : (row.hint ? `<div class="ctx-pop-hint">${escapeHtml(row.hint)}</div>` : "");
  const age = ageText(row.fetched_at, now);
  const meta = [age ? (age === "now" ? "fetched just now" : `fetched ${age} ago`) : "no text yet",
                row.unread ? "the agent hasn't read this change" : (row.has_text ? "the agent has read it" : "")]
    .filter(Boolean).join(" · ");
  const detach = row.scope === "project" ? "mute here" : "detach";
  const detachTitle = row.scope === "project"
    ? "The project's source: this session stops seeing it (chi context unmute brings it back)"
    : "Remove it from this session";
  return `<div class="ctx-pop-head"><strong>${escapeHtml(row.name)}</strong>` +
    `<span class="ctx-pop-kind">${escapeHtml(row.scope)} · ${escapeHtml(kind)}</span>` +
    `<button type="button" class="ctx-pop-close" data-act="close" aria-label="Close">×</button></div>` +
    (row.why ? `<div class="ctx-pop-why">${escapeHtml(row.why)}</div>` : "") +
    hint +
    (row.summary ? `<div class="ctx-pop-summary">${escapeHtml(row.summary)}</div>` : "") +
    `<div class="ctx-pop-meta">${escapeHtml(meta)}</div>` +
    (row.error ? `<div class="ctx-pop-error">last refresh failed: ${escapeHtml(row.error)}</div>` : "") +
    `<pre class="ctx-pop-text" hidden></pre>` +
    `<div class="ctx-pop-actions">` +
    (row.has_text ? `<button type="button" data-act="view">view text</button>` : "") +
    `<button type="button" class="ctx-pop-detach" data-act="detach" title="${escapeHtml(detachTitle)}">${detach}</button></div>`;
}

// The chips for the session bar. el: #contextChips; api: {list(id),
// show(id, name), detach(id, name), add(id, {url, why})}; escapeHtml;
// toast(text).
export function createContextChips({ el, api, escapeHtml, toast = () => {}, doc = document, win = window }) {
  let sessionId = null;
  let rows = [];
  let canAdd = false;
  let openName = null;
  let loadSeq = 0;
  const pop = doc.createElement("div");
  pop.id = "contextPopover";
  pop.className = "ctx-popover";
  pop.setAttribute("role", "dialog");
  pop.hidden = true;
  doc.body.appendChild(pop);

  // openName ADD: the "+ URL" form is open.
  const ADD = "\u0000add";

  function render() {
    const chips = chipModel(rows);
    el.innerHTML = chipsHtml(chips, escapeHtml, { addUrl: canAdd });
    el.hidden = chips.length === 0 && !canAdd;
    // The "+ URL" chip alone sits inline, not on a row of its own.
    el.classList.toggle("only-add", chips.length === 0 && canAdd);
    if (openName === ADD) {
      if (canAdd) el.querySelector(".ctx-add")?.classList.add("open");
      else close();
    } else if (openName && !chips.some((chip) => chip.name === openName)) close();
    else if (openName) el.querySelector(`.ctx-chip[data-name="${openName}"]`)?.classList.add("open");
  }

  async function refresh() {
    const id = sessionId;
    if (!id) return;
    const seq = ++loadSeq;
    try {
      const data = await api.list(id);
      if (seq !== loadSeq || id !== sessionId) return;
      rows = data.sources || [];
      canAdd = data.can_add_url === true;
    } catch {
      // A session the server doesn't know (gone, or an older chi web): no chips.
      if (seq !== loadSeq || id !== sessionId) return;
      rows = [];
      canAdd = false;
    }
    render();
    if (openName && openName !== ADD) {
      const row = rows.find((r) => r.name === openName);
      if (row && pop.querySelector(".ctx-pop-text")?.hidden !== false) fill(row);
    }
  }

  function load(id) {
    sessionId = id;
    rows = [];
    canAdd = false;
    close();
    render();
    return refresh();
  }

  function clear() {
    sessionId = null;
    rows = [];
    canAdd = false;
    close();
    render();
  }

  function fill(row) {
    pop.innerHTML = popoverHtml(row, escapeHtml);
  }

  // Above the chip, inside the window with a 16px gutter.
  function place(chip) {
    const rect = chip.getBoundingClientRect();
    const width = Math.min(380, win.innerWidth - 32);
    pop.style.width = `${width}px`;
    pop.style.left = `${Math.max(16, Math.min(rect.left, win.innerWidth - width - 16))}px`;
    pop.style.bottom = `${Math.max(16, win.innerHeight - rect.top + 8)}px`;
  }

  function open(name, chip) {
    const row = rows.find((r) => r.name === name);
    if (!row) return;
    openName = name;
    fill(row);
    pop.hidden = false;
    place(chip);
    el.querySelectorAll(".ctx-chip").forEach((c) => c.classList.toggle("open", c.dataset.name === name));
  }

  function openAdd(chip, state = {}) {
    openName = ADD;
    pop.innerHTML = addFormHtml(escapeHtml, state);
    pop.hidden = false;
    place(chip);
    el.querySelectorAll(".ctx-chip").forEach((c) => c.classList.toggle("open", c === chip));
    pop.querySelector('input[name="url"]')?.focus();
  }

  async function submitAdd(form) {
    const id = sessionId;
    const url = form.elements.url.value.trim();
    const why = form.elements.why.value.trim();
    if (!id || !url) return;
    const button = form.querySelector(".ctx-add-submit");
    if (button) button.disabled = true;
    try {
      const data = await api.add(id, { url, why: why || undefined });
      if (id !== sessionId) return;
      close();
      await refresh();
      toast(`Attached ${data.name}: the agent gets a note before your next message`);
    } catch (e) {
      if (id !== sessionId || openName !== ADD) return;
      const chip = el.querySelector(".ctx-add");
      if (chip) openAdd(chip, { url, error: String(e.message).replace(/ \(\d+\)$/, "") });
    }
  }

  function close() {
    openName = null;
    pop.hidden = true;
    el.querySelectorAll(".ctx-chip.open").forEach((c) => c.classList.remove("open"));
  }

  async function viewText() {
    const name = openName;
    const pre = pop.querySelector(".ctx-pop-text");
    if (!name || !pre) return;
    try {
      const data = await api.show(sessionId, name);
      if (name !== openName) return;
      pre.textContent = data.text || "";
      pre.hidden = false;
      pop.querySelector('[data-act="view"]')?.remove();
    } catch (e) {
      toast(`Can't read ${name}: ${String(e.message).replace(/ \(\d+\)$/, "")}`);
    }
  }

  async function detach() {
    const row = rows.find((r) => r.name === openName);
    if (!row) return;
    const ask = row.scope === "project"
      ? `Mute ${row.name} for this session? It is the project's: other sessions keep it.`
      : `Detach ${row.name} from this session?`;
    if (!win.confirm(ask)) return;
    try {
      await api.detach(sessionId, row.name);
      close();
      await refresh();
    } catch (e) {
      toast(`Can't detach ${row.name}: ${String(e.message).replace(/ \(\d+\)$/, "")}`);
    }
  }

  el.addEventListener("click", (e) => {
    const chip = e.target.closest(".ctx-chip");
    if (!chip) return;
    e.stopPropagation();
    if (chip.dataset.act === "add") {
      if (openName === ADD) close();
      else openAdd(chip);
    } else if (openName === chip.dataset.name) close();
    else open(chip.dataset.name, chip);
  });
  pop.addEventListener("submit", (e) => {
    e.preventDefault();
    submitAdd(e.target);
  });
  pop.addEventListener("click", (e) => {
    const act = e.target.closest("[data-act]")?.dataset.act;
    if (act === "close") close();
    else if (act === "view") viewText();
    else if (act === "detach") detach();
  });
  doc.addEventListener("click", (e) => {
    if (openName && !pop.contains(e.target) && !el.contains(e.target)) close();
  });
  doc.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && openName) close();
  });
  win.addEventListener("resize", () => {
    const chip = openName && el.querySelector(".ctx-chip.open");
    if (chip) place(chip);
  });
  win.addEventListener("focus", () => refresh());
  // The ages move on by themselves.
  win.setInterval(() => { if (rows.length) render(); }, 60_000);

  return { load, clear, refresh, close, get rows() { return rows; } };
}
