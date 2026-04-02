-- =============================================================================
-- MOFSL Experimentation Platform — ClickHouse Schema
-- =============================================================================
-- Database: experimentation
-- Engine: ClickHouse (self-hosted or ClickHouse Cloud)
-- Purpose: High-volume event storage and analytical queries for stats engine
-- =============================================================================

CREATE DATABASE IF NOT EXISTS experimentation;

-- =============================================================================
-- 1. EXPOSURE EVENTS
-- =============================================================================
-- Records that a user was shown a specific experiment variant.
-- Source: Kafka topic exp.exposures → ClickHouse Kafka engine → this table
-- Volume: ~10M events/day at full scale
-- =============================================================================

CREATE TABLE experimentation.exposure_events
(
    -- Event identity
    event_id          String,                   -- Server-generated UUID
    idempotency_key   String DEFAULT '',        -- Client-provided dedup key
    
    -- Core fields
    app_id            LowCardinality(String),   -- Application identifier (e.g., 'riise')
    client_code       String,                   -- MOFSL client code
    experiment_key    LowCardinality(String),   -- Experiment identifier
    variation_key     LowCardinality(String),   -- Assigned variation
    
    -- Timestamps
    timestamp         DateTime64(3, 'Asia/Kolkata'),  -- Client-side event time
    received_at       DateTime64(3, 'Asia/Kolkata'),  -- Server receive time
    
    -- Session
    session_id        String DEFAULT '',
    
    -- User attributes (denormalized for analytical queries)
    attr_platform     LowCardinality(String) DEFAULT '',    -- 'android', 'ios', 'web'
    attr_app_version  String DEFAULT '',
    attr_city         LowCardinality(String) DEFAULT '',
    attr_segment      LowCardinality(String) DEFAULT '',
    
    -- All attributes as JSON for flexible querying
    attributes        String DEFAULT '{}',      -- JSON string of all attributes
    
    -- Metadata
    api_key_id        String DEFAULT ''
)
ENGINE = ReplacingMergeTree(received_at)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (experiment_key, client_code, timestamp)
TTL timestamp + INTERVAL 1 YEAR
SETTINGS index_granularity = 8192;

-- Indices for common query patterns
ALTER TABLE experimentation.exposure_events
    ADD INDEX idx_exposure_client (client_code) TYPE bloom_filter GRANULARITY 4;

ALTER TABLE experimentation.exposure_events
    ADD INDEX idx_exposure_session (session_id) TYPE bloom_filter GRANULARITY 4;

-- =============================================================================
-- 2. CONVERSION EVENTS
-- =============================================================================
-- Records that a user performed a target action (conversion metric).
-- Source: Kafka topic exp.conversions → ClickHouse Kafka engine → this table
-- Volume: ~5M events/day at full scale
-- =============================================================================

CREATE TABLE experimentation.conversion_events
(
    -- Event identity
    event_id          String,
    idempotency_key   String DEFAULT '',
    
    -- Core fields
    app_id            LowCardinality(String),
    client_code       String,
    metric_key        LowCardinality(String),   -- e.g., 'order_placed', 'order_value'
    value             Float64,                   -- Metric value (1/0 for binary, actual value for continuous)
    
    -- Timestamps
    timestamp         DateTime64(3, 'Asia/Kolkata'),
    received_at       DateTime64(3, 'Asia/Kolkata'),
    
    -- Session
    session_id        String DEFAULT '',
    
    -- User attributes (denormalized)
    attr_platform     LowCardinality(String) DEFAULT '',
    attr_app_version  String DEFAULT '',
    attr_city         LowCardinality(String) DEFAULT '',
    attr_segment      LowCardinality(String) DEFAULT '',
    
    attributes        String DEFAULT '{}',
    
    -- Metadata
    api_key_id        String DEFAULT ''
)
ENGINE = ReplacingMergeTree(received_at)
PARTITION BY toYYYYMM(timestamp)
ORDER BY (metric_key, client_code, timestamp)
TTL timestamp + INTERVAL 1 YEAR
SETTINGS index_granularity = 8192;

ALTER TABLE experimentation.conversion_events
    ADD INDEX idx_conversion_client (client_code) TYPE bloom_filter GRANULARITY 4;

ALTER TABLE experimentation.conversion_events
    ADD INDEX idx_conversion_session (session_id) TYPE bloom_filter GRANULARITY 4;

