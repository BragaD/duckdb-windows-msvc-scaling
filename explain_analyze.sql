-- EXPLAIN ANALYZE of one wide LEFT JOIN from the workload (duckdb CLI).
-- Run: duckdb :memory: < explain_analyze.sql   (edit SET threads to taste)
SET threads TO 8;
CREATE TABLE t AS SELECT i AS id, 'k' || CAST(hash(i) % 2000000 AS VARCHAR) AS key,
  'p1_' || CAST(hash(i * 10) % 100000 AS VARCHAR) AS p1,
  'p2_' || CAST(hash(i * 17) % 100000 AS VARCHAR) AS p2,
  'p3_' || CAST(hash(i * 24) % 100000 AS VARCHAR) AS p3,
  'p4_' || CAST(hash(i * 31) % 100000 AS VARCHAR) AS p4,
  'p5_' || CAST(hash(i * 38) % 100000 AS VARCHAR) AS p5,
  'p6_' || CAST(hash(i * 45) % 100000 AS VARCHAR) AS p6,
  'p7_' || CAST(hash(i * 52) % 100000 AS VARCHAR) AS p7,
  'p8_' || CAST(hash(i * 59) % 100000 AS VARCHAR) AS p8
  FROM range(8000000) g(i);
CREATE TABLE d AS SELECT 'k' || CAST(i AS VARCHAR) AS key, 'v' || CAST(i AS VARCHAR) AS value FROM range(2000000) g(i);
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w1 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w2 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w3 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w4 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w5 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS w6 FROM t LEFT JOIN d ON t.key = d.key;
SELECT platform FROM pragma_platform();
EXPLAIN ANALYZE CREATE OR REPLACE TABLE t2 AS SELECT t.*, d.value AS w FROM t LEFT JOIN d ON t.key = d.key;
