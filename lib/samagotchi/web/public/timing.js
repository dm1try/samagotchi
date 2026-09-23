export function formatDuration(milliseconds) {
  const ms = Number(milliseconds);
  if (!Number.isFinite(ms) || ms < 0) return "";

  if (ms < 500) return `${Math.round(ms)}ms`;

  const seconds = ms / 1000;
  if (seconds < 60) return `${seconds < 10 ? seconds.toFixed(1) : Math.round(seconds)}s`;

  const totalSeconds = Math.round(seconds);
  const minutes = Math.floor(totalSeconds / 60);
  return `${minutes}m ${String(totalSeconds % 60).padStart(2, "0")}s`;
}

export function elapsedSince(startedAt, now = Date.now()) {
  const started = Date.parse(startedAt);
  const current = Number(now);
  if (!Number.isFinite(started) || !Number.isFinite(current)) return null;
  return Math.max(0, current - started);
}

export function normalizeTiming(data = {}) {
  return {
    startedAt: typeof data.started_at === "string" ? data.started_at : null,
    sessionDurationMs: finiteOrNull(data.session_duration_ms),
    turnRecords: Array.isArray(data.turn_records) ? data.turn_records.filter(validRecord) : [],
    toolRecords: Array.isArray(data.tool_records) ? data.tool_records.filter(validRecord) : [],
    activeTurn: validRecord(data.active_turn) ? data.active_turn : null,
  };
}

export function turnRecordAt(timing, index) {
  const records = timing?.turnRecords;
  return Array.isArray(records) ? records[index] || null : null;
}

// For each history item, the turn index its timing shows under, or null. A
// turn with tool calls holds several assistant messages; only the last one
// before the next user message carries the turn's timing.
export function timedTurnIndexes(items) {
  const result = items.map(() => null);
  let turnIndex = -1;
  let lastAssistant = null;
  items.forEach((item, i) => {
    if (item?.role === "user") {
      if (lastAssistant !== null) result[lastAssistant] = turnIndex;
      turnIndex += 1;
      lastAssistant = null;
    } else if (item?.role === "assistant") {
      lastAssistant = i;
    }
  });
  if (lastAssistant !== null) result[lastAssistant] = turnIndex;
  return result;
}

// Append +el+ to the history, above +timingEl+ while it is a running turn's
// live timing line, so that line stays under the turn's activity, thinking
// and answer.
export function appendAboveLiveTiming(parent, el, timingEl) {
  if (timingEl && timingEl.parentNode === parent && timingEl.classList.contains("live")) {
    parent.insertBefore(el, timingEl);
  } else {
    parent.appendChild(el);
  }
}

function validRecord(record) {
  return record && typeof record === "object";
}

function finiteOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) && number >= 0 ? number : null;
}
