// A session's background tasks a delete or an archive was refused for
// (the 409 tasks_running, SessionManager::RunningTasks), in the page's
// words: their one line, the second confirm, the toast's suffix after a
// stop. DOM-free (no lit-html): format.js-style text helpers, a module of
// their own (docs/internals/web-frontend.md, "New exports go in new modules").
// session_actions.js asks the confirm; delete_sheet.js' refusal view and
// stop_sheet.js' cut share NAMED_MAX and cutCommand.

// At most this many tasks (or holds of a kind) named in a line; the rest
// are one "+N more" (stop_sheet.js MAX_NAMED, RunningTasks::MAX_NAMED).
export const NAMED_MAX = 3;

// A command (a task's, a hold's label) cut short to fit a phone line
// (RunningTasks::COMMAND_CHARS).
export function cutCommand(label) {
  return label.length > 42 ? `${label.slice(0, 42)}…` : label;
}

// The background tasks a delete or an archive was refused for (the 409
// tasks_running's tasks: {running, unverified, unreadable}, each
// [{session_id, id, command}]; a plain array reads as running), as one line:
// "npm run dev · rspec", at most NAMED_MAX named then "+N more". A task of
// another session than +sessionId+ (a delegate's, another link's) carries
// its short id ("9d0e1f2a: rspec"); one chi can't verify or read is named by
// its id. SessionManager::RunningTasks.words is the CLI's twin.
export function tasksLine(listing, sessionId = null) {
  const names = taskEntries(listing).map(({ task, kind }) => {
    const hex = String(task?.id ?? "").split("-").pop().slice(0, 8);
    let name;
    if (kind === "unverified") name = `task ${hex} (may still be running)`;
    else if (kind === "unreadable") name = `task ${hex} (record unreadable)`;
    else name = String(task?.command ?? "").trim() ? cutCommand(String(task.command).trim()) : `task ${hex}`;
    const owner = String(task?.session_id ?? "");
    return sessionId && owner && owner !== sessionId ? `${owner.slice(0, 8)}: ${name}` : name;
  });
  const more = names.length - NAMED_MAX;
  return `${names.slice(0, NAMED_MAX).join(" · ")}${more > 0 ? ` +${more} more` : ""}`;
}

// How many tasks +listing+ (as tasksLine's) holds.
export function tasksCount(listing) {
  return taskEntries(listing).length;
}

function taskEntries(listing) {
  if (Array.isArray(listing)) return listing.map((task) => ({ task, kind: "running" }));
  return ["running", "unverified", "unreadable"].flatMap((kind) =>
    (Array.isArray(listing?.[kind]) ? listing[kind] : []).map((task) => ({ task, kind })));
}

// The second confirm of a delete or an archive refused for background tasks
// still running (409 tasks_running): which, and whether to stop them and
// +verb+ ("delete" / "archive") the session. +listing+ is the 409's tasks.
export function tasksConfirmText(id, listing, verb) {
  const n = tasksCount(listing);
  const one = n === 1;
  return [
    `Session ${String(id).slice(0, 8)} started ${n} background task${one ? "" : "s"} that ${one ? "is" : "are"} still running:`,
    tasksLine(listing, id),
    `Stop ${one ? "it" : "them"} and ${verb} the session?`,
  ].join("\n");
}

// What a delete's or an archive's toast adds for the tasks it stopped (its
// 200's tasks_stopped / tasks_not_stopped): " · stopped 2 background tasks",
// " · 1 not stopped: npm run dev"; "" when it stopped none.
export function tasksStoppedSuffix(result) {
  const stopped = (result?.tasks_stopped || []).length;
  const left = result?.tasks_not_stopped || [];
  let text = stopped ? ` · stopped ${stopped} background task${stopped === 1 ? "" : "s"}` : "";
  if (left.length) text += ` · ${left.length} not stopped: ${tasksLine(left, result?.session_id ?? null)}`;
  return text;
}
