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
# Registered as its own Stop hook entry so it runs in parallel with the example
# app's gate (example-checks.sh). Every check runs even if an earlier one fails,
# so a single turn surfaces every problem. On any failure the hook exits 2: the
# collected output goes back to Claude and it keeps working until the gate is
# green. The loop terminates naturally once all checks pass.

set -uo pipefail

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Make the mise-managed toolchain available in web sessions (see
# session-start.sh); harmless no-ops in a local checkout.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/certs/ca-certificates.crt}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

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
