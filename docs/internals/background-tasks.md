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

- Task metadata and output are persisted under `tmp/tasks/`.
- Task listing is workspace-scoped (current project only).
- `task_get` returns metadata and `output_path`; use `read` for output contents.
- `task_wait` accepts `timeout`, `tail_lines` (maximum 100), and `done_pattern` (a regular expression string).
- `task_create` accepts `env` as a JSON object string for deterministic overrides such as `PATH`; use an absolute interpreter path when that is simpler. Ruby/Bundler isolation variables remain protected.
