#!/usr/bin/env bash
set -euo pipefail
helper="$(dirname "$0")/diagnostic-prompts.sh"

for answer in 0 1 2; do
  actual="$(printf '%s\n' "$answer" | bash -c 'source "$1"; capture RESULT "test"; printf "%s" "$RESULT"' _ "$helper" 2>/dev/null)"
  [[ "$actual" == "$answer" ]] || { printf 'FAIL: answer %s was not preserved\n' "$answer"; exit 1; }
done
actual="$(printf '\nx\n1\n' | bash -c 'source "$1"; capture RESULT "test"; printf "%s" "$RESULT"' _ "$helper" 2>/dev/null)"
[[ "$actual" == 1 ]] || { printf 'FAIL: invalid input must retry\n'; exit 1; }
if bash -c 'source "$1"; capture RESULT "test"' _ "$helper" </dev/null 2>/dev/null; then
  printf 'FAIL: EOF must not become an invented observation\n'
  exit 1
fi
printf 'PASS: 0/1/2, invalid-input retry, and EOF\n'
