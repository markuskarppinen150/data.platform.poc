-- Example Iceberg queries for Trino with Apache Polaris REST Catalog

-- 1. Show available catalogs
SHOW CATALOGS;

-- 2. Create Iceberg namespace (database)
CREATE SCHEMA IF NOT EXISTS iceberg.data_lake
WITH (location = 's3a://iceberg/');

-- 2. Create Iceberg table for image metadata
CREATE TABLE IF NOT EXISTS iceberg.data_lake.images (
    id BIGINT,
    filename VARCHAR,
    file_hash VARCHAR,
    file_size BIGINT,
    width INTEGER,
    height INTEGER,
    mime_type VARCHAR,
    s3_path VARCHAR,
    uploaded_at TIMESTAMP,
    kafka_offset BIGINT,
    kafka_partition INTEGER
)
WITH (
    format = 'PARQUET',
    location = 's3a://iceberg/data_lake/images',
    partitioning = ARRAY['day(uploaded_at)']
);

-- 3. Insert data from PostgreSQL to Iceberg
-- (Using Trino's PostgreSQL connector)
INSERT INTO iceberg.data_lake.images
SELECT 
    id,
    filename,
    file_hash,
    file_size,
    CAST(NULL AS INTEGER) as width,
    CAST(NULL AS INTEGER) as height,
    mime_type,
    s3_path,
    uploaded_at,
    kafka_offset,
    kafka_partition
FROM postgres.public.image_metadata;

-- 4. Query Iceberg table
SELECT 
    DATE(uploaded_at) as upload_date,
    COUNT(*) as image_count,
    SUM(file_size) / 1024 / 1024 as total_size_mb
FROM iceberg.data_lake.images
GROUP BY DATE(uploaded_at)
ORDER BY upload_date DESC;

-- 5. Time travel - query data as of specific time
SELECT * FROM iceberg.data_lake.images
FOR TIMESTAMP AS OF TIMESTAMP '2026-02-11 12:00:00';

-- 6. Show table history (snapshots)
SELECT * FROM iceberg.data_lake."images$snapshots"
ORDER BY committed_at DESC;

-- 7. Show table files
SELECT * FROM iceberg.data_lake."images$files";

-- 8. Query by partition
SELECT * FROM iceberg.data_lake.images
WHERE uploaded_at >= DATE '2026-02-11'
  AND uploaded_at < DATE '2026-02-12';

-- 9. Update data (Iceberg supports ACID)
UPDATE iceberg.data_lake.images
SET mime_type = 'image/jpeg'
WHERE mime_type = 'image/jpg';

-- 10. Delete old data
DELETE FROM iceberg.data_lake.images
WHERE uploaded_at < DATE '2026-01-01';

-- 11. Expire old snapshots (cleanup)
ALTER TABLE iceberg.data_lake.images
EXECUTE expire_snapshots(retention_threshold => '7d');

-- 12. Optimize table (compact small files)
ALTER TABLE iceberg.data_lake.images
EXECUTE optimize;
