-- Partition checks: layout, runway, partition ACL vs parent, foreign keys that affect DETACH. Read-only.
-- Run through pg.sh (stdin), as a role that can read the catalogs (superuser recommended):
--   bash <kit>/scripts/pg.sh psql <name> <dsn> -v min_runway_days=30 < <kit>/scripts/partitions.sql
-- Variables: min_runway_days (default 30). Needs PostgreSQL >= 16 (pg_input_is_valid).
-- Last line: partitions_summary parents=… runway_violations=… acl_mismatches=… missing_default=…
\set QUIET on
\if :{?min_runway_days}
\else
  \set min_runway_days 30
\endif
\pset footer off

\echo '### partitioned tables and partitions'
SELECT p.oid::regclass AS parent,
       pg_get_partkeydef(p.oid) AS partition_key,
       c.oid::regclass AS partition,
       pg_get_expr(c.relpartbound, c.oid) AS bound
FROM pg_partitioned_table pt
JOIN pg_class p ON p.oid = pt.partrelid
LEFT JOIN pg_inherits i ON i.inhparent = p.oid
LEFT JOIN pg_class c ON c.oid = i.inhrelid
WHERE p.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
ORDER BY 1, 4;

\echo '### runway (range partitions on a time key: latest upper bound minus now)'
CREATE TEMP VIEW dbrev_runway AS
WITH b AS (
  SELECT i.inhparent AS parent,
         (regexp_match(pg_get_expr(c.relpartbound, c.oid), 'TO \(''([^'']+)''\)'))[1] AS upper_txt
  FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
  JOIN pg_partitioned_table pt ON pt.partrelid = i.inhparent AND pt.partstrat = 'r'
)
SELECT parent::regclass AS parent,
       max(upper_txt::timestamptz) AS latest_upper_bound,
       round(extract(epoch FROM (max(upper_txt::timestamptz) - now())) / 86400.0, 1) AS runway_days
FROM b
WHERE upper_txt IS NOT NULL AND pg_input_is_valid(upper_txt, 'timestamptz')
GROUP BY parent;
SELECT r.*, (r.runway_days < :min_runway_days) AS below_minimum, :min_runway_days AS min_runway_days
FROM dbrev_runway r ORDER BY 1;

\echo '### partition ACL differs from parent (NULL = default privileges)'
CREATE TEMP VIEW dbrev_acl AS
SELECT i.inhparent::regclass AS parent, c.oid::regclass AS partition,
       p.relacl::text AS parent_acl, c.relacl::text AS partition_acl
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_class p ON p.oid = i.inhparent
JOIN pg_partitioned_table pt ON pt.partrelid = p.oid
WHERE c.relacl IS DISTINCT FROM p.relacl;
SELECT * FROM dbrev_acl ORDER BY 1, 2;

\echo '### partition column ACL differs from parent (column-level GRANTs)'
CREATE TEMP VIEW dbrev_colacl AS
SELECT i.inhparent::regclass AS parent, c.oid::regclass AS partition, pa.attname AS column_name,
       pa.attacl::text AS parent_acl, ca.attacl::text AS partition_acl
FROM pg_inherits i
JOIN pg_class c ON c.oid = i.inhrelid
JOIN pg_partitioned_table pt ON pt.partrelid = i.inhparent
JOIN pg_attribute pa ON pa.attrelid = i.inhparent AND pa.attnum > 0 AND NOT pa.attisdropped
JOIN pg_attribute ca ON ca.attrelid = c.oid AND ca.attname = pa.attname AND NOT ca.attisdropped
WHERE ca.attacl IS DISTINCT FROM pa.attacl;
SELECT * FROM dbrev_colacl ORDER BY 1, 2, 3;

\echo '### foreign keys on partitioned tables (DETACH takes locks on referenced tables; consider DETACH CONCURRENTLY only without them)'
SELECT con.conrelid::regclass AS partitioned_table, con.conname, con.confrelid::regclass AS references_table,
       pg_get_constraintdef(con.oid) AS definition
FROM pg_constraint con
JOIN pg_partitioned_table pt ON pt.partrelid = con.conrelid
WHERE con.contype = 'f' AND con.conparentid = 0
ORDER BY 1, 2;
SELECT con.conrelid::regclass AS referencing_table, con.conname, con.confrelid::regclass AS partitioned_table_referenced
FROM pg_constraint con
JOIN pg_partitioned_table pt ON pt.partrelid = con.confrelid
WHERE con.contype = 'f' AND con.conparentid = 0
ORDER BY 1, 2;

\echo '### default partition (range / list only; out-of-range writes fail without one)'
SELECT p.oid::regclass AS parent, (pt.partdefid <> 0) AS has_default_partition
FROM pg_partitioned_table pt JOIN pg_class p ON p.oid = pt.partrelid
WHERE pt.partstrat <> 'h' AND p.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
ORDER BY 1;

\pset tuples_only on
\pset format unaligned
SELECT 'partitions_summary parents=' || (SELECT count(*) FROM pg_partitioned_table pt JOIN pg_class p ON p.oid = pt.partrelid
                                          WHERE p.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace))
    || ' runway_violations=' || (SELECT count(*) FROM dbrev_runway WHERE runway_days < :min_runway_days)
    || ' acl_mismatches=' || ((SELECT count(*) FROM dbrev_acl) + (SELECT count(*) FROM dbrev_colacl))
    || ' missing_default=' || (SELECT count(*) FROM pg_partitioned_table pt JOIN pg_class p ON p.oid = pt.partrelid
                               WHERE pt.partdefid = 0 AND pt.partstrat <> 'h'
                                 AND p.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace));
