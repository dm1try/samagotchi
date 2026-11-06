import { html } from "./vendor/lit-html.js";
import { cantText } from "./format.js";
import { workerBadgeFor } from "./info_bar_model.js";
import { readStored, writeStored } from "./storage.js";
import { createUpdateSheet } from "./update_sheet.js";
import { mergeVersionState, restartConfirmText, updateFrameToast, versionNotice } from "./update_notice.js";

// An available release's notice is once per version per browser, not per
// tab: chi web says it in every snapshot until the owner updates.
export const AVAILABLE_SHOWN_KEY = "chi_update_available_shown";

// The owner page's chi versions (used by app.js): the versions carried by each
// event snapshot and `chi` frame, the toasts they bring (chi web upgraded, a
// newer one installed, an aged one available to update to), the update sheet
// (update_sheet.js) and its `chi_update` frames, and the open session's
// worker Restart.
//
// +store+: the page's session store (selected and current read; it writes no
// field, only touch("infoBar"): the worker badge and the Restart button read
// the versions and the restarting set). +toasts+: toasts.js's. +dialog+: the
// update sheet's <dialog>. +loadedVersion+: the chi this page was loaded
// from (body data-version). +api+: {updateChi, restartWorkers, restartWeb,
// restartSession} (data.js). +confirm+, +reload+, +clipboard()+: the
// browser's; +storage+: storage.js's guarded read and write.
export function createVersionNotices({
  store, toasts, dialog, loadedVersion, api,
  confirm = (text) => globalThis.confirm(text),
  reload = () => globalThis.location.reload(),
  clipboard = () => globalThis.navigator?.clipboard,
  storage = { read: readStored, write: writeStored },
}) {
  const toast = (text, action = null, options = {}) => { toasts.show(text, action, options); };
  const sheet = createUpdateSheet({
    dialog,
    update: api.updateChi,
    restartWorkers: api.restartWorkers,
    restartWeb: api.restartWeb,
  });
  // Once per notice per tab: every reconnect's snapshot says it again.
  const versions = { served: null, installed: null };
  // The sessions whose Restart is under way (their button says so): one
  // session's restart never blocks another's.
  const restarting = new Set();
  const shown = new Set();
  const availableShown = storage.read(AVAILABLE_SHOWN_KEY);
  if (availableShown) shown.add(`available:${availableShown}`);
  let versionToast = null;

  function notice(data) {
    Object.assign(versions, mergeVersionState(versions, data));
    const next = versionNotice({ loaded: loadedVersion, served: versions.served,
                                 installed: versions.installed, available: versions.available,
                                 updateBlocked: versions.updateBlocked, auto: versions.auto, restart: versions.restart,
                                 autoOffers: versions.autoOffers, shown });
    store.touch("infoBar"); // the worker badge compares with the newest installed
    if (!next) return;
    shown.add(next.key);
    if (next.key.startsWith("available:")) storage.write(AVAILABLE_SHOWN_KEY, next.key.slice("available:".length));
    const text = next.releaseUrl
      ? html`${next.text} <a href=${next.releaseUrl} target="_blank" rel="noopener noreferrer">RubyGems</a>`
      : next.text;
    const action = next.reload
      ? { label: "Reload", run: () => reload() }
      : next.updateVersion
        ? { label: "Update", run: () => sheet.install(next.updateVersion) }
        : next.actions
          ? next.actions.map((name) => ({
            label: name === "restartWorkers" ? "Restart workers" : "Restart chi web",
            run: () => (name === "restartWorkers" ? sheet.restartWorkers() : sheet.restartWeb()),
          }))
      : next.command
        ? { label: "Copy", run: () => copyUpdateCommand(next.command) }
        : null;
    // One version toast at a time: a newer notice (Reload after a restart)
    // supersedes the one before it.
    toasts.dismiss(versionToast);
    versionToast = toasts.show(text, action, { sticky: true });
  }

  // A `chi_update` frame (+snapshot+: the one an event snapshot carries).
  function frame(data, { snapshot = false } = {}) {
    const wasOpen = sheet.isOpen();
    if (!sheet.receive(data)) return;
    if (data.operation === "install" && data.state === "done" && data.version) notice({ installed: data.version });
    const text = updateFrameToast(data, { wasOpen, snapshot });
    if (text) toast(text, { label: "View", run: () => sheet.view() }, { sticky: true });
  }

  // An event snapshot's version after Restart chi web: the sheet says done.
  function reconnected(version) {
    if (sheet.reconnected(version)) toast(`chi web reconnected on chi ${version}`);
  }

  function copyUpdateCommand(command) {
    const board = clipboard();
    if (!board?.writeText) {
      toast(`Clipboard unavailable; run ${command}`);
      return;
    }
    board.writeText(command).then(
      () => toast(`Copied ${command}`),
      () => toast(`Couldn't copy ${command}`),
    );
  }

  // The open session's worker badge (info_bar_model.js workerBadgeFor).
  function badge() {
    return workerBadgeFor(store.selected, store.current, versions);
  }

  // Restart: the session moves to a new worker on the newest chi; the page
  // follows it (its bridge_up), the composer's draft stays as it is.
  async function restart() {
    const current = badge();
    if (!current || !current.restart || restarting.has(store.selected)) return;
    if (!confirm(restartConfirmText(store.current.workerVersion, current.newest))) return;
    const id = store.selected;
    restarting.add(id);
    store.touch("infoBar");
    try {
      const result = await api.restartSession(id);
      toast(result.version ? `Restarted on chi ${result.version}` : "Restarting: the new worker is starting");
    } catch (e) {
      toast(cantText("restart", e), null, { sticky: true });
    } finally {
      restarting.delete(id);
      store.touch("infoBar");
    }
  }

  return { notice, frame, reconnected, versions: () => versions, restarting, restart };
}
