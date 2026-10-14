-- =====================================================================
-- Query analyzer demo: partition pruning defeated by a function
-- Starburst / Trino, Iceberg connector
--
-- Story:
--   1. A table partitioned by event_date, ~100+ MB of data for September.
--   2. A "dashboard" query filters with date_format(event_date, ...), which
--      hides the partition column inside a function. No partition pruning:
--      the query reads every partition to return one day of results.
--   3. October data is added. The same query returns the SAME result but
--      reads roughly TWICE the data. Cost grows with the table, not the answer.
--   4. The correct filter (event_date = DATE '...') reads one partition,
--      before and after the new data.
--
-- Before running:
--   * Replace demo_catalog.demo_schema with your Iceberg catalog and schema.
--   * If Warp Speed / result caching is enabled on the demo cluster, disable
--     it for this session so scan sizes are honest.
--   * Completed query details expire from the coordinator after a while
--     (query.min-expire-age / query.max-history). Run the analysis soon
--     after the demo queries, or capture the query IDs right away.
--
-- Each demo query carries a tag comment (/* demo:... */) so its query ID is
-- easy to find in system.runtime.queries.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. Clean start
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS demo_catalog.demo_schema.orders_demo;


-- ---------------------------------------------------------------------
-- 1. Create the table, partitioned by day
-- ---------------------------------------------------------------------
CREATE TABLE demo_catalog.demo_schema.orders_demo (
    order_id     varchar,
    event_date   date,
    customer_id  bigint,
    region       varchar,
    amount       decimal(12, 2),
    payload      varchar          -- high-entropy filler so the data is not tiny after compression
)
WITH (
    format       = 'PARQUET',
    partitioning = ARRAY['event_date']
);


-- ---------------------------------------------------------------------
-- 2. Load September: 30 days x 70,000 rows = 2.1M rows (~100-150 MB on disk)
--    To change the size, adjust the upper bound of b (700).
-- ---------------------------------------------------------------------
INSERT INTO demo_catalog.demo_schema.orders_demo
SELECT
    CAST(uuid() AS varchar)                                                       AS order_id,
    d.day                                                                         AS event_date,
    CAST(floor(random() * 100000) AS bigint)                                      AS customer_id,
    element_at(ARRAY['east', 'west', 'north', 'south'],
               CAST(floor(random() * 4) AS integer) + 1)                          AS region,
    CAST(random() * 1000 AS decimal(12, 2))                                       AS amount,
    to_hex(sha256(to_utf8(CAST(uuid() AS varchar))))                              AS payload
FROM UNNEST(sequence(DATE '2026-09-01', DATE '2026-09-30', INTERVAL '1' DAY)) AS d(day)
CROSS JOIN UNNEST(sequence(1, 100)) AS a(i)
CROSS JOIN UNNEST(sequence(1, 700)) AS b(j);


-- ---------------------------------------------------------------------
-- 3. Check the table: partitions, rows and size
-- ---------------------------------------------------------------------
SELECT count(*)                         AS partitions,
       sum(record_count)                AS total_rows,
       sum(file_count)                  AS total_files,
       round(sum(total_size) / 1e6, 1)  AS total_mb
FROM demo_catalog.demo_schema."orders_demo$partitions";

-- Size of one day (what a well-written query should read)
SELECT partition, record_count, file_count, round(total_size / 1e6, 1) AS mb
FROM demo_catalog.demo_schema."orders_demo$partitions"
ORDER BY partition
LIMIT 5;


-- ---------------------------------------------------------------------
-- 4. RUN 1: the "bad" dashboard query (function on the partition column)
--    Expected: reads all 30 partitions to answer for 1 day.
-- ---------------------------------------------------------------------
SELECT /* demo:bad_run1 */
       region,
       count(*)    AS orders,
       sum(amount) AS revenue
FROM demo_catalog.demo_schema.orders_demo
WHERE date_format(event_date, '%Y-%m-%d') = '2026-09-15'
GROUP BY region
ORDER BY region;


-- ---------------------------------------------------------------------
-- 5. RUN 1: the "good" query (filter directly on the partition column)
--    Expected: reads 1 partition. Same result as step 4.
-- ---------------------------------------------------------------------
SELECT /* demo:good_run1 */
       region,
       count(*)    AS orders,
       sum(amount) AS revenue
FROM demo_catalog.demo_schema.orders_demo
WHERE event_date = DATE '2026-09-15'
GROUP BY region
ORDER BY region;


