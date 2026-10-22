#!/bin/sh
# The e2e suite's gh (env.js puts it on chi web's PATH as `gh`): the
# github-pr bundle's PR data for https://github.com/acme/app/pull/42, no
# network. `gh pr view` (the branch's PR) finds none. Once the PR's files
# are served it leaves gh_files_served beside itself: a script's
# "hold_until" (fake_openai.py) waits for it, so an answer comes after the
# fetch however loaded the machine is.
case "$*" in
  *"repos/acme/app/pulls/42/files"*)
    printf '%s\n' '{"filename":"lib/foo.rb","status":"modified","previous_filename":null,"patch":"@@ -20,6 +20,12 @@ class Foo\n   a\n+  b"}'
    : > "$(dirname "$0")/gh_files_served"
    ;;
  "api repos/acme/app/pulls/42 "*) echo "e2ehead e2ebase" ;;
  *) exit 1 ;;
esac
