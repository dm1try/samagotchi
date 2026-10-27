import { html, nothing, render } from "./vendor/lit-html.js";

function installRow(row) {
  const kept = Array.isArray(row.kept) ? row.kept.map(String) : [];
  const versions = [row.from, row.to].filter(Boolean).join(" → ");
  return html`<li class="us-row">
    <div class="us-row-head"><strong>${row.component || "chi update"}</strong><span>${row.status || "working"}</span></div>
    ${versions ? html`<div class="us-detail">${versions}</div>` : nothing}
    ${kept.length ? html`<div class="us-kept"><strong>Kept edited files:</strong><ul>${kept.map((file) => html`<li>${file}</li>`)}</ul></div>` : nothing}
  </li>`;
}

function workerRow(row) {
  const sessionId = String(row.session_id || "unknown");
  const detail = row.detail || row.reason;
  const holds = Array.isArray(row.holds) ? row.holds.map((hold) => String(hold).replaceAll("_", " ")).join(", ") : "";
  const version = row.version ? `chi ${row.version}` : "";
  return html`<li class="us-row">
    <div class="us-row-head"><strong title=${sessionId}>${sessionId.slice(0, 8)}</strong>
      <span>${String(row.state || "working").replaceAll("_", " ")}</span></div>
    ${version ? html`<div class="us-detail">${version}</div>` : nothing}
    ${detail ? html`<div class="us-detail">${detail}</div>` : nothing}
    ${holds ? html`<div class="us-detail">Holds: ${holds}</div>` : nothing}
  </li>`;
}

function operationTitle(model) {
  if (model.operation === "install") return `Update chi${model.version ? ` to ${model.version}` : ""}`;
  if (model.operation === "workers") return "Restart workers";
  return "Restart chi web";
}

// A running operation's last progress line; the end's own words after it
// (a done frame carries no progress, and the last line would stay).
function statusText(model) {
  if (model.error) return model.error;
  if (model.operation === "web" && model.state === "restarting") return "Waiting for chi web to reconnect…";
  if (model.operation === "web" && model.state === "done") return `Reconnected${model.version ? ` on chi ${model.version}` : ""}.`;
  if (model.state === "starting") return "Starting…";
  if (model.state === "running") return model.progress || (model.operation === "install" ? "Installing…" : "Restarting…");
  if (model.state === "done") return model.operation === "install" ? "Update complete." : "Worker restart results.";
  return "Operation failed.";
}

// Both restarts, once a newer chi is installed (an install done here, or the
// installed notice's toast) and nothing runs: either result keeps the other in reach.
function restartActions(model) {
  const busy = ["starting", "running", "restarting"].includes(model.state);
  if (!model.restartable || busy) return nothing;
  return html`<button type="button" class="ghost" data-act="restart-workers">Restart workers</button>
    <button type="button" class="ghost" data-act="restart-web">Restart chi web</button>`;
}

export function updateSheetTemplate(model) {
  const rows = Array.isArray(model.rows) ? model.rows : [];
  const rowTemplate = model.operation === "workers" ? workerRow : installRow;
  return html`<header class="us-head">
    <h2 id="updateSheetTitle">${operationTitle(model)}</h2>
    <button type="button" class="us-close" data-act="close" aria-label="Close">×</button>
  </header>
  <p class="us-status" aria-live="polite">${statusText(model)}</p>
  ${rows.length ? html`<ol class="us-rows">${rows.map(rowTemplate)}</ol>` : nothing}
  <footer class="us-foot">${restartActions(model)}<button type="button" class="ghost" data-act="close">Close</button></footer>`;
}

// The update progress/result sheet; operations continue if it is dismissed.
export function createUpdateSheet({ dialog, update, restartWorkers, restartWeb }) {
  let model = null;
  let requestId = 0;
  let restartable = false;

  function draw() {
    if (model) render(updateSheetTemplate({ ...model, restartable }), dialog);
  }

  function show(next) {
    model = { ...next, requestId: ++requestId };
    draw();
    if (!dialog.open) dialog.showModal();
  }

  function fail(error, expectedId) {
    if (!model || model.requestId !== expectedId) return;
    model = { ...model, state: "failed", error: error?.message || String(error) };
    draw();
  }

  function request(action) {
    const expectedId = model.requestId;
    Promise.resolve().then(action).catch((error) => fail(error, expectedId));
  }

  dialog.addEventListener("click", (event) => {
    const act = event.target.closest?.("[data-act]")?.dataset.act;
    if (act === "close") dialog.close();
    else if (act === "restart-workers") openWorkers();
    else if (act === "restart-web") openWeb();
  });

  function openInstall(version) {
    show({ operation: "install", version, state: "starting", rows: [] });
    request(() => update(version));
  }

  function openWorkers() {
    restartable = true;
    show({ operation: "workers", state: "starting", rows: [] });
    request(restartWorkers);
  }

  function openWeb() {
    restartable = true;
    show({ operation: "web", state: "restarting", rows: [] });
    request(restartWeb);
  }

  function receive(data) {
    if (!["install", "workers"].includes(data?.operation)) return false;
    if (model?.operation === "web" && model.state === "restarting") return false;
    if (!model || (model.operation !== data.operation && ["done", "failed"].includes(model.state))) {
      model = { operation: data.operation, state: data.state, rows: [], version: data.version };
    }
    if (model.operation !== data.operation) return false;
    model = {
      ...model,
      ...data,
      rows: Array.isArray(data.rows) ? data.rows : [],
    };
    if (data.operation === "install" && data.state === "done") restartable = true;
    draw();
    return true;
  }

  function reconnected(version) {
    if (model?.operation !== "web" || model.state !== "restarting") return false;
    model = { ...model, state: "done", version };
    draw();
    return true;
  }

  function view() {
    if (!model) return false;
    draw();
    if (!dialog.open) dialog.showModal();
    return true;
  }

  return {
    install: openInstall,
    restartWorkers: openWorkers,
    restartWeb: openWeb,
    receive,
    reconnected,
    view,
    close: () => dialog.close(),
    isOpen: () => dialog.open,
  };
}
