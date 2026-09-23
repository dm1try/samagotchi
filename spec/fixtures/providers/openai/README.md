# OpenAI-compatible provider fixtures

Recorded from llama.cpp b10819 (`/v1`, Ornith-1.5) by `script/record_provider_fixtures.rb`;
re-run it to refresh them. `*.sse` are streamed bodies byte for byte, `*.json` plain bodies
with the HTTP status in the sibling `*.status`.

Files named `*.hand-written.*` are not recorded (a local server can't produce them):
401/429/500 bodies in the usual OpenAI shape, a stream whose second `data:` line is
broken JSON, and llama.cpp's mid-stream `error:` event.

llama.cpp's mid-stream `error:` event stays hand-written: on 2026-09-23, b10819 could not be made to send one.
A streamed prompt longer than the window is refused before the stream starts (HTTP 400, the shape of
`error_400.json`, on both `/completion` and `/v1/chat/completions`). A prompt that fits but runs out of
room while generating (127,961 prompt tokens, `n_predict: 200`) ends normally, with
`"truncated":true,"stop_type":"limit"` in the last `data:` event, not an error. While the prompt is
processed, the server sends bare `:` keep-alive comment lines.

`openrouter_*` files come from OpenRouter (https://openrouter.ai/api/v1), not llama.cpp.
`openrouter_error_429.json` was recorded with curl on 2026-09-23 (`z-ai/glm-5.2:free`, which
answered with a `Retry-After: 5` header); only `user_id` is redacted.
`openrouter_error_404_no_tools.json` was recorded with curl on 2026-09-23: `z-ai/glm-5.2:free` with one
tool in the request, when none of the model's endpoints takes tools (nothing redacted).
`openrouter_stream_error_503.hand-written.sse` has the shape OpenRouter uses for an upstream
failure after it has answered 200: a `: OPENROUTER PROCESSING` comment, then a `data:` event
with empty `choices` and an `error` object. It was seen in a smoke run on 2026-09-23 but not
saved, and it couldn't be triggered on demand, so the error text is made up.
