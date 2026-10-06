#!/bin/sh
# The e2e suite's gh (env.js puts it on chi web's PATH as `gh`): the
# github-pr bundle's PR data for https://github.com/acme/app/pull/42, no
# network. `gh pr view` (the branch's PR) finds none.
case "$*" in
  *"repos/acme/app/pulls/42/files"*)
    printf '%s\n' '{"filename":"lib/foo.rb","status":"modified","previous_filename":null,"patch":"@@ -20,6 +20,12 @@ class Foo\n   a\n+  b"}'
    ;;
  "api repos/acme/app/pulls/42 "*) echo "e2ehead e2ebase" ;;
  *) exit 1 ;;
esac
