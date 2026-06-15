#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${PG_BUILD_DIR:-"$ROOT_DIR/build/local"}"
PREFIX="${PG_PREFIX:-"$ROOT_DIR/.local/pgsql"}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
CFLAGS="${CFLAGS:--O2 -g}"

INSTALL_DEPS=0
RECONFIGURE=0
RUN_CHECK=0
CLEAN=0

usage() {
  cat <<'EOF'
Usage: ./rebuild-postgres.sh [options]

Build and install PostgreSQL from this source tree into a local prefix.

Options:
  --install-deps   Install Ubuntu/Debian build prerequisites with apt-get.
  --reconfigure    Rerun configure even if the build directory already exists.
  --clean          Run make clean before building.
  --check          Run make check after building and before installing.
  -h, --help       Show this help.

Environment:
  PG_BUILD_DIR     Build directory. Default: ./build/local
  PG_PREFIX        Install prefix. Default: ./.local/pgsql
  JOBS             Parallel make jobs. Default: nproc
  CFLAGS           Compiler flags. Default: -O2 -g
  CONFIGURE_FLAGS  Extra flags passed to configure.

Examples:
  ./rebuild-postgres.sh --install-deps
  ./rebuild-postgres.sh
  CFLAGS="-O3 -g" ./rebuild-postgres.sh --reconfigure
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

if [[ "$INSTALL_DEPS" -eq 1 ]]; then
  install_deps
fi

for command_name in gcc make flex bison perl pkg-config; do
  require_command "$command_name"
done

mkdir -p "$BUILD_DIR" "$PREFIX"

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

cat <<EOF

PostgreSQL installed to:
  $PREFIX

Use this build in your shell:
  export PATH="$PREFIX/bin:\$PATH"

Initialize a local data directory if needed:
  "$PREFIX/bin/initdb" -D "$ROOT_DIR/.local/data"

Start it:
  "$PREFIX/bin/pg_ctl" -D "$ROOT_DIR/.local/data" -l "$ROOT_DIR/.local/postgres.log" start
EOF
