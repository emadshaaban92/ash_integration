#!/usr/bin/env bash
#
# Shared helpers for the Stop quality-gate hooks (lib-checks.sh, example-checks.sh).
#
# The Stop hook fires every time Claude finishes a turn — including pure Q&A or
# "thinking" turns that touch no files. Running the full CI suite (compile,
# credo, sobelow, test) on every one of those is wasteful, so the gates are
# fingerprint-gated: each gate hashes the source files it cares about and skips
# entirely when that hash matches the last run that passed. The fingerprint is
# content-based, so it correctly skips no-op turns yet still fires after a real
# edit (including edits made via Bash, which never reach the format PostToolUse
# hook).
#
# Sourced after REPO_DIR is set. Sets up the toolchain env shared by both gates.

# Make the mise-managed toolchain available in web sessions (see
# session-start.sh); harmless no-ops in a local checkout.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH="${HEX_CACERTS_PATH:-/etc/ssl/certs/ca-certificates.crt}"
export ELIXIR_ERL_OPTIONS="${ELIXIR_ERL_OPTIONS:-+fnu}"

# Where the last-passing fingerprints live (gitignored; see .gitignore).
STATE_DIR="${REPO_DIR}/.claude/hooks/.state"

# fingerprint_library — content hash of the library's source set (everything
# that feeds compile/format/test outside the example app).
fingerprint_library() {
  ( cd "$REPO_DIR" && \
    find . \
      \( -path ./example -o -path ./deps -o -path ./_build -o -path ./.git -o -name node_modules \) -prune -o \
      -type f \( -name '*.ex' -o -name '*.exs' -o -name '*.heex' -o -name mix.lock -o -name .formatter.exs \) -print0 \
  ) | sort -z | xargs -0 sha1sum 2>/dev/null | sha1sum | cut -d' ' -f1
}

# fingerprint_example — content hash of the example app's source set.
fingerprint_example() {
  ( cd "$REPO_DIR/example" && \
    find . \
      \( -path ./deps -o -path ./_build -o -name node_modules \) -prune -o \
      -type f \( -name '*.ex' -o -name '*.exs' -o -name '*.heex' -o -name mix.lock -o -name .formatter.exs \) -print0 \
  ) | sort -z | xargs -0 sha1sum 2>/dev/null | sha1sum | cut -d' ' -f1
}

# gate_unchanged <name> <fingerprint> — true when <fingerprint> matches the value
# stored by the last passing run of gate <name>, i.e. there is nothing to do.
gate_unchanged() {
  local name="$1" fp="$2"
  [ -f "$STATE_DIR/$name" ] && [ "$(cat "$STATE_DIR/$name")" = "$fp" ]
}

# gate_passed <name> <fingerprint> — record <fingerprint> as gate <name>'s last
# passing run so future no-op turns skip it.
gate_passed() {
  local name="$1" fp="$2"
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$fp" > "$STATE_DIR/$name"
}
