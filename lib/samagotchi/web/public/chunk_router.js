// Pure routing for one :generation_chunk event into the two render lanes.
//
// Phase 2 (web-stream-rendering): the server enriches each :generation_chunk with
// additive `text` (visible prose, thinking + tool_call blocks removed) and
// `thinking` (thinking-only) fields, leaving raw `content` untouched. When those
// fields are present we use them and ignore raw `content`; when absent (a
// pre-Phase-2 server, or a non-splitting profile the server did not enrich) we
// fall back to raw `content` so behavior matches the pre-Phase-2 UI.
//
// Presence is checked with `typeof === "string"` (not truthiness) so an empty
// `text` (e.g. a chunk that is entirely a tool_call body) still selects the new
// wire instead of accidentally falling back to raw `content`.
export function routeChunk(data) {
  data = data || {};
  if (typeof data.text === "string" || typeof data.thinking === "string") {
    return {
      text: typeof data.text === "string" ? data.text : "",
      thinking: typeof data.thinking === "string" ? data.thinking : "",
    };
  }
  return {
    text: typeof data.content === "string" ? data.content : "",
    thinking: "",
  };
}
