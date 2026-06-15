#!/usr/bin/env bash
# Run the Hugo-generated hash-join benchmark against the local PostgreSQL build.
#
# This is a PostgreSQL port of the DuckDB driver in /mnt/local_ssd/spy.  The
# main workflow is the same, but data is loaded into a PostgreSQL database and
# queries are executed through psql against a running postgres server.
set -euo pipefail

COLD=10
LAYOUT=interleaved
MULT=""
CASE=""
CASES_LIST=""
RUNS=1
SEED=""
SEEDS_COUNT=""
CSV_PATH=""
GENERATE=false
USE_PERF=false
PROFILE=false
DROP_OS_CACHE=false
NO_WARMUP=false
START_SERVER=false

usage() {
	cat <<'USAGE'
Usage: scripts/measure/run_hugo_generated.sh [options]

Options:
  --cold <1|5|10|100>   Cold-to-hot ratio (default: 10)
  --layout <L>          Layout: interleaved, segmented (default: interleaved)
  --mult <int>          Multiplicity suffix (required for interleaved files)
  --case <label>        Case label for output/CSV. 1-4 are accepted as no-op
                        DuckDB compatibility labels; default: pg
  --cases <list>        Comma-separated case labels, e.g. pg or 1,2,3,4
  --runs <N>            Timed query iterations per case/seed tuple (default: 1)
  --no-warmup           Skip the warmup query before timed iterations
  --seed <int>          Seed label for output/CSV. PostgreSQL does not use it
                        for optimizer transfer-graph ordering.
  --seeds <N>           Sweep seed labels 0..N-1
  --csv <path>          Write per-run CSV
  --generate            Drop/recreate the PostgreSQL database and load data
  --profile             Write EXPLAIN ANALYZE output instead of DuckDB JSON
  --perf                Not supported for this port; psql is not the backend
  --drop-os-cache       Run sync + drop Linux page cache before query runs.
                        Note: this does not clear PostgreSQL shared_buffers.
  --start-server        Start the local server before running
  -h, --help            Show this help

Examples:
  scripts/measure/run_hugo_generated.sh --case pg --mult 5 --generate
  scripts/measure/run_hugo_generated.sh --cases pg --mult 5 --runs 3 --csv results.csv
  scripts/measure/run_hugo_generated.sh --cold 10 --layout segmented --mult 1 --generate --profile
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--cold) COLD="$2"; shift 2 ;;
		--layout) LAYOUT="$2"; shift 2 ;;
		--mult) MULT="$2"; shift 2 ;;
		--case) CASE="$2"; shift 2 ;;
		--cases) CASES_LIST="$2"; shift 2 ;;
		--runs) RUNS="$2"; shift 2 ;;
		--seed) SEED="$2"; shift 2 ;;
		--seeds) SEEDS_COUNT="$2"; shift 2 ;;
		--csv) CSV_PATH="$2"; shift 2 ;;
		--generate) GENERATE=true; shift ;;
		--perf) USE_PERF=true; shift ;;
		--profile|--duckdb-profiling) PROFILE=true; shift ;;
		--drop-os-cache) DROP_OS_CACHE=true; shift ;;
		--start-server) START_SERVER=true; shift ;;
		--no-warmup) NO_WARMUP=true; shift ;;
		--debug|--no-taskset)
			echo "Warning: $1 is a DuckDB compatibility option and is ignored by the PostgreSQL port." >&2
			shift
			;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
done

case "$COLD" in
	1|5|10|100) ;;
	*) echo "Error: --cold must be 1, 5, 10, or 100 (got: $COLD)" >&2; exit 1 ;;
esac
case "$LAYOUT" in
	interleaved|segmented) ;;
	*) echo "Error: --layout must be interleaved or segmented (got: $LAYOUT)" >&2; exit 1 ;;
esac
if [[ -z "$MULT" ]]; then
	echo "Error: --mult is required. See --help." >&2
	exit 1
fi
if ! [[ "$MULT" =~ ^[0-9]+$ ]] || [[ "$MULT" -lt 1 ]]; then
	echo "Error: --mult must be a positive integer (got: $MULT)" >&2
	exit 1
