#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PG_BUILD_DIR:-"$ROOT_DIR/build/local"}"
PREFIX="${PG_PREFIX:-"$ROOT_DIR/.local/pgsql"}"
DATA_DIR="${PG_DATA_DIR:-"$ROOT_DIR/.local/data"}"
LOG_FILE="${PG_LOG_FILE:-"$ROOT_DIR/.local/postgres.log"}"
DB_NAME="${PGDATABASE:-bench}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
CFLAGS="${CFLAGS:--O2 -g}"

INSTALL_DEPS=0
RECONFIGURE=0
RUN_CHECK=0
CLEAN=0
INITDB=0
START_SERVER=0
STOP_SERVER=0
CREATE_DB=0
RUN_SQL=""

usage() {
  cat <<'EOF'
Usage: ./rebuild-postgres.sh [options]

Build and install PostgreSQL from this source tree into a local prefix.

Options:
  --install-deps   Install Ubuntu/Debian build prerequisites with apt-get.
  --reconfigure    Rerun configure even if the build directory already exists.
  --clean          Run make clean before building.
  --check          Run make check after building and before installing.
  --initdb         Initialize the local data directory if it does not exist.
  --start          Start the local PostgreSQL server.
  --stop           Stop the local PostgreSQL server.
  --createdb       Create the benchmark database if it does not exist.
  --run-sql FILE   Run FILE against the benchmark database with psql.
  -h, --help       Show this help.

Environment:
  PG_BUILD_DIR     Build directory. Default: ./build/local
  PG_PREFIX        Install prefix. Default: ./.local/pgsql
  PG_DATA_DIR      Data directory. Default: ./.local/data
  PG_LOG_FILE      Server log file. Default: ./.local/postgres.log
  PGDATABASE       Database used by --createdb and --run-sql. Default: bench
  JOBS             Parallel make jobs. Default: nproc
  CFLAGS           Compiler flags. Default: -O2 -g
  CONFIGURE_FLAGS  Extra flags passed to configure.

Examples:
  ./rebuild-postgres.sh --install-deps
  ./rebuild-postgres.sh
  ./rebuild-postgres.sh --initdb --start --createdb
  ./rebuild-postgres.sh --run-sql bench_hash_join.sql
  CFLAGS="-O3 -g" ./rebuild-postgres.sh --reconfigure

PostgreSQL is a client/server database. Unlike DuckDB, psql does not run
queries by itself; it connects to a running postgres server process.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-deps)
      INSTALL_DEPS=1
      ;;
    --reconfigure)
      RECONFIGURE=1
      ;;
    --clean)
      CLEAN=1
      ;;
    --check)
      RUN_CHECK=1
      ;;
    --initdb)
      INITDB=1
      ;;
    --start)
      START_SERVER=1
      ;;
    --stop)
      STOP_SERVER=1
      ;;
    --createdb)
      CREATE_DB=1
      ;;
    --run-sql)
      if [[ $# -lt 2 ]]; then
        echo "--run-sql requires a SQL file path" >&2
        exit 2
      fi
      RUN_SQL="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

install_deps() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get was not found. Install the PostgreSQL build prerequisites manually." >&2
    exit 1
  fi

  local sudo_cmd=()
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    sudo_cmd=(sudo)
  fi

  "${sudo_cmd[@]}" apt-get update
  "${sudo_cmd[@]}" apt-get install -y \
    build-essential \
    flex \
    bison \
    libreadline-dev \
    zlib1g-dev \
    libicu-dev \
    pkg-config
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    echo "On Ubuntu/Debian, rerun: ./rebuild-postgres.sh --install-deps" >&2
    exit 1
  fi
}

server_is_running() {
  "$PREFIX/bin/pg_ctl" -D "$DATA_DIR" status >/dev/null 2>&1
}

initdb_if_needed() {
  if [[ -s "$DATA_DIR/PG_VERSION" ]]; then
    echo "PostgreSQL data directory already exists: $DATA_DIR"
    return
  fi

  mkdir -p "$(dirname "$DATA_DIR")"
  "$PREFIX/bin/initdb" -D "$DATA_DIR"
}

start_server() {
  if [[ ! -s "$DATA_DIR/PG_VERSION" ]]; then
    echo "Data directory does not exist: $DATA_DIR" >&2
    echo "Run: ./rebuild-postgres.sh --initdb --start" >&2
    exit 1
  fi

  if server_is_running; then
    echo "PostgreSQL server is already running for: $DATA_DIR"
    return
  fi

  "$PREFIX/bin/pg_ctl" -D "$DATA_DIR" -l "$LOG_FILE" start
}

stop_server() {
  if [[ ! -s "$DATA_DIR/PG_VERSION" ]]; then
    echo "PostgreSQL data directory does not exist, nothing to stop: $DATA_DIR"
    return
  fi

  if ! server_is_running; then
    echo "PostgreSQL server is not running for: $DATA_DIR"
    return
  fi

  "$PREFIX/bin/pg_ctl" -D "$DATA_DIR" stop
}

create_database_if_needed() {
  if ! server_is_running; then
    echo "PostgreSQL server is not running." >&2
    echo "Run: ./rebuild-postgres.sh --start --createdb" >&2
    exit 1
  fi

  if "$PREFIX/bin/psql" -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -qx 1; then
    echo "Database already exists: $DB_NAME"
    return
  fi

  "$PREFIX/bin/createdb" "$DB_NAME"
}

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  install_deps
fi

for command_name in gcc make flex bison perl pkg-config; do
  require_command "$command_name"
done

mkdir -p "$BUILD_DIR" "$PREFIX"

if [[ "$STOP_SERVER" -eq 1 ]]; then
  stop_server
fi

configure_args=("--prefix=$PREFIX")
if [[ -n "${CONFIGURE_FLAGS:-}" ]]; then
  # Intentional word splitting lets callers pass normal configure flag strings.
  # shellcheck disable=SC2206
  extra_configure_args=($CONFIGURE_FLAGS)
  configure_args+=("${extra_configure_args[@]}")
fi

if [[ "$RECONFIGURE" -eq 1 || ! -x "$BUILD_DIR/config.status" ]]; then
  (
    cd "$BUILD_DIR"
    "$ROOT_DIR/configure" "${configure_args[@]}" CFLAGS="$CFLAGS"
  )
fi

if [[ "$CLEAN" -eq 1 ]]; then
  make -C "$BUILD_DIR" clean
fi

make -C "$BUILD_DIR" -j"$JOBS"

if [[ "$RUN_CHECK" -eq 1 ]]; then
  make -C "$BUILD_DIR" check
fi

make -C "$BUILD_DIR" install

if [[ "$INITDB" -eq 1 ]]; then
  initdb_if_needed
fi

if [[ "$START_SERVER" -eq 1 ]]; then
  start_server
fi

if [[ "$CREATE_DB" -eq 1 ]]; then
  create_database_if_needed
fi

if [[ -n "$RUN_SQL" ]]; then
  if ! server_is_running; then
    echo "PostgreSQL server is not running." >&2
    echo "Run: ./rebuild-postgres.sh --start --run-sql $RUN_SQL" >&2
    exit 1
  fi

  "$PREFIX/bin/psql" "$DB_NAME" -f "$RUN_SQL"
fi

cat <<EOF

PostgreSQL installed to:
  $PREFIX

Use this build in your shell:
  export PATH="$PREFIX/bin:\$PATH"

Initialize a local data directory if needed:
  "$PREFIX/bin/initdb" -D "$DATA_DIR"

Start it:
  "$PREFIX/bin/pg_ctl" -D "$DATA_DIR" -l "$LOG_FILE" start

Create the benchmark database:
  "$PREFIX/bin/createdb" "$DB_NAME"

Run a SQL file:
  "$PREFIX/bin/psql" "$DB_NAME" -f "$ROOT_DIR/bench_hash_join.sql"

One-command fresh clone setup:
  ./rebuild-postgres.sh --install-deps --initdb --start --createdb --run-sql bench_hash_join.sql
EOF
