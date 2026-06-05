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
mix deps.get
mix compile

log "Setting up example app (deps, database, assets, seeds)..."
cd "$REPO_DIR/example"
mix setup

log "Done. Run the example with: cd example && mix phx.server  (http://localhost:4000)"
