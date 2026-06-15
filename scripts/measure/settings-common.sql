------------------------- Common Settings -----------------------------

-- Keep benchmark queries single-process.  PostgreSQL does not have DuckDB's
-- `threads` setting; disabling parallel workers per Gather is the query-level
-- knob that prevents worker processes from participating in a plan.
SET max_parallel_workers_per_gather = 0;
SET max_parallel_maintenance_workers = 0;
SET enable_parallel_append = off;

-- Keep the benchmark on the hash-join path.
SET enable_mergejoin = off;
SET enable_nestloop = off;

-- Avoid one-time JIT compilation noise in wall-clock measurements.
SET jit = off;
