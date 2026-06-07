#!/usr/bin/env bash
#
# Stop hook (example app): CI-equivalent quality gate for the example/ host app.
#
#   mix format --check-formatted
#   mix compile --warnings-as-errors
#   mix test
#
# The example app's tests exercise library code paths that can only be tested
# inside a real host app (router, endpoint, auth, etc.), so a *library* change
# can break them just as an example/ change can. The gate is therefore
# fingerprint-gated on BOTH the library and example source sets (see
# _common.sh): it skips only when neither has changed since the last passing
# run, so pure Q&A / "thinking" turns don't trigger the suite.
#
# (credo and sobelow are library-only: the example app has no credo dep and CI
# runs Sobelow against it only via an archive.)
#
# Registered as its own Stop hook entry so it runs in parallel with the
# library's gate (lib-checks.sh). Every check runs even if an earlier one fails.
# On any failure the hook exits 2 so Claude keeps working until the gate is
# green; the loop terminates naturally once all checks pass.

set -uo pipefail

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
EXAMPLE_DIR="$REPO_DIR/example"

# Fail open: if the shared helper is missing, let the turn finish rather than
# hard-erroring under `set -u`.
COMMON="$REPO_DIR/.claude/hooks/_common.sh"
[ -f "$COMMON" ] || exit 0
source "$COMMON"

# A library change can break the host app, so this gate fires on either set
# changing. Combine both fingerprints into one trigger value.
fp="$(printf '%s\n%s\n' "$(fingerprint_library)" "$(fingerprint_example)" | sha1sum | cut -d' ' -f1)"
gate_unchanged example "$fp" && exit 0

failures=""

# run <label> <cmd...> — execute a check in the example app, capturing output.
run() {
  local label="$1"
  shift
  local out
  if ! out="$(cd "$EXAMPLE_DIR" && "$@" 2>&1)"; then
    failures+=$'\n'"### ${label} failed:"$'\n'"${out}"$'\n'
  fi
}

run "example: mix format --check-formatted"     mix format --check-formatted
run "example: mix compile --warnings-as-errors" mix compile --warnings-as-errors
run "example: mix test"                          mix test

if [ -n "$failures" ]; then
  echo "Example stop gate failed — fix these before finishing:${failures}" >&2
  exit 2
fi

# All green — remember this fingerprint so unchanged turns skip the gate.
gate_passed example "$fp"
