# Source links

A `sources: NAME ref → url, …` line right after an answer is the `source-links` bundle's `after_turn` hook: it found refs (a JIRA ticket, a GitHub issue, …) in the answer you just read and turned them into links. The line is **not part of the conversation** — it is an event, so it is not in the session file and you cannot refer back to it. A UI replays it while the session's worker lives (a page reload keeps it; a stopped worker loses it).

The refs come from the `bundles: source-links:` section of config.yml: each source is a `prefix:` + `base_url:` pair (simple) or a `pattern:` regex + `url:` template (full form), plus an optional `max:` for refs per line. With no sources configured the hook does nothing. A ref already inside a URL is not linked again.
