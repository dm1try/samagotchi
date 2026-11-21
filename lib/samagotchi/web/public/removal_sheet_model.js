// The delete / archive sheet's words (docs/internals/web-frontend.md, The
// delete sheet), DOM-free: the rows (Goes / Stopped first / Stays; Hidden
// for an archive), the button's words, the archive's model and the toast
// after a delete. delete_sheet.js draws them (its templates, its flow and its
// shell); session_actions.js starts it. A module of its own: the page's
// modules are cached at unversioned URLs ("New exports go in new modules").
//
// What it reads is the server's (GET …/delete_plan, SessionChain::Delete::
// Preview): each choice's +delegates+ ({delete: [ids], leave: [{id,
// running}]}), +tasks+ ({running, unverified, unreadable}, RunningTasks'
// wire form), +worker+ ("turn" / "idle" / null; a chain's {idle, turn}) and
// +refusal+; an archive's 409 tasks_running (+tasks+, +sessions+). A card's
// name is the page's rule (format.js cardName) from its own list, else the
// short id.
//
// A row's line is a list of parts: a string, {b} (bold) or {dim}.

import { cardName, clip, normalize } from "./format.js";
import { NAMED_MAX, tasksCount, tasksLine, tasksStoppedSuffix } from "./running_tasks.js";

const short = (id) => String(id ?? "").slice(0, 8);
const count = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
const capital = (text) => (text ? `${text.charAt(0).toUpperCase()}${text.slice(1)}` : text);
// A server's refusal words (lower case, no stop) as a sentence.
const sentence = (text) => {
  const s = capital(String(text ?? "").trim());
  return s && !/[.!?]$/.test(s) ? `${s}.` : s;
};

export const UNDONE = "This can't be undone.";

// The session's name as the list shows it, cut for a sheet's title.
export function sessionName(session) {
  return clip(normalize(session ? cardName(session) : ""), 41);
}

// "Delete 3f2a91c0 — "Nightly triage"?" (+verb+ Delete / Archive).
export function sheetTitle(verb, id, session) {
  const name = sessionName(session);
  return `${verb} ${short(id)}${name ? ` — "${name}"` : ""}?`;
}

// The sessions +ids+ named as the list names them (9d0e1f2a "run the
// specs"), NAMED_MAX at most, then "+N more".
export function namesLine(ids, sessions = []) {
  const byId = new Map(sessions.map((s) => [s.id, s]));
  const names = ids.map((id) => {
    const name = clip(normalize(byId.has(id) ? cardName(byId.get(id)) : ""), 30);
    return name ? `${short(id)} "${name}"` : short(id);
  });
  const more = names.length - NAMED_MAX;
  return `${names.slice(0, NAMED_MAX).join(" · ")}${more > 0 ? ` +${more} more` : ""}`;
}

// A choice's tasks split as the sheet says them: the running ones it stops,
// the ones chi can't verify or read it leaves (never signalled).
function taskParts(listing) {
  if (Array.isArray(listing)) return { running: listing, unsure: { unverified: [], unreadable: [] } };
  return {
    running: listing?.running || [],
    unsure: { unverified: listing?.unverified || [], unreadable: listing?.unreadable || [] },
  };
}

// The running tasks' ids a stop is given (the tap stops only those).
export function runningTaskIds(listing) {
  return taskParts(listing).running.map((task) => task.id).filter(Boolean);
}

// What a tap sends with its delete or archive: stopTasks and the named ids
// whenever the choice lists any task (also when it holds only records chi
// can't verify: the server refuses on those too, and a stop never signals
// them), else nothing.
export function stopTasksOptions(listing) {
  return tasksCount(listing) > 0 ? { stopTasks: true, tasks: runningTaskIds(listing) } : {};
}

// The delegates a choice leaves: the running ones, and the stopped ones under
// them (they stay with their running delegate). Without +delegates+ (an
// older server) its count reads as running ones.
function leftDelegates(choice) {
  const leave = choice?.delegates?.leave;
  if (!Array.isArray(leave)) return { running: [], under: 0, n: choice?.left_running || 0 };
  const running = leave.filter((d) => d.running !== false).map((d) => d.id);
  return { running, under: leave.length - running.length, n: running.length };
}

function goneDelegates(choice) {
  const ids = choice?.delegates?.delete;
  return Array.isArray(ids) ? ids : [];
}

function turnCount(worker) {
  if (worker === "turn") return 1;
  return worker && typeof worker === "object" ? worker.turn || 0 : 0;
}

