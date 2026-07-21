CREATE OR REPLACE TABLE t AS SELECT * FROM read_parquet('t.parquet');
CREATE OR REPLACE TABLE d AS SELECT * FROM read_parquet('dict.parquet');
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS v1 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS v2 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS v3 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS v4 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS v5 FROM t LEFT JOIN d ON t.key = d.key;
CREATE OR REPLACE TABLE t AS SELECT t.*, d.value AS v6 FROM t LEFT JOIN d ON t.key = d.key;
SELECT COUNT(*) FROM t;