fi
if [[ -n "$CASE" && -n "$CASES_LIST" ]]; then
	echo "Error: --case and --cases are mutually exclusive." >&2
	exit 1
fi
if [[ -n "$SEED" && -n "$SEEDS_COUNT" ]]; then
	echo "Error: --seed and --seeds are mutually exclusive." >&2
	exit 1
fi
if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -lt 1 ]]; then
	echo "Error: --runs must be a positive integer" >&2
	exit 1
fi
if $USE_PERF; then
	echo "Error: --perf is not supported in this PostgreSQL port." >&2
	echo "Running perf around psql would measure the client, not the postgres backend process." >&2
	exit 1
fi

CASES=()
if [[ -n "$CASE" ]]; then
	CASES=("$CASE")
elif [[ -n "$CASES_LIST" ]]; then
	IFS=',' read -r -a CASES <<<"$CASES_LIST"
else
	CASES=(pg)
fi

case_settings_for() {
	local case_label="$1"

	case "$case_label" in
		pg|1|2|3|4)
			printf -- '-- case %s: no PostgreSQL-specific optimizer settings\n' "$case_label"
			;;
		*)
			echo "Error: unsupported case label: $case_label" >&2
			exit 1
			;;
	esac
}

SEEDS=()
SWEEPING_SEEDS=false
if [[ -n "$SEEDS_COUNT" ]]; then
	if ! [[ "$SEEDS_COUNT" =~ ^[0-9]+$ ]] || [[ "$SEEDS_COUNT" -lt 1 ]]; then
		echo "Error: --seeds must be a positive integer (got: $SEEDS_COUNT)" >&2
		exit 1
	fi
	for ((i = 0; i < SEEDS_COUNT; i++)); do
		SEEDS+=("$i")
	done
	SWEEPING_SEEDS=true
elif [[ -n "$SEED" ]]; then
	if ! [[ "$SEED" =~ ^[0-9]+$ ]]; then
		echo "Error: --seed must be a non-negative integer (got: $SEED)" >&2
		exit 1
	fi
	SEEDS=("$SEED")
else
	SEEDS=("")
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

PREFIX="${PG_PREFIX:-"$REPO_ROOT/.local/pgsql"}"
DATA_DIR="${PG_DATA_DIR:-"$REPO_ROOT/.local/data"}"
LOG_FILE="${PG_LOG_FILE:-"$REPO_ROOT/.local/postgres.log"}"
PSQL="$PREFIX/bin/psql"
CREATEDB="$PREFIX/bin/createdb"
DROPDB="$PREFIX/bin/dropdb"
PG_CTL="$PREFIX/bin/pg_ctl"

DB_NAME="${COLD}_cold_${LAYOUT}_${MULT}x"
SETUP_SQL="scripts/measure/generation/${DB_NAME}.sql"
SETUP_LABEL="$DB_NAME"
if [[ ! -f "$SETUP_SQL" && "$LAYOUT" == "segmented" ]]; then
	SETUP_LABEL="${COLD}_cold_${LAYOUT}"
	SETUP_SQL="scripts/measure/generation/${SETUP_LABEL}.sql"
fi
COMMON_SETTINGS_SQL="scripts/measure/settings-common.sql"
RUN_SETTINGS_SQL="scripts/measure/settings-run_hugo_generated.sql"
PROFILE_OUT="scripts/measure/${DB_NAME}_explain.txt"

require_file() {
	local path="$1"

	if [[ ! -f "$path" ]]; then
		echo "Error: required file not found: $path" >&2
		exit 1
	fi
}

require_executable() {
	local path="$1"

	if [[ ! -x "$path" ]]; then
		echo "Error: executable not found: $path" >&2
		echo "Build PostgreSQL first, for example: ./rebuild-postgres.sh" >&2
		exit 1
	fi
}

server_is_running() {
	"$PG_CTL" -D "$DATA_DIR" status >/dev/null 2>&1
}

start_server() {
	if [[ ! -s "$DATA_DIR/PG_VERSION" ]]; then
		echo "Error: data directory does not exist: $DATA_DIR" >&2
		echo "Initialize it first: ./rebuild-postgres.sh --initdb --start --createdb" >&2
		exit 1
	fi
	if server_is_running; then
		return
	fi
	"$PG_CTL" -D "$DATA_DIR" -l "$LOG_FILE" start
}

