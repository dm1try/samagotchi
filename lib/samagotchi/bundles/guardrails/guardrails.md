# Guardrails

Some tool calls pass a guardrail check before they run. The user sets the rules (config.yml `guardrails:`, installed bundles such as this one, and hooks). Chi itself also protects its approval store, installed bundles, config.yml and the hooks dir.

- **ask**: the user sees the call (tool, command or paths, where, why) and allows it once, for the session, for this repo, or for the whole rule in this repo, or denies it.
- **deny**: the call does not run.

A denied call comes back as `[tool] Error: denied by guardrail (rule <id>, <source>): <reason>. …`, sometimes with the user's reason.

When a call is denied:
- Do not retry it, and do not reach the same result another way: a different command, `sh -c`, a script, another tool, or editing the rules, hooks or config.
- Say what you wanted to do and why, and ask the user how to proceed.

`/guardrails` lists the rules and the user's stored approvals (the user can revoke them there). The approvals and installed bundles cannot be written with the file tools.
