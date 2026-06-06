#!/usr/bin/env bash
#
# Stop hook: run the CI-equivalent quality gate before Claude finishes a turn.
#
#   Library (root): mix format --check-formatted
#                   mix compile --warnings-as-errors
#                   mix credo
#                   mix sobelow
#                   mix test
#
#   Example app:    mix format --check-formatted
#                   mix compile --warnings-as-errors
#                   mix test
#
# (The example app has no credo dep and runs Sobelow only via an archive in CI,
# so those two are intentionally library-only here.)
#
# Every check runs even if an earlier one fails, so a single turn surfaces all
# problems at once (mirrors CI's `if: !cancelled()`). On any failure the hook
# exits 2: the collected output goes back to Claude and it keeps working until
# the gate is green. The loop terminates naturally once all checks pass.

set -uo pipefail

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Make the mise-managed toolchain available in web sessions (see
# session-start.sh); harmless no-ops in a local checkout.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/certs/ca-certificates.crt}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

failures=""

# run <label> <dir> <cmd...> — execute a check, capturing output on failure.
run() {
  local label="$1" dir="$2"
  shift 2
  local out
  if ! out="$(cd "$dir" && "$@" 2>&1)"; then
    failures+=$'\n'"### ${label} failed:"$'\n'"${out}"$'\n'
  fi
}

# --- Library (root) ---
run "library: mix format --check-formatted"     "$REPO_DIR" mix format --check-formatted
run "library: mix compile --warnings-as-errors" "$REPO_DIR" mix compile --warnings-as-errors
run "library: mix credo"                        "$REPO_DIR" mix credo
run "library: mix sobelow"                      "$REPO_DIR" mix sobelow
run "library: mix test"                         "$REPO_DIR" mix test

# --- Example app ---
run "example: mix format --check-formatted"     "$REPO_DIR/example" mix format --check-formatted
run "example: mix compile --warnings-as-errors" "$REPO_DIR/example" mix compile --warnings-as-errors
run "example: mix test"                         "$REPO_DIR/example" mix test

if [ -n "$failures" ]; then
  echo "Stop gate failed — fix these before finishing (CI-equivalent checks):${failures}" >&2
  exit 2
fi