database_exists() {
	"$PSQL" -X -v ON_ERROR_STOP=1 -d postgres -Atqc \
		"SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -qx 1
}

drop_os_page_cache() {
	if ! $DROP_OS_CACHE; then
		return
	fi
	echo "Dropping Linux page cache. PostgreSQL shared_buffers are not cleared." >&2
	sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
}

translate_duckdb_setup_sql() {
	local input_sql="$1"

	python3 - "$input_sql" <<'PY'
import re
import sys
from pathlib import Path

sql = Path(sys.argv[1]).read_text()

def repl(match):
    start = match.group(1).strip()
    stop = match.group(2).strip()
    step = match.group(3)
    if step is None:
        return f"FROM generate_series({start}, ({stop}) - 1) AS range(range)"
    return f"FROM generate_series({start}, ({stop}) - 1, {step.strip()}) AS range(range)"

sql = re.sub(
    r"FROM\s+range\(\s*([^,()]+)\s*,\s*([^,()]+)\s*(?:,\s*([^,()]+)\s*)?\)",
    repl,
    sql,
    flags=re.IGNORECASE,
)
print(sql)
PY
}

run_psql() {
	"$PSQL" -X -v ON_ERROR_STOP=1 "$@"
}

generate_data() {
	local translated_sql

	require_file "$SETUP_SQL"
	translated_sql="$(mktemp)"
	trap 'rm -f "$translated_sql"' RETURN

	echo "=== Generating PostgreSQL data: ${DB_NAME} from ${SETUP_LABEL}.sql ==="
	"$DROPDB" --if-exists "$DB_NAME" >/dev/null 2>&1 || true
	"$CREATEDB" "$DB_NAME"
	translate_duckdb_setup_sql "$SETUP_SQL" >"$translated_sql"
	run_psql -d "$DB_NAME" -f "$translated_sql"
	echo "=== Data generated in PostgreSQL database: $DB_NAME ==="
}

emit_settings_sql() {
	local case_label="$1"

	printf '\\i %s\n' "$COMMON_SETTINGS_SQL"
	printf '\\i %s\n' "$RUN_SETTINGS_SQL"
	case_settings_for "$case_label"
}

emit_query_sql() {
	cat <<'SQL'
SELECT min(b.valueB1)
FROM a
JOIN b ON a.keyB1 = b.keyB1
SQL
}

build_bench_sql() {
	local case_label="$1"
	local seed_label="$2"

	emit_settings_sql "$case_label"
	if [[ -n "$seed_label" ]]; then
		printf -- '-- seed %s: label only; PostgreSQL does not use DuckDB transfer_graph_seed\n' "$seed_label"
	fi
	echo "PREPARE benchmark_query AS"
	emit_query_sql
	echo ";"
	echo "\\pset tuples_only on"
	echo "\\pset format unaligned"
	if ! $NO_WARMUP; then
		echo "\\o /dev/null"
		echo "EXECUTE benchmark_query;"
		echo "\\o"
	fi
	for ((i = 1; i <= RUNS; i++)); do
		echo "SELECT clock_timestamp() AS t0 \\gset"
		echo "\\o /dev/null"
		echo "EXECUTE benchmark_query;"
		echo "\\o"
		echo "SELECT 'PERRUN_S=${i}=' || to_char(EXTRACT(EPOCH FROM clock_timestamp() - :'t0'::timestamptz), 'FM999999990.000000');"
	done
}

build_explain_sql() {
	local case_label="$1"
	local seed_label="$2"

	emit_settings_sql "$case_label"
	if [[ -n "$seed_label" ]]; then
		printf -- '-- seed %s: label only; PostgreSQL does not use DuckDB transfer_graph_seed\n' "$seed_label"
	fi
	echo "EXPLAIN (ANALYZE, BUFFERS, TIMING ON, SUMMARY ON)"
	emit_query_sql
	echo ";"
}

