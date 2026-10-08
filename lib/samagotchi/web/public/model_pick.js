// The start page's model picker: pure helpers over GET /api/models' payload.

export const MODEL_KEY = "chi_model";

// The name to preselect: the remembered one when it is still offered (any
// case), else the server's default, else the first offered, else "".
export function pickModel(names, defaultName, stored) {
  const want = String(stored || "").trim().toLowerCase();
  if (want) {
    const kept = names.find((n) => n.toLowerCase() === want);
    if (kept) return kept;
  }
  if (defaultName && names.includes(defaultName)) return defaultName;
  return defaultName || names[0] || "";
}


export const RECENT_KEY = "chi_model_recent";

// The payload's models as rows: {name, host, id, isDefaultHost}, and
// sampling (the configured request parameters as /model words them) when
// the model has some, and llm_context (the LLM context it starts under,
// LLMContextStrategy::Explained#summary) when the server sent one. The
// default host's names are bare (name == id); the server's own default,
// unshifted when no host lists it, has no host and goes with them, shown
// by its name.
export function modelRows(payload) {
  const list = Array.isArray(payload?.models) ? payload.models : [];
  return list
    .filter((m) => m && String(m.name || ""))
    .map((m) => {
      const name = String(m.name);
      const host = m.host ? String(m.host) : "";
      const id = host ? String(m.id || name) : name;
      const row = { name, host, id, isDefaultHost: !host || name === id };
      if (m.sampling) row.sampling = String(m.sampling);
      if (m.llm_context && typeof m.llm_context === "object") row.llm_context = m.llm_context;
      return row;
    });
}

const byId = (a, b) => a.id.localeCompare(b.id, "en", { sensitivity: "base" });

// The rows under their hosts, [{host, isDefault, rows}]: the default host
// first, the others in the server's order, ids A-Z inside a host.
export function groupRows(rows) {
  const groups = [];
  const find = (key) => groups.find((g) => g.key === key);
  for (const row of rows) {
    const key = row.isDefaultHost ? "" : row.host;
    let group = find(key);
    if (!group) {
      group = { key, host: row.host, isDefault: row.isDefaultHost, rows: [] };
      if (row.isDefaultHost) groups.unshift(group); else groups.push(group);
    }
    if (!group.host && row.host) group.host = row.host;
    group.rows.push(row);
  }
  return groups.map(({ host, isDefault, rows: rs }) => ({
    host: host || "default", isDefault, rows: [...rs].sort(byId),
  }));
}

const SEPARATORS = "/-:._ ";
const atSegmentStart = (text, i) => i === 0 || SEPARATORS.includes(text[i - 1]);

// One word against one field (both lowercased): {sub, cost, marks} or null.
// A substring is best, at a segment start better still; else, for words of
// 3+ characters, a subsequence taken greedily from the leftmost start,
// costing more per gap.
function matchWord(word, text) {
  let best = null;
  for (let i = text.indexOf(word); i >= 0; i = text.indexOf(word, i + 1)) {
    const cost = atSegmentStart(text, i) ? 0 : 2;
    if (!best || cost < best.cost) best = { sub: true, cost, marks: [[i, i + word.length]] };
    if (cost === 0) break;
  }
  if (best || word.length < 3) return best;
  const marks = [];
  let gaps = 0;
  let at = text.indexOf(word[0]);
  if (at < 0) return null;
  for (let k = 0; k < word.length; k++) {
    const i = k === 0 ? at : text.indexOf(word[k], at + 1);
    if (i < 0) return null;
    if (k > 0) gaps += i - at - 1;
    const last = marks[marks.length - 1];
    if (last && last[1] === i) last[1] = i + 1; else marks.push([i, i + 1]);
    at = i;
  }
  return { sub: false, cost: 10 + gaps, marks };
}

function mergeMarks(marks) {
  const sorted = [...marks].sort((a, b) => a[0] - b[0]);
  const out = [];
  for (const [a, b] of sorted) {
    const last = out[out.length - 1];
    if (last && a <= last[1]) last[1] = Math.max(last[1], b); else out.push([a, b]);
  }
  return out;
}

const better = (a, b) => !b || (a.sub && !b.sub) || (a.sub === b.sub && a.cost < b.cost);

// The rows matching every word of +query+ against the host or the shown id,
// ranked: substring-only rows first, then the summed cost, the shorter id,
// the rows' own order. Each {row, hostMarks, idMarks} carries [start, end)
// ranges into its field; a default-host row's host is not shown, so it
// gets none. [] for a blank query.
export function matchModels(rows, query) {
  const words = String(query || "").toLowerCase().split(/\s+/).filter(Boolean);
  if (!words.length) return [];
  const found = [];
  rows.forEach((row, index) => {
    const host = row.host.toLowerCase();
    const id = row.id.toLowerCase();
    const hostMarks = [];
    const idMarks = [];
    let sub = true;
    let cost = 0;
    for (const word of words) {
      const onId = matchWord(word, id);
      const onHost = matchWord(word, host);
      const pick = onId && !better(onHost || { sub: false, cost: Infinity }, onId) ? onId : onHost;
      if (!pick) return;
      (pick === onId ? idMarks : hostMarks).push(...pick.marks);
      sub = sub && pick.sub;
      cost += pick.cost;
    }
    found.push({
      row, index, sub, cost,
      hostMarks: row.isDefaultHost ? [] : mergeMarks(hostMarks),
      idMarks: mergeMarks(idMarks),
    });
  });
  found.sort((a, b) => (b.sub - a.sub) || (a.cost - b.cost) ||
    (a.row.id.length - b.row.id.length) || (a.index - b.index));
  return found.map(({ row, hostMarks, idMarks }) => ({ row, hostMarks, idMarks }));
}

// The recent list after picking +name+: it first, no other copy (any case),
// at most +max+.
export function pushRecent(list, name, max = 5) {
  const prior = (Array.isArray(list) ? list : []).filter((n) => typeof n === "string" && n);
  if (!name) return prior.slice(0, max);
  const want = name.toLowerCase();
  return [name, ...prior.filter((n) => n.toLowerCase() !== want)].slice(0, max);
}

// The rows for the recent names still offered, newest first.
export function recentRows(rows, list) {
  if (!Array.isArray(list)) return [];
  return list
    .filter((n) => typeof n === "string")
    .map((n) => rows.find((r) => r.name.toLowerCase() === n.toLowerCase()))
    .filter(Boolean);
}
