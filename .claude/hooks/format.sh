#!/usr/bin/env bash
#
# PostToolUse hook: auto-format the file Claude just edited with `mix format`.
#
# Runs after Edit/Write/MultiEdit. It reads the tool call's JSON from stdin,
# pulls out the target file, and (for Elixir / HEEx sources) formats it from the
# owning Mix project so the correct .formatter.exs applies (root library vs.
# example app).

set -euo pipefail

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Make the mise-managed toolchain available in web sessions (see
# session-start.sh); these are harmless no-ops in a local checkout.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/certs/ca-certificates.crt}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

# The edited file, from the hook's JSON payload on stdin.
file="$(jq -r '.tool_input.file_path // empty')"
[ -n "$file" ] || exit 0

# Only format Elixir source and HEEx templates.
case "$file" in
  *.ex|*.exs|*.heex) ;;
  *) exit 0 ;;
esac

[ -f "$file" ] || exit 0

# Format from the owning project root so its .formatter.exs (imports, plugins,
# locals_without_parens) is the one that applies.
case "$file" in
  "$REPO_DIR"/example/*) cd "$REPO_DIR/example" ;;
  *) cd "$REPO_DIR" ;;
esac

mix format "$file"
