// What chi's edit/write tools change, as HTML, apart from the DOM. One
// renderer for both places: the approval card (the dry run, which can also
// say the edit would fail, or that the file isn't shown) and a tool row's
// collapsed "diff +3 −1" (what the call really changed). A diff is the
// server's {text, added, removed, truncated, new_file} (EditPreview).

import { escapeHtml } from "./format.js";

// More lines than this fold behind a "show all N lines" toggle.
export const DIFF_FOLD_LINES = 20;

const MINUS = "−";

// "+3 −1"
export function diffCounts(diff) {
  return `+${Number(diff?.added) || 0} ${MINUS}${Number(diff?.removed) || 0}`;
}

// A row's summary line: "diff +3 −1", "new file +12".
export function diffSummary(diff) {
  return diff?.new_file ? `new file +${Number(diff.added) || 0}` : `diff ${diffCounts(diff)}`;
}

export function diffLineClass(line) {
  if (line.startsWith("@@")) return "hunk";
  if (line.startsWith("+")) return "add";
  if (line.startsWith("-")) return "del";
  if (line.startsWith("\\") || line.startsWith("… ")) return "meta";
  return "ctx";
}

// Each line's line number in the file after the change (the new side),
// from the hunk headers ("@@ -a,b +c,d @@"): a hunk header its hunk's
// start, a context or added line its own, a removed line the line it was
// removed before; null outside a hunk and for a meta line ("\ No newline
// at end of file", "… N more lines"). An emptied file's hunk (+0,0) gives
// 0, which no line carries.
export function diffLineNumbers(lines) {
  let next = null;
  return lines.map((line) => {
    const kind = diffLineClass(line);
    if (kind === "hunk") {
      const m = /^@@ -\d+(?:,\d+)? \+(\d+)/.exec(line);
      next = m ? Number(m[1]) : null;
      return next;
    }
    if (next === null || kind === "meta") return null;
    if (kind === "del") return next;
    return next++;
  });
}

// A line with a number carries it as data-line (refs.js opens it there).
function linesHtml(lines, numbers) {
  return lines.map((line, i) => {
    const at = numbers[i] > 0 ? ` data-line="${numbers[i]}"` : "";
    return `<span class="diff-line diff-${diffLineClass(line)}"${at}>${escapeHtml(line) || " "}</span>`;
  }).join("");
}

// @param diff an EditPreview: a diff, or {error} / {skipped}
// @return {string} HTML; "" for none
export function diffHtml(diff, { fold = DIFF_FOLD_LINES } = {}) {
  if (!diff || typeof diff !== "object") return "";
  if (diff.error) return `<div class="diff-note warn">this edit would fail: ${escapeHtml(diff.error)}</div>`;
  if (diff.skipped) return `<div class="diff-note">diff not shown: ${escapeHtml(diff.skipped)}</div>`;
  const text = String(diff.text ?? "");
  if (!text) return `<div class="diff-note">no change</div>`;
  const lines = text.split("\n");
  const head = diff.new_file ? `<div class="diff-note">new file</div>` : "";
  const numbers = diffLineNumbers(lines);
  const shown = `<pre class="diff"><code>${linesHtml(lines.slice(0, fold), numbers.slice(0, fold))}</code></pre>`;
  if (lines.length <= fold) return head + shown;
  // The rest opens under the first lines; the toggle hides once open (CSS).
  const rest = `<details class="diff-more"><summary>show all ${lines.length} lines</summary>` +
    `<pre class="diff"><code>${linesHtml(lines.slice(fold), numbers.slice(fold))}</code></pre></details>`;
  return head + shown + rest;
}

// A tool row's collapsed diff (closed by default).
export function activityDiffHtml(diff) {
  if (!diff || typeof diff !== "object" || diff.error || diff.skipped) return "";
  return `<details class="activity-diff"><summary>${escapeHtml(diffSummary(diff))}</summary>${diffHtml(diff)}</details>`;
}