// The rows of one session's choice (the plan's +link+ for a session in no
// chain): Goes, Stopped first, Stays, each only when it applies.
// @return [{key: "goes"|"stop"|"stays", label, lines: [[part]]}]
export function sheetGroups(choice, { sessions = [], sessionId = null } = {}) {
  const groups = [];
  const gone = goneDelegates(choice);
  const goes = [["Its history, notes and images."]];
  if (gone.length) goes.push([{ b: count(gone.length, "stopped delegate") }, `: ${namesLine(gone, sessions)}`]);
  groups.push({ key: "goes", label: "Goes", lines: goes });

  const { running, unsure } = taskParts(choice?.tasks);
  const stop = [];
  if (choice?.worker === "turn") stop.push([{ b: "Its running turn" }, ": it ends as stopped, its worker goes."]);
  else if (choice?.worker === "idle") stop.push(["Its worker ", { dim: "(idle)" }, "."]);
  if (running.length) stop.push([{ b: count(running.length, "background task") }, `: ${tasksLine({ running }, sessionId)}`]);
  if (stop.length) groups.push({ key: "stop", label: "Stopped first", lines: stop });

  const stays = [];
  const left = leftDelegates(choice);
  if (left.n) {
    const one = left.n === 1;
    const under = left.under ? `, with ${one ? "its" : "their"} ${count(left.under, "delegate")}` : "";
    const named = left.running.length ? ` ${namesLine(left.running, sessions)}` : "";
    stays.push([{ b: `${count(left.n, "running delegate")}${under}` },
                `:${named} ${one ? "keeps" : "keep"} running on ${one ? "its" : "their"} own, without a parent.`]);
  }
  const n = tasksCount(unsure);
  if (n) {
    stays.push([{ b: `${count(n, "task")} chi can't verify` },
                `: ${tasksLine(unsure, sessionId)}. chi leaves ${n === 1 ? "it as it is" : "them as they are"}.`]);
  }
  if (stays.length) groups.push({ key: "stays", label: "Stays", lines: stays });
  return groups;
}

// The button's words (decision 3): it names the running work it ends (the
// tasks, a turn); an idle worker is only a row. +op+: "delete" or
// "archive"; +object+: what a chain's choice deletes ("this link", "the
// whole chain"), "" for one session; +sessions+: how many sessions the tap
// takes (" · 3 sessions" from 2).
export function buttonWords(choice, { op = "delete", object = "", sessions = 1 } = {}) {
  const tasks = taskParts(choice?.tasks).running.length;
  const turns = turnCount(choice?.worker);
  const target = object ? `${op} ${object}` : op;
  let words;
  if (object) {
    const ends = [turns && (turns === 1 ? "the turn" : count(turns, "turn")), tasks && count(tasks, "task")].filter(Boolean);
    words = ends.length ? `Stop ${ends.join(" and ")} and ${target}` : capital(target);
  } else if (tasks && turns) {
    words = `Stop the turn and tasks and ${target}`;
  } else if (tasks) {
    words = `Stop ${tasks === 1 ? "it" : "them"} and ${target}`;
  } else if (turns) {
    words = `Stop the turn and ${target}`;
  } else {
    words = capital(target);
  }
  return sessions > 1 ? `${words} · ${count(sessions, "session")}` : words;
}

// Whether a tap stops running work first: the sheet then says "Stopping…".
export function stopsFirst(choice) {
  return taskParts(choice?.tasks).running.length > 0 || turnCount(choice?.worker) > 0;
}

// A refusal the plan carries (a one-turn run, a schedule, a continue), or a
// plan that can't be read: why, and only Close.
// @return {title, sub, close: true}
export function cantModel(verb, id, refusal) {
  return { title: `Can't ${verb} ${short(id)} now`, sub: sentence(refusal?.message) || "Not now.", close: true };
}

// The sheet for a session in no chain, from its plan's +link+.
// @return {title, groups, button, stops, foot, tasks} | cantModel's
export function sessionSheetModel(session, plan, sessions = []) {
  const id = session?.id ?? plan?.session_id;
  const link = plan?.link || {};
  if (link.refusal && link.refusal.reason !== "delegate_unmovable") return cantModel("delete", id, link.refusal);
  return {
    title: sheetTitle("Delete", id, session),
    groups: sheetGroups(link, { sessions, sessionId: id }),
    button: buttonWords(link, { sessions: 1 + goneDelegates(link).length }),
    stops: stopsFirst(link),
    foot: UNDONE,
    tasks: link.tasks || null,
  };
}

