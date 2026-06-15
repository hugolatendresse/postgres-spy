\timing on

DROP TABLE IF EXISTS left_dataset;
DROP TABLE IF EXISTS right_dataset;

CREATE TABLE left_dataset AS
SELECT
  i AS id,
  i % 1000000 AS join_key,
  repeat('left-', 8) AS payload
FROM generate_series(1, 5000000) AS g(i);

CREATE TABLE right_dataset AS
SELECT
  i AS join_key,
  repeat('right-', 8) AS payload
FROM generate_series(0, 999999) AS g(i);

ANALYZE left_dataset;
ANALYZE right_dataset;

SET max_parallel_workers_per_gather = 0;
SET enable_mergejoin = off;
SET enable_nestloop = off;

EXPLAIN (ANALYZE, BUFFERS, TIMING ON, SUMMARY ON)
SELECT count(*)
FROM left_dataset l
JOIN right_dataset r
  ON l.join_key = r.join_key;