-- =============================================================================
-- 3. KAFKA ENGINE TABLES (source tables for Kafka ingestion)
-- =============================================================================
-- These tables read directly from Kafka topics. Data is consumed and
-- inserted into the main tables via materialized views.
-- =============================================================================

CREATE TABLE experimentation.kafka_exposures
(
    event_id          String,
    idempotency_key   String,
    app_id            String,
    client_code       String,
    experiment_key    String,
    variation_key     String,
    timestamp         String,         -- ISO 8601 string, parsed in MV
    received_at       String,
    session_id        String,
    attr_platform     String,
    attr_app_version  String,
    attr_city         String,
    attr_segment      String,
    attributes        String,
    api_key_id        String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'b-1.msk-cluster.kafka.ap-south-1.amazonaws.com:9092,b-2.msk-cluster.kafka.ap-south-1.amazonaws.com:9092,b-3.msk-cluster.kafka.ap-south-1.amazonaws.com:9092',
    kafka_topic_list = 'exp.exposures',
    kafka_group_name = 'clickhouse_exposures_consumer',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 2,
    kafka_max_block_size = 65536;

CREATE TABLE experimentation.kafka_conversions
(
    event_id          String,
    idempotency_key   String,
    app_id            String,
    client_code       String,
    metric_key        String,
    value             Float64,
    timestamp         String,
    received_at       String,
    session_id        String,
    attr_platform     String,
    attr_app_version  String,
    attr_city         String,
    attr_segment      String,
    attributes        String,
    api_key_id        String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'b-1.msk-cluster.kafka.ap-south-1.amazonaws.com:9092,b-2.msk-cluster.kafka.ap-south-1.amazonaws.com:9092,b-3.msk-cluster.kafka.ap-south-1.amazonaws.com:9092',
    kafka_topic_list = 'exp.conversions',
    kafka_group_name = 'clickhouse_conversions_consumer',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 2,
    kafka_max_block_size = 65536;

-- =============================================================================
-- 4. MATERIALIZED VIEWS (Kafka → Main Tables)
-- =============================================================================

CREATE MATERIALIZED VIEW experimentation.mv_exposures TO experimentation.exposure_events AS
SELECT
    event_id,
    idempotency_key,
    app_id,
    client_code,
    experiment_key,
    variation_key,
    parseDateTime64BestEffort(timestamp, 3, 'Asia/Kolkata')  AS timestamp,
    parseDateTime64BestEffort(received_at, 3, 'Asia/Kolkata') AS received_at,
    session_id,
    attr_platform,
    attr_app_version,
    attr_city,
    attr_segment,
    attributes,
    api_key_id
FROM experimentation.kafka_exposures;

CREATE MATERIALIZED VIEW experimentation.mv_conversions TO experimentation.conversion_events AS
SELECT
    event_id,
    idempotency_key,
    app_id,
    client_code,
    metric_key,
    value,
    parseDateTime64BestEffort(timestamp, 3, 'Asia/Kolkata')  AS timestamp,
    parseDateTime64BestEffort(received_at, 3, 'Asia/Kolkata') AS received_at,
    session_id,
    attr_platform,
    attr_app_version,
    attr_city,
    attr_segment,
    attributes,
    api_key_id
FROM experimentation.kafka_conversions;

-- =============================================================================
-- 5. MATERIALIZED VIEWS FOR STATS ENGINE (Pre-Aggregations)
-- =============================================================================

-- Daily exposure counts per experiment per variation
CREATE MATERIALIZED VIEW experimentation.mv_daily_exposures
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (experiment_key, variation_key, day)
AS
SELECT
    experiment_key,
    variation_key,
    toDate(timestamp, 'Asia/Kolkata') AS day,
    uniqState(client_code)            AS unique_users_state,
    countState()                      AS exposure_count_state
FROM experimentation.exposure_events
GROUP BY experiment_key, variation_key, day;

-- Daily conversion aggregates per metric per variation
-- This view joins exposures and conversions to attribute conversions to experiment variants
CREATE MATERIALIZED VIEW experimentation.mv_daily_conversions
ENGINE = SummingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (experiment_key, variation_key, metric_key, day)
AS
SELECT
    e.experiment_key                  AS experiment_key,
    e.variation_key                   AS variation_key,
    c.metric_key                      AS metric_key,
    toDate(c.timestamp, 'Asia/Kolkata') AS day,
    uniqState(c.client_code)          AS converting_users_state,
    countState()                      AS conversion_count_state,
    sumState(c.value)                 AS value_sum_state,
    -- For variance calculation (continuous metrics)
    sumState(c.value * c.value)       AS value_squared_sum_state
FROM experimentation.conversion_events AS c
INNER JOIN experimentation.exposure_events AS e
    ON c.client_code = e.client_code
    AND c.timestamp >= e.timestamp
    AND c.timestamp <= e.timestamp + INTERVAL 30 DAY
GROUP BY experiment_key, variation_key, metric_key, day;

-- =============================================================================
-- 6. STATS ENGINE QUERY VIEWS (consumed by the API)
-- =============================================================================

-- Per-variation summary for binary metrics
CREATE VIEW experimentation.v_binary_metric_summary AS
SELECT
    experiment_key,
    variation_key,
    metric_key,
    uniqMerge(unique_users_state)      AS total_exposed_users,
    uniqMerge(converting_users_state)  AS converting_users,
    countMerge(conversion_count_state) AS total_conversions,
    -- Conversion rate = converting_users / total_exposed_users
    -- Computed in application layer to avoid division by zero
    sumMerge(value_sum_state)          AS total_value
FROM experimentation.mv_daily_conversions
GROUP BY experiment_key, variation_key, metric_key;

-- Per-variation summary for exposure counts
CREATE VIEW experimentation.v_exposure_summary AS
SELECT
    experiment_key,
    variation_key,
    uniqMerge(unique_users_state)  AS unique_users,
    countMerge(exposure_count_state) AS total_exposures
FROM experimentation.mv_daily_exposures
GROUP BY experiment_key, variation_key;

-- Time-series for results charts (daily granularity)
CREATE VIEW experimentation.v_daily_timeseries AS
SELECT
    experiment_key,
    variation_key,
    metric_key,
    day,
    uniqMerge(converting_users_state) AS daily_converting_users,
    countMerge(conversion_count_state) AS daily_conversions,
    sumMerge(value_sum_state) AS daily_value_sum,
    sumMerge(value_squared_sum_state) AS daily_value_squared_sum
FROM experimentation.mv_daily_conversions
GROUP BY experiment_key, variation_key, metric_key, day
ORDER BY day;

-- =============================================================================
-- 7. EXAMPLE STATS QUERIES (used by the Node.js stats engine module)
-- =============================================================================

-- EXAMPLE 1: Binary metric comparison (two-proportion z-test inputs)
-- Returns data needed to compute z-statistic and p-value in application layer
/*
SELECT
    variation_key,
    total_exposed_users,
    converting_users,
    converting_users / total_exposed_users AS conversion_rate
FROM experimentation.v_binary_metric_summary
WHERE experiment_key = 'new_chart_ui'
  AND metric_key = 'order_placed';
*/

-- EXAMPLE 2: Continuous metric comparison (Welch's t-test inputs)
-- Returns data needed to compute t-statistic and p-value in application layer
/*
SELECT
    e.variation_key,
    e.unique_users AS n,
    c.total_value / c.total_conversions AS mean_value,
    -- Variance = E[X²] - (E[X])²
    (c.total_value_squared / c.total_conversions) - pow(c.total_value / c.total_conversions, 2) AS variance
FROM experimentation.v_exposure_summary AS e
LEFT JOIN (
    SELECT
        experiment_key,
        variation_key,
        metric_key,
        sumMerge(value_sum_state) AS total_value,
        sumMerge(value_squared_sum_state) AS total_value_squared,
        countMerge(conversion_count_state) AS total_conversions
    FROM experimentation.mv_daily_conversions
    WHERE experiment_key = 'order_flow_v2'
      AND metric_key = 'order_value'
    GROUP BY experiment_key, variation_key, metric_key
) AS c ON e.experiment_key = c.experiment_key AND e.variation_key = c.variation_key
WHERE e.experiment_key = 'order_flow_v2';
*/

-- EXAMPLE 3: Time-series for results chart
/*
SELECT
    day,
    variation_key,
    daily_converting_users,
    daily_conversions,
    daily_value_sum
FROM experimentation.v_daily_timeseries
WHERE experiment_key = 'new_chart_ui'
  AND metric_key = 'order_placed'
ORDER BY day, variation_key;
*/
