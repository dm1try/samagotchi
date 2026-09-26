# gh helper

Needs the `gh` command (GitHub CLI), logged in. If `gh` is missing or not
logged in (a "command not found" or an auth error), tell the user and stop;
don't try to scrape github.com instead.

- List open PRs: `gh pr list --state open`
- CI status of a PR: `gh pr checks <number>`
