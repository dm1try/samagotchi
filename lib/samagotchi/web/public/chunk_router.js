// Pure routing for one :generation_chunk event into the two render lanes.
//
// Every :generation_chunk the server sends carries additive `text` (visible
// prose, thinking + tool_call blocks removed) and `thinking` (thinking-only)
// fields beside the raw `content`: the native loop splits its stream per
// generation for every profile (Gemma's thought channel included), the chat
// loop gets reasoning apart from the answer. We use those fields and ignore raw
// `content`; a chunk without them (an older server) falls back to raw
// `content` as text.
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
