// A turn's tool rows as one line: "read 12 files · ran 3 commands · edited
// 2 files (engine.rb, worker.rb)". Pure, names only (rows carry a tool name
// and a project path, never args or output); the participant page folds a
// turn's rows into it, and the owner's page may later.
const READERS = new Set(["read"]);
const COMMANDS = new Set(["execute", "bash"]);
const EDITORS = new Set(["write", "edit"]);
const FILE_NAMES = 3;

const rowsOf = (rows) => (Array.isArray(rows) ? rows : []);
const namedPath = (row) => typeof row?.path === "string" && row.path ? row.path : null;
const basename = (path) => path.split(/[\\/]/).at(-1);
const noun = (count, singular, plural) => `${count} ${count === 1 ? singular : plural}`;

function fileCount(rows) {
  const paths = new Set(rows.map(namedPath).filter(Boolean));
  return paths.size + rows.filter((row) => !namedPath(row)).length;
}

function fileNames(rows) {
  const paths = [...new Set(rows.map(namedPath).filter(Boolean))];
  const names = paths.slice(0, FILE_NAMES).map(basename);
  if (paths.length > FILE_NAMES) names.push("…");
  return names.length ? ` (${names.join(", ")})` : "";
}

export function toolsOverview(rows) {
  const list = rowsOf(rows);
  if (!list.length) return "";

  const readers = list.filter((row) => READERS.has(row?.tool));
  const commands = list.filter((row) => COMMANDS.has(row?.tool));
  const editors = list.filter((row) => EDITORS.has(row?.tool));
  const otherCount = list.length - readers.length - commands.length - editors.length;
  const parts = [];

  if (readers.length) parts.push(`read ${noun(fileCount(readers), "file", "files")}`);
  if (commands.length) parts.push(`ran ${noun(commands.length, "command", "commands")}`);
  if (editors.length) parts.push(`edited ${noun(fileCount(editors), "file", "files")}${fileNames(editors)}`);
  if (otherCount) parts.push(`used ${noun(otherCount, "other tool", "other tools")}`);
  return parts.join(" · ");
}
