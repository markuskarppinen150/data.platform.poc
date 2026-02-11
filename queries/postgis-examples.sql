-- PostGIS Examples for PostgreSQL
-- Demonstrating geospatial capabilities

-- 1. Create a table with geometry column
CREATE TABLE IF NOT EXISTS locations (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    location GEOMETRY(Point, 4326),  -- WGS84 coordinate system
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 2. Insert sample locations
INSERT INTO locations (name, location) VALUES
    ('New York', ST_SetSRID(ST_MakePoint(-74.0060, 40.7128), 4326)),
    ('London', ST_SetSRID(ST_MakePoint(-0.1278, 51.5074), 4326)),
    ('Tokyo', ST_SetSRID(ST_MakePoint(139.6917, 35.6895), 4326)),
    ('Sydney', ST_SetSRID(ST_MakePoint(151.2093, -33.8688), 4326)),
    ('Rio', ST_SetSRID(ST_MakePoint(-43.1729, -22.9068), 4326));

-- 3. Query locations
SELECT 
    name,
    ST_AsText(location) as coordinates,
    ST_X(location) as longitude,
    ST_Y(location) as latitude
FROM locations;

-- 4. Calculate distances between points (in meters)
SELECT 
    l1.name as from_city,
    l2.name as to_city,
    ROUND(ST_Distance(l1.location::geography, l2.location::geography)::numeric / 1000, 2) as distance_km
FROM locations l1
CROSS JOIN locations l2
WHERE l1.id < l2.id
ORDER BY distance_km;

-- 5. Find locations within radius (e.g., 5000km from New York)
SELECT 
    name,
    ROUND(ST_Distance(
        location::geography,
        (SELECT location::geography FROM locations WHERE name = 'New York')
    )::numeric / 1000, 2) as distance_km
FROM locations
WHERE ST_DWithin(
    location::geography,
    (SELECT location::geography FROM locations WHERE name = 'New York'),
    5000000  -- 5000 km in meters
)
AND name != 'New York'
ORDER BY distance_km;

-- 6. Create a polygon (e.g., a bounding box)
CREATE TABLE IF NOT EXISTS regions (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    boundary GEOMETRY(Polygon, 4326)
);

-- Insert a sample region (Europe approximate bounding box)
INSERT INTO regions (name, boundary) VALUES (
    'Europe',
    ST_SetSRID(ST_MakePolygon(ST_GeomFromText(
        'LINESTRING(-10 35, 40 35, 40 70, -10 70, -10 35)'
    )), 4326)
);

-- 7. Check which locations are within a region
SELECT 
    l.name,
    r.name as region
FROM locations l
JOIN regions r ON ST_Within(l.location, r.boundary);

-- 8. Calculate area of a polygon (in square kilometers)
SELECT 
    name,
    ROUND((ST_Area(boundary::geography) / 1000000)::numeric, 2) as area_sq_km
FROM regions;

-- 9. Create spatial index for performance
CREATE INDEX IF NOT EXISTS idx_locations_geom ON locations USING GIST(location);
CREATE INDEX IF NOT EXISTS idx_regions_geom ON regions USING GIST(boundary);

-- 10. Add image locations table with GPS coordinates
CREATE TABLE IF NOT EXISTS image_locations (
    id SERIAL PRIMARY KEY,
    image_id INTEGER REFERENCES image_metadata(id),
    location GEOMETRY(Point, 4326),
    altitude FLOAT,
    direction FLOAT,  -- compass direction in degrees
    captured_at TIMESTAMP
);

-- 11. Extract GPS data from EXIF and insert
-- Example: INSERT INTO image_locations (image_id, location, altitude, captured_at)
-- VALUES (1, ST_SetSRID(ST_MakePoint(longitude, latitude), 4326), altitude, timestamp);

-- 12. Find images near a location
SELECT 
    im.filename,
    il.altitude,
    ST_AsText(il.location) as coordinates,
    ROUND(ST_Distance(
        il.location::geography,
        ST_SetSRID(ST_MakePoint(-74.0060, 40.7128), 4326)::geography
    )::numeric, 2) as distance_meters
FROM image_metadata im
JOIN image_locations il ON im.id = il.image_id
WHERE ST_DWithin(
    il.location::geography,
    ST_SetSRID(ST_MakePoint(-74.0060, 40.7128), 4326)::geography,
    1000  -- within 1km
)
ORDER BY distance_meters;

-- 13. Create a heatmap query (group by grid cells)
SELECT 
    ST_AsText(ST_SnapToGrid(location, 0.1)) as grid_cell,
    COUNT(*) as image_count
FROM image_locations
GROUP BY grid_cell
ORDER BY image_count DESC;

-- 14. Line of sight / trajectory
CREATE TABLE IF NOT EXISTS trajectories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    path GEOMETRY(LineString, 4326)
);

-- 15. Buffer zone around a point (e.g., 10km radius)
SELECT 
    name,
    ST_AsText(ST_Buffer(location::geography, 10000)::geometry) as buffer_10km
FROM locations
WHERE name = 'Tokyo';

-- 16. Check PostGIS version and capabilities
SELECT PostGIS_Full_Version();

-- 17. List all PostGIS functions
SELECT 
    proname as function_name,
    pg_catalog.pg_get_function_arguments(oid) as arguments
FROM pg_proc
WHERE pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
  AND proname LIKE 'st_%'
ORDER BY proname
LIMIT 20;
