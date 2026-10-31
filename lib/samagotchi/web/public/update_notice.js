// What the page says about chi versions. An open tab keeps its JS across a
// `chi web` restart (its event streams just reconnect), so after an upgrade
// old page code talks to a new server: the page knows the version that
// served it (body data-version), and each GET /api/events snapshot names
// the one serving now and the newest installed (`chi` frames when that
// changes).

const known = (v) => typeof v === "string" && v !== "";
const has = (object, key) => Object.prototype.hasOwnProperty.call(object, key);

// Merge partial chi frames without treating an omitted field as a cleared value.
export function mergeVersionState(current = {}, frame = {}) {
  const next = { ...current };
  if (known(frame.version)) next.served = frame.version;
  if (has(frame, "installed")) next.installed = known(frame.installed) ? frame.installed : null;
  if (has(frame, "available")) next.available = known(frame.available) ? frame.available : null;
  if (has(frame, "update_blocked")) next.updateBlocked = known(frame.update_blocked) ? frame.update_blocked : null;
  if (has(frame, "auto")) next.auto = frame.auto === "install" ? "install" : "off";
  if (has(frame, "restart")) next.restart = frame.restart === "never" ? "never" : "idle";
  // The last install's chi_update state (a snapshot's, or a frame's): the
  // version an automatic one installs, while it hasn't failed.
  const run = frame.chi_update;
  if (run && run.operation === "install" && known(run.version)) {
    next.autoInstall = run.auto === true && run.state !== "failed" ? run.version : null;
  }
  return next;
}

// Gem::Version's order, near enough: segments of digits or letters, a
// missing one counts as 0, and letters (a prerelease: 0.19.0.pre1) sort
// below any number. <0, 0 or >0.
export function compareVersions(a, b) {
  const parts = (v) => (v.match(/[0-9]+|[a-z]+/gi) || []).map((p) => (/^[0-9]+$/.test(p) ? Number(p) : p));
  const x = parts(a);
  const y = parts(b);
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const p = i < x.length ? x[i] : 0;
    const q = i < y.length ? y[i] : 0;
    if (p === q) continue;
    if (typeof p === "number" && typeof q === "number") return p - q;
    if (typeof p === "number") return 1;
    if (typeof q === "number") return -1;
    return p < q ? -1 : 1;
  }
  return 0;
}

// Whether +a+ is a newer version than +b+ (false when either is unknown).
export function newerVersion(a, b) {
  return known(a) && known(b) && compareVersions(a, b) > 0;
}

// The toast for the versions as the page knows them, or null:
// - loaded ≠ served: chi web restarted on another version; reload the page;
// - installed newer than served: chi web runs an older chi than installed;
//   restart its workers or chi web; not for the version an automatic install
//   (+autoInstall+) brought with update.restart: idle, whose run restarts
//   them by itself (and pushes how it went);
// - available newer than served: install it, unless the install is blocked;
//   with update.auto: install (and not blocked) chi web installs it by itself
//   once no turn runs: the notice says so, with no Update button.
// Each has a key; one in +shown+ (a Set: what this tab already showed, as
// every reconnect's snapshot says it again) is not shown twice.
// @return {{key, text, reload: boolean} | null}
export function versionNotice({ loaded, served, installed, available, updateBlocked, auto, restart, autoInstall,
  shown = new Set() } = {}) {
  let notice = null;
  if (known(loaded) && known(served) && loaded !== served) {
    notice = { key: `reload:${served}`, text: `chi was updated to ${served}`, reload: true };
  } else if (newerVersion(installed, served)) {
    const restartsByItself = auto === "install" && restart !== "never" && autoInstall === installed;
    if (!restartsByItself) {
      notice = {
        key: `installed:${installed}`,
        text: `chi ${installed} is installed; this chi web runs ${served}.`,
        actions: ["restartWorkers", "restartWeb"],
        reload: false,
      };
    }
  } else if (newerVersion(available, served)) {
    const commands = {
      checkout: ["this chi is running from a checkout", "git pull"],
      bundler: ["chi update cannot run under Bundler", "bundle update samagotchi"],
      gem_dir_not_writable: ["the RubyGems directory is not writable", `gem install samagotchi -v ${available}`],
    };
    const blocked = commands[updateBlocked];
    const automatic = auto === "install" && !blocked;
    const command = blocked?.[1] || "chi update";
    notice = {
      key: `available:${available}`,
      text: blocked
        ? `chi ${available} is available (you run ${served}); ${blocked[0]}. Run ${command}.`
        : automatic
          ? `chi ${available} is available (you run ${served}); it installs by itself once no turn is running.`
          : `chi ${available} is available (you run ${served}).`,
      ...(blocked ? { command } : automatic ? {} : { updateVersion: available }),
      releaseUrl: `https://rubygems.org/gems/samagotchi/versions/${encodeURIComponent(available)}`,
      reload: false,
    };
  }
  return notice && !shown.has(notice.key) ? notice : null;
}

// The info bar's badge for the open session's worker when it runs an older
// chi than the newest installed (or than chi web, while that is unknown),
// else null. A worker with the "restart" feature offers Restart; an older
// one can only be stopped (any message then starts it on the newest chi).
// @return {{text, title, newest, restart: boolean} | null}
export function workerBadge({ workerVersion, features, installed, served, sessionId = "" } = {}) {
  const newest = known(installed) ? installed : served;
  if (!newerVersion(newest, workerVersion)) return null;
  if (Array.isArray(features) && features.includes("restart")) {
    return {
      text: `chi ${workerVersion}`,
      title: `This session's worker runs chi ${workerVersion}; chi ${newest} is installed. ` +
        `Restart hands the session to a new worker on chi ${newest}.`,
      newest,
      restart: true,
    };
  }
  const stop = `chi sessions stop ${String(sessionId).slice(0, 8)}`;
  return {
    text: `chi ${workerVersion} · ${stop}`,
    title: `This session's worker runs chi ${workerVersion}, which can't restart itself; chi ${newest} is installed. ` +
      `Stop it (${stop}), then any message starts it on chi ${newest}.`,
    newest,
    restart: false,
  };
}

// What the Restart confirm asks.
export function restartConfirmText(workerVersion, newest) {
  return `Restart this session's worker on chi ${newest} (it runs ${workerVersion})?\n\n` +
    "The conversation stays, and this page and attached terminals move to the new worker. " +
    "What lives only in the worker goes: kept /btw answers and plugins' in-memory state.";
}
