#!/usr/bin/env bash
#
# SessionStart hook for Claude Code on the web.
#
# The cloud Setup script installs the mise-managed toolchain (Erlang/OTP,
# Elixir, hex, rebar) and provisions the PostgreSQL 18 cluster. This hook does
# the per-session work that isn't snapshotted: activate the toolchain, start
# PostgreSQL, prepare the database, and build the library + example app.

set -euo pipefail

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

log() { echo "[session-start] $*"; }

REPO_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$REPO_DIR"

# mise-managed toolchain on PATH.
#   HEX_CACERTS_PATH: the egress gateway terminates TLS with its own CA and Hex
#     ignores SSL_CERT_FILE, so point it at the system trust store or deps.get
#     fails unknown_ca.
#   ELIXIR_ERL_OPTIONS=+fnu: the container locale is C; force UTF-8 filename
#     handling or the BEAM warns it may malfunction.
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH="/etc/ssl/certs/ca-certificates.crt"
export ELIXIR_ERL_OPTIONS="+fnu"

mise trust "$REPO_DIR"
mise install

# Bridge the toolchain (PATH, MIX_HOME) + Hex/BEAM env into the agent session.
{
  mise env -s bash
  echo "export HEX_CACERTS_PATH=\"$HEX_CACERTS_PATH\""
  echo "export ELIXIR_ERL_OPTIONS=\"$ELIXIR_ERL_OPTIONS\""
} >> "$CLAUDE_ENV_FILE"

# Route git dependency fetches (e.g. the heroicons git dep in example/) through
# the MAIN HTTPS proxy.
#
# The example app pulls heroicons straight from github.com as a git dep:
#   {:heroicons, github: "tailwindlabs/heroicons", ...}
# The session normally rewrites github.com to a git-specific proxy (injected
# into git config as url.<...:port/git/>.insteadOf=https://github.com/), but that
# proxy's egress policy only allows the in-scope repo and answers 403 for any
# third-party repo like tailwindlabs/heroicons — so `mix deps.get` fails to
# fetch the git dep on a fresh clone. The main HTTPS proxy ($HTTPS_PROXY, with
# the proxy CA at /root/.ccr/ca-bundle.crt) *does* allow it, so point git at the
# main proxy for github.com and drop every injected insteadOf rewrite for the
# duration of the fetch.
GIT_DEP_CONFIG="$(mktemp)"
trap 'rm -f "$GIT_DEP_CONFIG"' EXIT
cat > "$GIT_DEP_CONFIG" <<GITCFG
[http "https://github.com/"]
	proxy = ${HTTPS_PROXY:-http://127.0.0.1:36065}
	sslCAInfo = /root/.ccr/ca-bundle.crt
GITCFG

# with_git_main_proxy <cmd...> — run <cmd> with git seeing only the clean config
# above (no system/global file, no GIT_CONFIG_* env injection), so github.com
# resolves through the main proxy with no competing insteadOf rewrite. Scoped to
# a subshell so the session's normal git routing is untouched afterwards.
with_git_main_proxy() {
  (
    if [ "${GIT_CONFIG_COUNT:-0}" -gt 0 ]; then
      for i in $(seq 0 $(( GIT_CONFIG_COUNT - 1 ))); do
        unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i"
      done
    fi
    unset GIT_CONFIG_COUNT
    export GIT_CONFIG_GLOBAL="$GIT_DEP_CONFIG" GIT_CONFIG_SYSTEM=/dev/null
    "$@"
  )
}

# Run psql as the postgres OS user (cd /tmp so it can getcwd).
run_as_postgres() { ( cd /tmp && runuser -u postgres -- "$@" ); }

log "Starting PostgreSQL..."
service postgresql start
for _ in $(seq 1 30); do
  run_as_postgres pg_isready -q && break
  sleep 1
done

# admin/admin superuser matching example/config/{dev,test}.exs.
run_as_postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='admin'" | grep -q 1 || \
  run_as_postgres psql -c "CREATE ROLE admin WITH LOGIN SUPERUSER CREATEDB PASSWORD 'admin';"

# The app configs use hostname "db"; map it to localhost.
grep -qE '(^|[[:space:]])db([[:space:]]|$)' /etc/hosts || echo "127.0.0.1 db" >> /etc/hosts

log "Fetching + compiling library deps..."
with_git_main_proxy mix deps.get
mix compile

log "Setting up example app (deps, database, assets, seeds)..."
cd "$REPO_DIR/example"
# Warm the git deps (heroicons) through the main proxy first; the deps.get inside
# `mix setup` then sees them already cloned and does no further github fetch.
with_git_main_proxy mix deps.get
mix setup

log "Done. Run the example with: cd example && mix phx.server  (http://localhost:4000)"
