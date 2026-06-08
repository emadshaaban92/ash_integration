#!/usr/bin/env bash
#
# Stop hook (library / root): CI-equivalent quality gate for the library.
#
#   mix format --check-formatted
#   mix compile --warnings-as-errors
#   mix credo
#   mix sobelow
#   mix test
#
# Fingerprint-gated (see _common.sh): if no library source file has changed
# since the last passing run, the gate skips entirely — so pure Q&A / "thinking"
# turns don't trigger the suite. Only a real change to library sources re-runs it.
#
# Registered as its own Stop hook entry so it runs in parallel with the example
# app's gate (example-checks.sh). Every check runs even if an earlier one fails,
# so a single turn surfaces every problem. On any failure the hook exits 2: the
# collected output goes back to Claude and it keeps working until the gate is
# green. The loop terminates naturally once all checks pass.

set -uo pipefail

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Fail open: if the shared helper is missing, let the turn finish rather than
# hard-erroring under `set -u`.
COMMON="$REPO_DIR/.claude/hooks/_common.sh"
[ -f "$COMMON" ] || exit 0
source "$COMMON"

# Skip when nothing the library cares about has changed since the last green run.
fp="$(fingerprint_library)"
gate_unchanged library "$fp" && exit 0

failures=""

# run <label> <cmd...> — execute a check in the library root, capturing output.
run() {
  local label="$1"
  shift
  local out
  if ! out="$(cd "$REPO_DIR" && "$@" 2>&1)"; then
    failures+=$'\n'"### ${label} failed:"$'\n'"${out}"$'\n'
  fi
}

run "library: mix format --check-formatted"     mix format --check-formatted
run "library: mix compile --warnings-as-errors" mix compile --warnings-as-errors
run "library: mix credo"                        mix credo
run "library: mix sobelow"                       mix sobelow
run "library: mix test"                          mix test

if [ -n "$failures" ]; then
  echo "Library stop gate failed — fix these before finishing:${failures}" >&2
  exit 2
fi

# All green — remember this fingerprint so unchanged turns skip the gate.
gate_passed library "$fp"
