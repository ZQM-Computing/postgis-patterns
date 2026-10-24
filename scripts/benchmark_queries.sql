-- Read-only plan/benchmark harness for the synthetic PostGIS demo.
-- Run after: make validate
-- Example: docker compose exec -T db psql -U patterns -d postgis_patterns -v ON_ERROR_STOP=1 < scripts/benchmark_queries.sql
--
-- EXPLAIN ANALYZE executes each SELECT. These statements are read-only, but
-- production users should still run them on representative non-critical data.
-- The demo has only 9 sites and 24 parcels: do not infer scale performance.

\set ON_ERROR_STOP on

SELECT 'benchmark_context' AS section,
       current_setting('server_version') AS postgres_version,
       postgis_full_version() AS postgis_version,
       current_database() AS database_name,
       now() AS captured_at;

SELECT 'table_sizes' AS section,
       relname AS table_name,
       n_live_tup AS estimated_rows,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size,
       last_analyze,
       last_autoanalyze
FROM pg_stat_user_tables
WHERE schemaname = 'demo'
ORDER BY relname;

\echo '1. Geometry index / bounding-box candidate plus exact intersection'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT area.area_id
FROM demo.service_areas AS area
WHERE area.geom && ST_MakeEnvelope(-81.15, 29.05, -81.00, 29.30, 4326)
  AND ST_Intersects(
      area.geom,
      ST_MakeEnvelope(-81.15, 29.05, -81.00, 29.30, 4326)
  );

\echo '2. Geography expression index candidate for meter-based distance'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT site.site_id
FROM demo.service_sites AS site
WHERE ST_DWithin(
    site.geom::geography,
    ST_SetSRID(ST_MakePoint(-81.06, 29.26), 4326)::geography,
    7500
);

\echo '3. Combined spatial + categorical filter'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT site.site_id
FROM demo.service_sites AS site
WHERE site.category = 'operations'
  AND ST_DWithin(
      site.geom::geography,
      ST_SetSRID(ST_MakePoint(-81.06, 29.26), 4326)::geography,
      15000
  );

\echo '4. Time-window filter on observations'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT observation_id, site_id, reading_value
FROM demo.sensor_observations
WHERE observed_at >= TIMESTAMPTZ '2026-01-01 00:00:00+00'
  AND observed_at < TIMESTAMPTZ '2027-01-01 00:00:00+00';

\echo '5. Partition pruning: bounded query against partitioned observations'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT site_id, count(*) AS observations
FROM demo.sensor_observations_partitioned
WHERE observed_at >= TIMESTAMPTZ '2026-01-01 00:00:00+00'
  AND observed_at < TIMESTAMPTZ '2027-01-01 00:00:00+00'
GROUP BY site_id;

\echo '6. Exact geography nearest site: correctness baseline, not a large-table strategy'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT candidate.site_id,
       candidate.name,
       ST_Distance(
           candidate.geom::geography,
           ST_SetSRID(ST_MakePoint(-81.06, 29.26), 4326)::geography
       ) AS exact_distance_m
FROM demo.service_sites AS candidate
ORDER BY exact_distance_m
LIMIT 3;

\echo '7. Geometry KNN shortlist: fast candidate generation; exact distance reranks shortlist only'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
WITH query_point AS (
    SELECT ST_SetSRID(ST_MakePoint(-81.06, 29.26), 4326) AS geom
),
candidates AS (
    SELECT site.site_id, site.name, site.geom, query_point.geom AS query_geom
    FROM demo.service_sites AS site
    CROSS JOIN query_point
    ORDER BY site.geom <-> query_point.geom
    LIMIT 5
)
SELECT site_id, name,
       ST_Distance(geom::geography, query_geom::geography) AS exact_distance_m
FROM candidates
ORDER BY exact_distance_m
LIMIT 3;

SELECT 'benchmark_notes' AS section,
       'Compare estimated/actual rows, buffers, loops, sorts, and plan shape on representative data. Sequential scans are valid for small/selective workloads.' AS guidance;
