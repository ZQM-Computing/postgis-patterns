-- Pattern 02: Spatial joins, distance filters, and nearest neighbors

-- Count sites in each service area. ST_Covers includes points on the boundary;
-- choose ST_Contains instead when boundary points must be excluded.
SELECT
    area.name AS service_area,
    count(site.site_id) AS site_count
FROM demo.service_areas AS area
LEFT JOIN demo.service_sites AS site
    ON ST_Covers(area.geom, site.geom)
GROUP BY area.area_id, area.name
ORDER BY area.name;

-- Find sites within 7.5 km of a search point. ST_DWithin can use the
-- geography expression index; filtering on ST_Distance would not provide the
-- same index-friendly predicate.
WITH search_point AS (
    SELECT ST_SetSRID(ST_MakePoint(-81.06, 29.26), 4326) AS geom
)
SELECT
    site.name,
    site.category,
    round((ST_Distance(site.geom::geography, search.geom::geography) / 1000.0)::numeric, 2) AS distance_km
FROM demo.service_sites AS site
CROSS JOIN search_point AS search
WHERE ST_DWithin(site.geom::geography, search.geom::geography, 7500)
ORDER BY distance_km;

-- Inspect a plan after loading representative data. The demo is intentionally
-- small, so a sequential scan can legitimately win here.
EXPLAIN (ANALYZE, BUFFERS)
SELECT site.site_id
FROM demo.service_sites AS site
WHERE ST_DWithin(
    site.geom::geography,
    ST_SetSRID(ST_MakePoint(-81.06, 29.26), 4326)::geography,
    7500
);

-- Find the exact nearest other site for every site using geography
-- distance. Ordering point geometries with <-> is a fast planar KNN strategy,
-- but it is not a general guarantee of spheroidal-distance ordering. This
-- all-candidates query is appropriate for the tiny demo; use a measured and
-- validated candidate strategy for large datasets.
SELECT
    site.name AS site,
    nearest.name AS nearest_site,
    round((nearest.exact_distance_m / 1000.0)::numeric, 2) AS distance_km
FROM demo.service_sites AS site
CROSS JOIN LATERAL (
    SELECT
        candidate.name,
        ST_Distance(site.geom::geography, candidate.geom::geography) AS exact_distance_m
    FROM demo.service_sites AS candidate
    WHERE candidate.site_id <> site.site_id
    ORDER BY exact_distance_m, candidate.site_id
    LIMIT 1
) AS nearest
ORDER BY site.name;

-- Assign each parcel to the service area containing its centroid. This avoids
-- double-counting parcels that cross a service-area boundary.
SELECT
    area.name AS service_area,
    count(parcel.parcel_id) AS parcel_count,
    round(sum(parcel.assessed_value), 2) AS total_assessed_value
FROM demo.service_areas AS area
LEFT JOIN demo.parcels AS parcel
    ON ST_Covers(area.geom, ST_Centroid(parcel.geom))
GROUP BY area.area_id, area.name
ORDER BY area.name;

-- Find the exact three closest service areas to an external point.
-- Polygon <-> ordering uses bounding-box distance, which is not guaranteed to
-- match exact geography distance. For this small demo, rank every area by the
-- exact metric. At scale, use KNN only to generate candidates and document that
-- a fixed-size shortlist is approximate unless its recall is proven.
WITH search_point AS (
    SELECT ST_SetSRID(ST_MakePoint(-81.30, 29.20), 4326) AS geom
),
distances AS (
    SELECT
        area.name,
        ST_Distance(area.geom::geography, search.geom::geography) AS exact_distance_m
    FROM demo.service_areas AS area
    CROSS JOIN search_point AS search
)
SELECT
    name,
    round((exact_distance_m / 1000.0)::numeric, 2) AS exact_distance_km
FROM distances
ORDER BY exact_distance_m, name
LIMIT 3;