capture_runs() {
	local output_file="$1"
	local case_label="$2"
	local seed_label="$3"
	local run_count=0

	while IFS= read -r line; do
		line="${line%$'\r'}"
		if [[ "$line" =~ ^PERRUN_S=([0-9]+)=([0-9.]+)$ ]]; then
			local run_idx="${BASH_REMATCH[1]}"
			local runtime="${BASH_REMATCH[2]}"

			run_count=$((run_count + 1))
			if [[ -n "$CSV_PATH" ]]; then
				printf '%s,%s,%s,%s\n' "$DB_NAME" "$case_label" "$seed_label" "$runtime" >>"$CSV_PATH"
			fi
			echo "  run ${run_idx}: ${runtime} s"
		fi
	done <"$output_file"

	if [[ "$run_count" -lt "$RUNS" ]]; then
		echo "Warning: captured ${run_count}/${RUNS} runs for case=${case_label} seed=${seed_label:-default}" >&2
		echo "--- psql stdout: ---" >&2
		cat "$output_file" >&2
		echo "--- end ---" >&2
	fi

	CAPTURED_RUNS="$run_count"
}

require_executable "$PSQL"
require_executable "$CREATEDB"
require_executable "$DROPDB"
require_executable "$PG_CTL"
require_file "$COMMON_SETTINGS_SQL"
require_file "$RUN_SETTINGS_SQL"
require_file "$SETUP_SQL"

if $START_SERVER; then
	start_server
fi
if ! server_is_running; then
	echo "Error: PostgreSQL server is not running for $DATA_DIR" >&2
	echo "Start it with: ./rebuild-postgres.sh --start" >&2
	exit 1
fi

if $GENERATE; then
	generate_data
fi

if ! database_exists; then
	echo "Error: PostgreSQL database '$DB_NAME' does not exist. Run with --generate first." >&2
	exit 1
fi

SWEEPING=false
if $SWEEPING_SEEDS || [[ ${#CASES[@]} -gt 1 ]]; then
	SWEEPING=true
fi
if $SWEEPING && [[ -z "$CSV_PATH" ]]; then
	mkdir -p "$REPO_ROOT/hugo_generated_results"
	CSV_PATH="$REPO_ROOT/hugo_generated_results/hugo_generated_postgres_runtimes_$(date +%Y%m%d_%H%M%S).csv"
fi
if [[ -n "$CSV_PATH" ]]; then
	mkdir -p "$(dirname "$CSV_PATH")"
	printf "query,case,seed,runtime_seconds\n" >"$CSV_PATH"
fi

echo "Starting PostgreSQL Hugo-generated benchmark (cases: ${CASES[*]}, seeds: ${SEEDS[*]:-default}, runs/tuple: ${RUNS}, db: ${DB_NAME})..."

TOTAL_RUNS=0
for c in "${CASES[@]}"; do
	for s in "${SEEDS[@]}"; do
		seed_disp="${s:-default}"
		echo "=== case=${c} seed=${seed_disp} runs=${RUNS} ==="

		tmp_out="$(mktemp)"
		tmp_err="$(mktemp)"
		drop_os_page_cache
		if ! build_bench_sql "$c" "$s" | run_psql -d "$DB_NAME" >"$tmp_out" 2>"$tmp_err"; then
			cat "$tmp_err" >&2
			cat "$tmp_out" >&2
			rm -f "$tmp_out" "$tmp_err"
			echo "Error: benchmark query failed (case ${c}, seed ${seed_disp})" >&2
			exit 1
		fi
		cat "$tmp_err" >&2
		CAPTURED_RUNS=0
		capture_runs "$tmp_out" "$c" "$s"
		TOTAL_RUNS=$((TOTAL_RUNS + CAPTURED_RUNS))
		rm -f "$tmp_out" "$tmp_err"

		if $PROFILE; then
			mkdir -p "$(dirname "$PROFILE_OUT")"
			echo "Writing EXPLAIN ANALYZE output to: $PROFILE_OUT"
			drop_os_page_cache
			build_explain_sql "$c" "$s" | run_psql -d "$DB_NAME" >"$PROFILE_OUT"
		fi
	done
done

echo "Benchmark complete."
if [[ -n "$CSV_PATH" ]]; then
	echo "CSV written to: $CSV_PATH"
fi
if $PROFILE; then
	echo "EXPLAIN ANALYZE output written to: $PROFILE_OUT"
fi
