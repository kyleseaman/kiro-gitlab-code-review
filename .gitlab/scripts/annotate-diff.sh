#!/usr/bin/env bash
# ABOUTME: Annotates unified diffs with absolute line numbers for AI review agents.
# ABOUTME: Part of the GitLab Kiro code review automation suite.
set -euo pipefail

# Transforms:
#   @@ -10,5 +20,7 @@ function foo()
#   +  const x = 1;
# Into:
#   @@ -10,5 +20,7 @@ function foo()
#   +[21]  const x = 1;

INPUT="${1:-/dev/stdin}"
FILE=""
LINE=1

while IFS= read -r line; do
  case "$line" in
    "--- "*)
      printf "%s\n" "$line"
      ;;
    "+++ "*)
      FILE="${line#+++ b/}"
      printf "%s\n" "$line"
      ;;
    "@@"*)
      PREV=$LINE
      LINE=$(printf "%s\n" "$line" | sed -E 's/^@@ -[0-9]+(,[0-9]+)? \+([0-9]+)(,[0-9]+)? @@.*/\2/')
      [[ "$LINE" =~ ^[0-9]+$ ]] || LINE=$PREV
      printf "%s\n" "$line"
      ;;
    "+"*)
      printf "+[%s]%s\n" "$LINE" "${line:1}"
      LINE=$((LINE + 1))
      ;;
    "-"*)
      printf "%s\n" "$line"
      ;;
    " "*)
      LINE=$((LINE + 1))
      printf "%s\n" "$line"
      ;;
    *)
      # Meta-lines (e.g. \ No newline at end of file) — don't increment
      printf "%s\n" "$line"
      ;;
  esac
done < "$INPUT"