-- ---------------------------------------------------------------------
-- 6. The table grows: load October (another 30 days, same volume)
-- ---------------------------------------------------------------------
INSERT INTO demo_catalog.demo_schema.orders_demo
SELECT
    CAST(uuid() AS varchar),
    d.day,
    CAST(floor(random() * 100000) AS bigint),
    element_at(ARRAY['east', 'west', 'north', 'south'],
               CAST(floor(random() * 4) AS integer) + 1),
    CAST(random() * 1000 AS decimal(12, 2)),
    to_hex(sha256(to_utf8(CAST(uuid() AS varchar))))
FROM UNNEST(sequence(DATE '2026-10-01', DATE '2026-10-30', INTERVAL '1' DAY)) AS d(day)
CROSS JOIN UNNEST(sequence(1, 100)) AS a(i)
CROSS JOIN UNNEST(sequence(1, 700)) AS b(j);

-- Table is now ~2x the size
SELECT count(*)                         AS partitions,
       sum(record_count)                AS total_rows,
       round(sum(total_size) / 1e6, 1)  AS total_mb
FROM demo_catalog.demo_schema."orders_demo$partitions";


-- ---------------------------------------------------------------------
-- 7. RUN 2: the same bad query again
--    Expected: SAME result as run 1, but ~2x the data read (60 partitions).
-- ---------------------------------------------------------------------
SELECT /* demo:bad_run2 */
       region,
       count(*)    AS orders,
       sum(amount) AS revenue
FROM demo_catalog.demo_schema.orders_demo
WHERE date_format(event_date, '%Y-%m-%d') = '2026-09-15'
GROUP BY region
ORDER BY region;


-- ---------------------------------------------------------------------
-- 8. RUN 2: the good query again
--    Expected: same result, still reads only 1 partition.
-- ---------------------------------------------------------------------
SELECT /* demo:good_run2 */
       region,
       count(*)    AS orders,
       sum(amount) AS revenue
FROM demo_catalog.demo_schema.orders_demo
WHERE event_date = DATE '2026-09-15'
GROUP BY region
ORDER BY region;


-- ---------------------------------------------------------------------
-- 9. Find the query IDs to hand to the agent
-- ---------------------------------------------------------------------
SELECT query_id,
       state,
       created,
       regexp_extract(query, 'demo:[a-z_0-9]+') AS tag
FROM system.runtime.queries
WHERE query LIKE '%/* demo:%'
  AND query NOT LIKE '%system.runtime.queries%'
ORDER BY created;

-- Ask the agent, for example:
--   "Same query, same result, but run 2 (<bad_run2 id>) read twice as much
--    as run 1 (<bad_run1 id>). Why?"


-- ---------------------------------------------------------------------
-- 10. Optional: show the difference in the plan yourself
--     EXPLAIN does not run the query. Compare the table scan of each:
--     the good plan carries a constraint on event_date; the bad plan
--     scans everything and applies date_format(...) as a filter afterwards.
-- ---------------------------------------------------------------------
EXPLAIN
SELECT region, count(*), sum(amount)
FROM demo_catalog.demo_schema.orders_demo
WHERE date_format(event_date, '%Y-%m-%d') = '2026-09-15'
GROUP BY region;

EXPLAIN
SELECT region, count(*), sum(amount)
FROM demo_catalog.demo_schema.orders_demo
WHERE event_date = DATE '2026-09-15'
GROUP BY region;

-- EXPLAIN ANALYZE runs the query and prints rows/bytes read per operator.
-- Use it live only on the demo table.
EXPLAIN ANALYZE
SELECT region, count(*), sum(amount)
FROM demo_catalog.demo_schema.orders_demo
WHERE date_format(event_date, '%Y-%m-%d') = '2026-09-15'
GROUP BY region;


-- ---------------------------------------------------------------------
-- 11. Other filters that defeat pruning the same way (for more demos)
--     Note: Trino can rewrite some simple patterns (for example
--     CAST(timestamp AS date) = DATE '...' or year(col) = 2026) into
--     range filters that still prune. The patterns below are not rewritten.
-- ---------------------------------------------------------------------
-- WHERE CAST(event_date AS varchar) = '2026-09-15'
-- WHERE substr(CAST(event_date AS varchar), 1, 7) = '2026-09'
-- WHERE format_datetime(CAST(event_date AS timestamp), 'yyyy-MM-dd') = '2026-09-15'
-- WHERE date_add('day', 1, event_date) = DATE '2026-09-16'


-- ---------------------------------------------------------------------
-- 12. Clean up after the demo
-- ---------------------------------------------------------------------
-- DROP TABLE demo_catalog.demo_schema.orders_demo;
