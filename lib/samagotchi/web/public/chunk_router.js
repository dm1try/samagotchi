// Pure routing for one :generation_chunk event into the two render lanes.
//
// Every :generation_chunk the server sends carries `text` (visible prose,
// thinking + tool_call blocks removed) and `thinking` (thinking-only): the
// native loop splits its stream per generation for every profile (Gemma's
// thought channel included), the chat loop gets reasoning apart from the
// answer. The raw stream text and the provider's payload stay in the worker
// (Bridge::ClientEvent); a missing or non-string field is an empty lane.
export function routeChunk(data) {
  data = data || {};
  return {
    text: typeof data.text === "string" ? data.text : "",
    thinking: typeof data.thinking === "string" ? data.thinking : "",
  };
}
