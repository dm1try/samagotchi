# llama.cpp native `/completion` fixtures

`completion_cached_stream.sse` was recorded with curl on 2026-09-28 from llama.cpp b10819-6a1a922d2
(Ornith-1.5-35B-A3B Q4_K_M): `{"prompt": …, "n_predict": 8, "stream": true, "cache_prompt": true,
"temperature": 0}`, sent twice; this is the second answer, byte for byte, so most of the prompt came
from the prompt cache. Every `data:` event carries `tokens_evaluated` (the whole prompt, 489) and
`tokens_predicted`; only the last one has `timings`, where `prompt_n` is 4 (the uncached part) and
`cache_n` 485. `TokenUsage.from_payload` must read the whole prompt.
