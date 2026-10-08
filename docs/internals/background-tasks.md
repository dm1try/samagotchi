# Background task tools

Samagotchi supports long-running commands in the background through five task tools:

- `task_create`: start a background command and return `task_id` plus `output_path`.
- `task_get`: fetch current task metadata by id.
- `task_list`: list all tasks for the current workspace.
- `task_stop`: stop a running task by id.
- `task_wait`: wait up to 600 seconds by default for a task to finish.

Recommended workflow:

1. Create a task with `task_create`.
2. Use `task_wait` once. On timeout it returns the last 10 log lines, avoiding a separate read just to see progress.
3. For commands with a reliable completion marker, pass `done_pattern` to return when the recent log tail matches it.
4. Use `task_get` or `task_list` for nonblocking status checks, and `task_stop` if needed.

Behavior:

- `execute`, `task_create` and the `!cmd` shell bang run the command in a non-login shell: `/bin/sh -c` on Linux; on macOS, when `/bin/zsh` is there, `/bin/zsh --emulate sh +o ignore_braces +o sh_glob -o bash_rematch +o bsd_echo -c` (macOS's `/bin/sh` is bash 3.2, which can't parse an apostrophe in a heredoc inside `"$( )"`, the usual commit message shape). That mode reads no rc files and keeps POSIX word splitting, unmatched globs left as is, `{1..3}`, `[[ … =~ (…) ]]` with `BASH_REMATCH`, arrays, `$'…'`, `&>` and echo expanding `\t`. Bash-only builtins and variables (`shopt`, `BASH_VERSION`, `${!prefix*}`, `read -p`) are not there.
- Task metadata and output are persisted under `tmp/tasks/`.
- A task record keeps its process's pid and start time (`pid_started`). Before `task_stop` signals, the pid must still lead its own process group and have started at that time; otherwise the pid was reused by another process, nothing is signalled and the task ends as failed. A record without `pid_started` (from an older chi) is checked by its group only.
- Task listing is workspace-scoped (current project only).
- `task_get` returns metadata and `output_path`; use `read` for output contents.
- `task_wait` accepts `timeout`, `tail_lines` (maximum 100), and `done_pattern` (a regular expression string).
- `task_create` accepts `env` as a JSON object string for deterministic overrides such as `PATH`; use an absolute interpreter path when that is simpler. Ruby/Bundler isolation variables remain protected.
- `execute` and `task_create` export chi's own markers into the command, set over the model's `env` (which can't set them: `Error: env key is reserved`): `SAMAGOTCHI_PARENT_SESSION` (the session's id, `chi` without one; a chi started there answers as a parent agent) and `SAMAGOTCHI_SESSION_MODEL` (the resolved ref the session runs on, read at each call so it follows `/model`; unset when unknown). `chi self` reads the latter for its `model` row. A session's worker never inherits them from whoever started it (a `chi send` run by another session's `execute`): its other commands (a user's `!cmd`, an MCP server, a context command) have none.

Work that needs a model, not a shell command, goes to a child chi session instead: `delegate` / `delegate_result` have the same shape (start, then wait) and return only the child's final reply; see [Sessions: Delegating](../sessions.md#delegating).
