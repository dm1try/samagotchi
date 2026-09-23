# OpenAI-compatible provider fixtures

Recorded from llama.cpp b10819 (`/v1`, Ornith-1.5) by `script/record_provider_fixtures.rb`;
re-run it to refresh them. `*.sse` are streamed bodies byte for byte, `*.json` plain bodies
with the HTTP status in the sibling `*.status`.

Files named `*.hand-written.*` are not recorded (a local server can't produce them):
401/429/500 bodies in the usual OpenAI shape, a stream whose second `data:` line is
broken JSON, and llama.cpp's mid-stream `error:` event.