// A chain's choice's own lines (the mock-up's case 8): what is stopped first
// and what stays, after its first lines. [{cls, text}]
export function choiceTail(choice, sessionId = null) {
  const lines = [];
  const { running, unsure } = taskParts(choice?.tasks);
  const stop = [turnCount(choice?.worker) && (turnCount(choice.worker) === 1 ? "its running turn" : count(turnCount(choice.worker), "running turn")),
                running.length && tasksLine({ running }, sessionId)].filter(Boolean);
  if (stop.length) lines.push({ cls: "stop", text: `Stopped first: ${stop.join(" · ")}` });
  const left = leftDelegates(choice);
  const stays = [];
  if (left.n) {
    const one = left.n === 1;
    stays.push(`${count(left.n, "running delegate")}${left.under ? `, with ${one ? "its" : "their"} ${count(left.under, "delegate")}` : ""}, on ${one ? "its" : "their"} own`);
  }
  const n = tasksCount(unsure);
  if (n) stays.push(`${count(n, "task")} chi can't verify (${tasksLine(unsure, sessionId)})`);
  if (stays.length) lines.push({ cls: "stays", text: `Stays: ${stays.join("; ")}.` });
  return lines;
}

// Archive's ask, from its 409 (+refusal+: the error, its body the route's):
// tasks_running is the sheet in Archive's words (Hidden, Stopped first, and
// Stays for a task chi can't verify); any other refusal is Can't archive.
// @return {title, groups, button, stops, foot, tasks, warn: true} | cantModel's
export function archiveSheetModel(session, refusal, sessions = []) {
  const id = session?.id ?? refusal?.body?.session_id;
  if (refusal?.code !== "tasks_running") return cantModel("archive", id, refusal);
  const body = refusal.body || {};
  const tasks = body.tasks || null;
  const others = Math.max(0, (Number.isInteger(body.sessions) ? body.sessions : 1) - 1);
  const hidden = others
    ? ["It and its ", { b: count(others, "delegate") }, " leave the lists and are kept for good."]
    : ["It leaves the lists and is kept for good."];
  const choice = { tasks };
  const groups = [{ key: "hidden", label: "Hidden", lines: [hidden] },
                  ...sheetGroups(choice, { sessions, sessionId: id }).filter((g) => g.key !== "goes")];
  return {
    title: sheetTitle("Archive", id, session),
    groups,
    button: buttonWords(choice, { op: "archive" }),
    stops: stopsFirst(choice),
    foot: `Undo brings the ${others ? "sessions" : "session"} back. Stopped tasks stay stopped.`,
    tasks,
    warn: true,
  };
}

// The delegates a delete left that still run: +left_running+ is the running
// ones with their subtrees, so the stopped ones the plan's choice lists
// (+delegates.leave+, running false) stay with theirs, unsaid.
function stillRunning(result, choice) {
  const leave = choice?.delegates?.leave;
  const stopped = new Set(Array.isArray(leave) ? leave.filter((d) => d.running === false).map((d) => d.id) : []);
  return (result.left_running || []).filter((sid) => !stopped.has(sid));
}

// The toast after a delete (the mock-up's case 14): what went, what was
// stopped, what stays. +which+: "this" or "chain"; +result+: the route's
// 200; +plan+: the sheet's. +back+: a session to offer opening (the link
// that came back, else a delegate left running), or null. +withTasks+ false
// leaves the stopped tasks out (an older cached caller adds them itself).
// @return {text, back}
export function deleteToast(which, result, plan, id, { withTasks = true } = {}) {
  const tasks = withTasks ? tasksStoppedSuffix(result) : "";
  const running = stillRunning(result, which === "chain" ? plan?.chain : plan?.link);
  const keeps = running.length === 1
    ? ` · ${short(running[0])} keeps running`
    : running.length ? ` · ${count(running.length, "delegate")} keep running` : "";
  if (which === "chain") {
    const left = (result.left || []).length;
    const links = Math.max(0, (plan?.chain?.links ?? 0) - left);
    const delegates = Math.max(0, (result.deleted || []).length - links);
    let text = `Deleted the chain: ${count(links, "session")}${delegates ? ` and ${count(delegates, "delegate")}` : ""}${tasks}${keeps}.`;
    if (left) text += ` ${count(left, "link")} kept: ${result.refusal}`;
    return { text, back: running.length === 1 ? running[0] : null };
  }
  const back = (result.unarchived || [])[0] || null;
  if (back) {
    // The sheet's count (each moved delegate with its subtree) when it had one.
    const moved = (result.moved_back || []).length ? (plan?.link?.moved || result.moved_back.length) : 0;
    const took = [moved && count(moved, "delegate"), plan?.link?.notes && count(plan.link.notes, "note")].filter(Boolean);
    return { text: `Deleted ${short(id)}${tasks}${keeps}. ${short(back)} is back${took.length ? `, with ${took.join(" and ")}` : ""}.`, back };
  }
  const delegates = (result.deleted || []).filter((sid) => sid !== id).length;
  return { text: `Deleted ${short(id)}${delegates ? ` and ${count(delegates, "delegate")}` : ""}${tasks}${keeps}`,
           back: running.length === 1 ? running[0] : null };
}
