// A test history as chi web's show sends it since every finished turn is
// drawn (H3 P5): each turn's items stamped (drawn: <id>) and its drawing in
// `drawings` ({id: {events, end}}), for turnHistoryNodes / turnGroups.
//
// The turns are cut as the items show them: an opening (a prompt, a wake's
// note) starts one; steps, merged lines, steers and the empty answer stay
// in it; a loose context note or a `!cmd`'s record stays apart (unstamped).
// Each turn's drawing is a minimal one: its start, one generation per
// assistant item (its text, its parts' thinking and calls: each call's
// fields on its start, its output and status on its end; the parts leave the
// items as the show's do), its merged lines and steers where they came,
// and a completed end naming the turn (+ends+, by id, replaces it). A
// turn with no turn id gets a made-up one (m<index>) that its end doesn't
// name, as chi web's made lines do. Not chi web's synthesizer: the Ruby
// specs and the parity test pin what a real drawing holds.
import { isShellCommandItem } from "../../../lib/samagotchi/web/public/shell_command.js";

const opens = (item) => (item?.role === "user" && !item.merged && !isShellCommandItem(item))
  || (item?.role === "note" && item.turn_start === true);

export function drawnHistory(source, { ends = {} } = {}) {
  const items = [];
  const drawings = {};
  let turn = null;
  source.forEach((item, i) => {
    if ((item?.role === "note" && !item.turn_start) || isShellCommandItem(item)) {
      items.push(item);
      if (isShellCommandItem(item)) turn = null;
      return;
    }
    if (opens(item) || !turn) {
      const id = item.turn_id || `m${i}`;
      turn = { id, iteration: 0, events: [{ type: "turn_started", prompt: opens(item) ? item.content : null, turn_id: id }] };
      drawings[id] = { events: turn.events, end: ends[id] || { type: "turn_completed", ...(item.turn_id ? { turn_id: id } : {}) } };
    }
    const { parts, ...shown } = item;
    items.push({ ...shown, drawn: turn.id });
    if (item.role === "assistant") {
      turn.iteration += 1;
      const n = turn.iteration;
      turn.events.push({ type: "generation_started", iteration: n },
        { type: "generation_chunk", iteration: n, text: String(item.content ?? ""), thinking: parts?.thinking || "" });
      (parts?.tools || []).forEach((call, k) => {
        const { output, status = "ok", ...fields } = call;
        const key = { iteration: n, call_index: k + 1, tool: call.tool, tool_id: call.tool_id || `${turn.id}:${n}:${k + 1}` };
        turn.events.push({ type: "tool_call_started", ...fields, ...key },
          { type: "tool_call_completed", ...key, ...(fields.label ? { label: fields.label } : {}), output, activity: { status } });
      });
    } else if (item.role === "user" && item.merged) {
      turn.events.push({ type: "merged_input" });
    } else if (item.role === "steer") {
      turn.events.push({ type: "pending_input_merged", steers: [{ source: item.source, text: item.content }] });
    }
  });
  return { items, drawings };
}
