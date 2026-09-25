# Known names

A tool call that comes back as `[tool] Error: denied by guardrail (hook known_names, bundle known-names): "…" in the command is N edit(s) away from the known name "…"` was caught misspelling a protected name (the user's home folder, login, git name, the repo name). Retry the same call with the name the error gives, spelled exactly like that. If the other spelling really is what you meant, say so to the user instead of retrying.
