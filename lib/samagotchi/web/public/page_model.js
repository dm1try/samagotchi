// What a page's header and state lines say, from the page's JSON
// (GET /api/pages/NAME): pure, so the words are testable without a DOM.
// page_view.js draws them. "Changed" is the server's (Pages::Stored#changed?,
// docs/internals/pages.md): the result on screen came from an older script.
import { relativeTime } from "./format.js";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// A run's length: "0.8 s", "12 s"; "" without one.
export function durationText(ms) {
  if (typeof ms !== "number" || !Number.isFinite(ms) || ms < 0) return "";
  return ms < 10_000 ? `${(ms / 1000).toFixed(1)} s` : `${Math.round(ms / 1000)} s`;
}

// The header's meta: "ran 2 min ago · 0.8 s", "never ran"; null for a
// failed run (its line says when the kept result is from).
export function metaText(page, now = Date.now()) {
  if (page.state === "failed") return null;
  if (!page.ran_at) return "never ran";
  const took = durationText(page.duration_ms);
  return took ? `ran ${relativeTime(page.ran_at, now)} · ${took}` : `ran ${relativeTime(page.ran_at, now)}`;
}

// "21 Nov, 14:02", in the viewer's own time zone; "" for no time.
export function resultDate(iso) {
  const t = iso ? Date.parse(iso) : NaN;
  if (Number.isNaN(t)) return "";
  const d = new Date(t);
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getDate()} ${MONTHS[d.getMonth()]}, ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// The failed-run line in three parts, the message drawn as code between
// them: {lead: "The script failed at line 9: ", message, tail: " Showing the
// result from 21 Nov, 14:02."}; the tail is "" with no earlier result.
// null when the last run didn't fail.
export function failureParts(page) {
  const error = page.state === "failed" ? page.error : null;
  if (!error) return null;
  const lead = Number.isInteger(error.line) ? `The script failed at line ${error.line}: ` : "The script failed: ";
  const tail = page.ran_at ? ` Showing the result from ${resultDate(page.ran_at)}.` : "";
  return { lead, message: String(error.message ?? ""), tail };
}

// The changed line (Scene 4), or null: shown when the result came from an
// older script, unless the last run failed on the script as it is now
// (then the failure line says enough).
export function changedText(page, now = Date.now()) {
  if (!page.changed || !page.ran_at) return null;
  if (page.state === "failed" && !page.changed_after_failure) return null;
  const when = page.script_changed_at ? ` ${relativeTime(page.script_changed_at, now)}` : "";
  return `The script changed${when}. This is the result of the earlier version; Refresh runs the new one.`;
}

// What Copy the error copies: "line 9: message", then the script's last
// words when the run's answer carried them.
export function errorCopy(page, stderr = "") {
  const error = page.error;
  if (!error) return "";
  const head = Number.isInteger(error.line) ? `line ${error.line}: ${error.message}` : String(error.message);
  return stderr ? `${head}\n\n${stderr.trimEnd()}` : head;
}

// Whether the blocks on screen are a kept result under a failure (dimmed).
export function keptAfterFailure(page) {
  return page.state === "failed" && !!page.ran_at;
}
