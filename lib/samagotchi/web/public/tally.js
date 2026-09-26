// The one-line tool tally of a long, tool-heavy turn, from its activity rows
// (activity.js): "12 tool calls (2 failed) · execute ×7 · read_file ×3 · …".
// The TUI builds the same text in Ruby (TurnTally); both follow
// spec/shared/tally_matrix.json. No DOM here, so node --test covers it.

// Below this many calls the running row says enough.
export const MIN_CALLS = 3;
import { toolName } from "./activity.js";

const TOP_TOOLS = 3;
const SEPARATOR = " · ";

// @param rows activity rows ({ tool, params, status: running|ok|error }) in call order
// @param opts.last end with the last call and its params (the web drops it: the rows show it)
// @returns the tally text, or null below MIN_CALLS
export function tallyText(rows, { last = true } = {}) {
  const calls = rows || [];
  if (calls.length < MIN_CALLS) return null;

  const failed = calls.filter((r) => r.status === "error").length;
  let head = `${calls.length} tool calls`;
  if (failed > 0) head += ` (${failed} failed)`;
  // A Map keeps first-use order; the index breaks ties.
  const counts = new Map();
  for (const r of calls) counts.set(toolName(r), (counts.get(toolName(r)) || 0) + 1);
  const top = [...counts.entries()]
    .map(([tool, n], i) => ({ tool, n, i }))
    .sort((a, b) => b.n - a.n || a.i - b.i)
    .slice(0, TOP_TOOLS);
  const fields = [head, ...top.map(({ tool, n }) => `${tool} ×${n}`)];
  if (last) {
    const call = calls[calls.length - 1];
    const params = String(call.params || "").replace(/\s+/g, " ").trim();
    fields.push(`last: ${[toolName(call), params].filter((s) => s).join(" ")}`);
  }
  return fields.join(SEPARATOR);
}
