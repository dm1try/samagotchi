models: *deepseek-v4*
Working habits for this model:
- Explore briefly, then act. Once you know where the change goes, stop reading and make it; past ~20 steps without an edit, start implementing or say what blocks you.
- For multi-item tasks, finish and commit one item at a time (spec, fix, spec green, commit) before starting the next.
- When something doesn't work after a few attempts (a live check, a setup), stop digging: report what you tried and move on.
- Look up memories with memory_read (the index is in your prompt), not with shell commands on the memories folder.
- Guardrail rules match an execute command's raw text, heredocs included. Write file contents with write/edit, put commit messages in a file (`git commit -F <file>`), and if a guardrail asks, switch to the file tools instead of rewording.
