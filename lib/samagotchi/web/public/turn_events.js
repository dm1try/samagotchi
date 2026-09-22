// Pure helpers for the Bridge's turn events (no DOM), so app.js's handlers
// stay thin and the logic runs under `node --test`.

// The answer text of a :turn_completed event. `turn_summary.output` is the
// contract; `result` is the KernelLoop result, which reaches the wire as its
// string form (older servers, other clients' fixtures).
export function turnOutput(data) {
  if (!data) return "";
  const summary = data.turn_summary?.output;
  const result = typeof data.result === "string" ? data.result : data.result?.output;
  const out = [summary, result, data.content, data.output].find((v) => typeof v === "string" && v.trim());
  return out ? out.trim() : "";
}
