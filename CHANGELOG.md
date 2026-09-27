# Changelog

All notable changes to samagotchi (the `chi` command) are listed here. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
versions follow [Semantic Versioning](https://semver.org/); before 1.0, config
and commands may change between minor versions. How releases are made:
[docs/releasing.md](docs/releasing.md).

## [Unreleased]

The first public release. chi is an agent harness for local models
(llama.cpp, mlx-lm, oMLX) and OpenAI-compatible servers, built around memory
and long-lived sessions.

### Added

- One session, three UIs: the terminal REPL, an attached terminal and a web UI
  (`chi web`) join the same session and see the same turn live; a session keeps
  running in a background worker when you detach (`chi --attach ID` comes back).
- Saved sessions (`chi sessions list`, `chi --resume ID`) and a short recap of
  what happened when you come back to one.
- Memory in plain Markdown files, per project and system-wide, with
  model-specific overlays; memory bundles to share and upgrade them
  (`chi bundle install`, `chi bundle list`, `chi bundle upgrade`).
- Plugins (commands, tools, cards, hooks) and an MCP bundle that brings in the
  tools of MCP servers; shipped plugins: `btw` (a side question mid-turn),
  `loop-guard` and `mcp`.
- Guardrails: every tool call can be allowed, denied or asked about first, with
  approvals per session, repo or rule; `chi bundle install guardrails` adds a
  default set.
- `delegate`: the model hands a task to a child session that runs in parallel
  and reports back.
- Images: `@shot.png` in a prompt, or a pasted or dropped image in the web UI,
  for models that can see them.
- `chi note` (background context for a session, no turn) and `chi send` (a
  message into a session, which wakes it if it was stopped).
- A macOS desktop helper (`chi desktop install`): a "Send to chi" Service and a
  hotkey panel that send selected text or the clipboard to your sessions.
