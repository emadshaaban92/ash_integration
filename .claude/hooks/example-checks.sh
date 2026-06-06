#!/usr/bin/env bash
#
# Stop hook (example app): CI-equivalent quality gate for the example/ host app.
#
#   mix format --check-formatted
#   mix compile --warnings-as-errors
#   mix test
#
# The example app's tests exercise library code paths that can only be tested
# inside a real host app (router, endpoint, auth, etc.), so they ALWAYS run —
# they are not gated on whether example/ files changed.
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

# Make the mise-managed toolchain available in web sessions (see
# session-start.sh); harmless no-ops in a local checkout.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/certs/ca-certificates.crt}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

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
