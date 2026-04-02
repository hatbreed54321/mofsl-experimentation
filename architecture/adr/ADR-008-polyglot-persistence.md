# ADR-008: PostgreSQL + ClickHouse Polyglot Persistence

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** Data Architecture

---

## Context

The platform has two fundamentally different data patterns:

1. **Transactional data:** Experiments, flags, variations, targeting rules, eligibility lists, audit logs. Low write volume, high consistency requirements, complex relational queries (JOINs), frequent updates.

2. **Analytical data:** Exposure events and conversion events. Very high write volume (10K events/sec peak), append-only, no updates, analytical queries (aggregations, GROUP BY, time-series) across hundreds of millions of rows.

No single database excels at both patterns. Attempting to serve both from one database would force compromises that degrade either the management experience or the analytics performance.

## Decision

**We use PostgreSQL (AWS RDS) for transactional data and ClickHouse for analytical data.** Each database is used exclusively for the workload it is optimized for. There is no cross-database querying — the application layer joins data when needed (e.g., experiment metadata from PostgreSQL + event aggregations from ClickHouse for the results page).

## Rationale

**PostgreSQL for transactional data:**
- ACID transactions for experiment state changes (Draft → Running must be atomic)
- Foreign keys enforce data integrity (variation belongs to experiment)
- Complex JOINs for config generation (experiments + variations + targeting rules + eligibility)
- Row-level updates for experiment state, flag values, targeting rules
- Mature ecosystem, widely understood, excellent AWS RDS support

**ClickHouse for analytical data:**
- Columnar storage: aggregation queries scan only the columns needed
- 10–100× faster than PostgreSQL for analytical queries at event scale
- MergeTree engine with automatic data compression (10:1 typical for event data)
- Built-in TTL for automatic data expiration
- Native Kafka engine for direct ingestion from Kafka topics
- Handles hundreds of millions of rows without performance degradation

**Why not a single database:**

| Approach | Problem |
|---|---|
| PostgreSQL for everything | Event table grows to billions of rows; analytical queries become unusably slow; write throughput insufficient for 10K events/sec |
| ClickHouse for everything | No ACID transactions; no foreign keys; no efficient row-level updates; poor at JOINs on small relational tables |
| TimescaleDB (PostgreSQL extension) | Better than plain PostgreSQL for time-series, but still row-oriented — cannot match ClickHouse's columnar performance for aggregations at scale |

## Consequences

**Positive:**
- Each database is used for its optimal workload
- Config generation queries (PostgreSQL) are fast because the table sizes are small (thousands of rows, not millions)
- Stats queries (ClickHouse) are fast because columnar storage is purpose-built for aggregations
- Clear separation: transactional writes never compete with analytical reads

**Negative:**
- Two databases to operate, monitor, and back up
- Application-level joins needed for the results page (experiment metadata + event aggregations)
- Team must learn ClickHouse SQL dialect and operational patterns
- Data consistency between PostgreSQL and ClickHouse is eventually consistent (experiment metadata in PostgreSQL, events in ClickHouse)

**Mitigations:**
- ClickHouse is self-managing for most operations (auto-merge, auto-TTL); operational overhead is low
- Application-level join is simple: fetch experiment from PostgreSQL, fetch aggregations from ClickHouse, merge in Node.js
- ClickHouse SQL is very close to standard SQL — learning curve is modest

## Alternatives Considered

1. **PostgreSQL only:** Simpler to operate but would require partitioning, careful indexing, and would still struggle at 100M+ event rows for analytical queries. Rejected for performance reasons.

2. **ClickHouse only:** Handles both patterns in theory, but ClickHouse's lack of ACID transactions and poor UPDATE performance make it unsuitable for experiment management. Rejected.

3. **PostgreSQL + BigQuery/Redshift:** Cloud data warehouses could replace ClickHouse. Rejected because they are more expensive, higher latency for interactive queries, and less suitable for real-time event ingestion.

4. **MongoDB:** Could handle both transactional and semi-structured event data. Rejected because it excels at neither — worse transactional guarantees than PostgreSQL, worse analytical performance than ClickHouse.
