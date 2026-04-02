# CLAUDE.md — Data Plane Module (ClickHouse, Kafka, Stats Engine)

> **This file is read automatically by Claude Code** when working in the `/data` directory.
> Read the root `/CLAUDE.md` first for project-wide conventions.

---

## What This Module Is

The data plane handles event ingestion, storage, and statistical analysis. It consists of:

1. **Kafka consumer** — reads events from Kafka topics, writes to ClickHouse (if not using ClickHouse's native Kafka engine)
2. **ClickHouse schema and migrations** — table definitions, materialized views, pre-aggregations
3. **Stats engine** — TypeScript module that queries ClickHouse and computes statistical test results

The event ingestion API itself lives in `/backend` (it's an Express route). This module owns everything from Kafka onwards.

---

## Module Structure

```
data/
├── CLAUDE.md                              ← you are here
├── clickhouse/
│   ├── migrations/
│   │   ├── 001_create_exposure_events.sql
│   │   ├── 002_create_conversion_events.sql
│   │   ├── 003_create_kafka_engines.sql
│   │   ├── 004_create_materialized_views.sql
│   │   └── 005_create_stats_views.sql
│   └── seed/
│       └── sample_events.sql              ← test data for local development
├── kafka/
│   ├── topics.json                        ← topic creation config (used by setup scripts)
│   └── consumer/
│       ├── index.ts                       ← Kafka consumer entry point (if not using CH Kafka engine)
│       ├── exposure-handler.ts
│       └── conversion-handler.ts
├── stats/
│   ├── engine.ts                          ← main StatsEngine class
│   ├── queries/
│   │   ├── binary-metric.query.ts         ← SQL + computation for binary metrics
│   │   ├── continuous-metric.query.ts     ← SQL + computation for continuous metrics
│   │   ├── timeseries.query.ts            ← daily time-series data
│   │   └── exposure-summary.query.ts      ← per-variation exposure counts
│   ├── math/
│   │   ├── t-test.ts                      ← Welch's t-test implementation
│   │   ├── z-test.ts                      ← two-proportion z-test
│   │   ├── confidence-interval.ts         ← CI computation
│   │   ├── sample-size.ts                 ← sample size calculator
│   │   ├── mde.ts                         ← minimum detectable effect
│   │   └── normal-distribution.ts         ← CDF/inverse CDF for p-value computation
│   ├── models/
│   │   └── results.model.ts              ← TypeScript types for results
│   └── __tests__/
│       ├── t-test.test.ts
│       ├── z-test.test.ts
│       ├── confidence-interval.test.ts
│       ├── sample-size.test.ts
│       └── engine.integration.test.ts
├── docker-compose.yml                     ← local ClickHouse + Kafka for dev/test
└── scripts/
    ├── setup-kafka-topics.sh
    ├── run-clickhouse-migrations.sh
    └── generate-test-events.ts            ← synthetic event generator for load testing
```

---

## ClickHouse Schema Reference

Full DDL is in `architecture/schemas/clickhouse_schema.sql`. Key tables:

| Table | Engine | Partition | Order By | Purpose |
|---|---|---|---|---|
| `exposure_events` | ReplacingMergeTree(received_at) | `toYYYYMM(timestamp)` | `(experiment_key, client_code, timestamp)` | Raw exposure events |
| `conversion_events` | ReplacingMergeTree(received_at) | `toYYYYMM(timestamp)` | `(metric_key, client_code, timestamp)` | Raw conversion events |
| `kafka_exposures` | Kafka | — | — | Kafka engine source for exposures |
| `kafka_conversions` | Kafka | — | — | Kafka engine source for conversions |
| `mv_daily_exposures` | SummingMergeTree | `toYYYYMM(day)` | `(experiment_key, variation_key, day)` | Pre-aggregated daily exposure counts |
| `mv_daily_conversions` | SummingMergeTree | `toYYYYMM(day)` | `(experiment_key, variation_key, metric_key, day)` | Pre-aggregated daily conversion stats |

**Important ClickHouse behaviors to understand:**
- `ReplacingMergeTree` deduplicates on the ORDER BY key during background merges — not guaranteed to be immediate. Use `FINAL` keyword for exact dedup in queries if needed.
- `SummingMergeTree` pre-aggregates during merges using AggregateFunction columns (`uniqState`, `countState`, `sumState`). Read with `uniqMerge`, `countMerge`, `sumMerge`.
- Materialized views are INSERT triggers — they process data as it arrives, not retroactively.
- TTL: both event tables have `TTL timestamp + INTERVAL 1 YEAR` — data auto-expires.

---

## Kafka Topics Reference

Full config is in `architecture/schemas/KAFKA_TOPICS.md`.

| Topic | Partition Key | Partitions | Message Format |
|---|---|---|---|
| `exp.exposures` | `experimentKey` | 8 | JSON (one event per message) |
| `exp.conversions` | `clientCode` | 8 | JSON (one event per message) |

**Event message schema (Kafka):**

Exposure:
```json
{
  "event_id": "UUID",
  "idempotency_key": "string",
  "app_id": "string",
  "client_code": "string",
  "experiment_key": "string",
  "variation_key": "string",
  "timestamp": "ISO8601",
  "received_at": "ISO8601",
  "session_id": "string",
  "attr_platform": "string",
  "attr_app_version": "string",
  "attr_city": "string",
  "attr_segment": "string",
  "attributes": "JSON string",
  "api_key_id": "string"
}
```

Conversion:
```json
{
  "event_id": "UUID",
  "idempotency_key": "string",
  "app_id": "string",
  "client_code": "string",
  "metric_key": "string",
  "value": 1.0,
  "timestamp": "ISO8601",
  "received_at": "ISO8601",
  "session_id": "string",
  "attr_platform": "string",
  "attr_app_version": "string",
  "attr_city": "string",
  "attr_segment": "string",
  "attributes": "JSON string",
  "api_key_id": "string"
}
```

---

## Stats Engine — Frequentist (Phase 1)

### Architecture

The stats engine is a TypeScript module (not a separate service). It is imported by the backend's `results.routes.ts` and called when a PM views experiment results.

```
Dashboard → Backend API (GET /api/v1/experiments/:id/results)
                → StatsEngine.computeResults(experimentId, metricId)
                    → Query ClickHouse (aggregated data from MVs)
                    → Compute test statistic, p-value, CI in TypeScript
                    → Return structured results
```

### Binary Metrics (Two-Proportion Z-Test)

For metrics like "order_placed" where value is 0 or 1:

```
Input (from ClickHouse per variation):
  n    = number of unique exposed users
  x    = number of converting users
  p    = x / n  (conversion rate)

Test: Two-proportion z-test (control vs treatment)
  p_pool = (x_c + x_t) / (n_c + n_t)
  se     = sqrt(p_pool * (1 - p_pool) * (1/n_c + 1/n_t))
  z      = (p_t - p_c) / se
  p_value = 2 * (1 - Φ(|z|))       // two-tailed

Where Φ is the standard normal CDF.

Confidence interval for the difference (p_t - p_c):
  se_diff = sqrt(p_c*(1-p_c)/n_c + p_t*(1-p_t)/n_t)
  CI = (p_t - p_c) ± z_α/2 * se_diff     // z_α/2 = 1.96 for 95% CI

Relative lift:
  lift = (p_t - p_c) / p_c
  lift_CI = CI / p_c
```

### Continuous Metrics (Welch's T-Test)

For metrics like "order_value" where value is a continuous number:

```
Input (from ClickHouse per variation):
  n     = count of observations
  mean  = sum(value) / n
  var   = sum(value²)/n - mean²    // population variance
  s²    = var * n / (n-1)          // sample variance (Bessel's correction)

Test: Welch's t-test (does not assume equal variances)
  t = (mean_t - mean_c) / sqrt(s²_t/n_t + s²_c/n_c)

Degrees of freedom (Welch-Satterthwaite):
  df = (s²_t/n_t + s²_c/n_c)² / ((s²_t/n_t)²/(n_t-1) + (s²_c/n_c)²/(n_c-1))

p_value = 2 * (1 - T_cdf(|t|, df))   // two-tailed, Student's t CDF

Confidence interval for difference in means:
  se_diff = sqrt(s²_t/n_t + s²_c/n_c)
  CI = (mean_t - mean_c) ± t_α/2(df) * se_diff
```

### Normal Distribution CDF

Implement using the rational approximation (Abramowitz and Stegun, formula 26.2.17) or use a well-tested npm package like `jstat`. Do NOT use a naive Taylor series — it's inaccurate in the tails.

### Student's T-Distribution CDF

Use the regularized incomplete beta function. This is mathematically complex — use `jstat` or implement the continued fraction approximation from Numerical Recipes.

### Sample Size Calculator

```
For binary metrics:
  n = (z_α/2 + z_β)² * (p_c*(1-p_c) + p_t*(1-p_t)) / (p_t - p_c)²
  
  Where:
    z_α/2 = 1.96 (for α = 0.05)
    z_β   = 0.84 (for 80% power) or 1.28 (for 90% power)
    p_c   = expected control conversion rate
    p_t   = p_c + MDE (minimum detectable effect)

For continuous metrics:
  n = (z_α/2 + z_β)² * 2 * σ² / δ²
  
  Where:
    σ² = expected variance
    δ  = minimum detectable difference in means
```

### Winner Declaration Logic

An experiment declares a winner when ALL of these conditions are met:
1. Primary metric's p-value < α (default α = 0.05)
2. Sample size per variation >= minimum required (from sample size calculator)
3. Experiment has been running for at least 7 days (prevent early peeking artifacts)
4. No guardrail metrics show statistically significant regression

If conditions 1–3 are met but condition 4 fails, show "Winner found but guardrail regression detected" warning.

---

## ClickHouse Query Patterns

**Always query the pre-aggregated materialized views** (`mv_daily_exposures`, `mv_daily_conversions`) instead of the raw event tables. The MVs are 100–1000× faster for aggregation queries.

**Binary metric query:**
```sql
SELECT
    variation_key,
    uniqMerge(unique_users_state)     AS n,
    uniqMerge(converting_users_state) AS x
FROM experimentation.mv_daily_conversions
WHERE experiment_key = {experimentKey: String}
  AND metric_key = {metricKey: String}
GROUP BY variation_key
```

**Continuous metric query:**
```sql
SELECT
    variation_key,
    countMerge(conversion_count_state)    AS n,
    sumMerge(value_sum_state)             AS sum_value,
    sumMerge(value_squared_sum_state)     AS sum_value_squared
FROM experimentation.mv_daily_conversions
WHERE experiment_key = {experimentKey: String}
  AND metric_key = {metricKey: String}
GROUP BY variation_key
```

Then compute `mean = sum_value / n` and `variance = sum_value_squared/n - mean²` in TypeScript.

**Time-series query:**
```sql
SELECT
    day,
    variation_key,
    uniqMerge(converting_users_state) AS daily_conversions,
    sumMerge(value_sum_state)         AS daily_value
FROM experimentation.mv_daily_conversions
WHERE experiment_key = {experimentKey: String}
  AND metric_key = {metricKey: String}
GROUP BY day, variation_key
ORDER BY day ASC
```

**Always use parameterized queries** with ClickHouse's `{param: Type}` syntax — never string concatenation.

---

## Test Requirements

- **Unit tests for math module:** Validate t-test, z-test, CI, p-value, sample size calculations against known statistical tables / scipy reference values. At least 10 test cases per function covering edge cases (small n, large n, equal proportions, extreme values).
- **Integration test for stats engine:** Insert known events into a test ClickHouse instance, run the stats engine, verify computed results match hand-calculated values.
- **Load test script:** `generate-test-events.ts` creates synthetic events (configurable volume) and pushes to Kafka. Verify ClickHouse ingestion throughput and query latency.
- **Coverage target:** 95%+ for the math module (statistical correctness is critical).

---

## What NOT To Do in This Module

- **Never query raw event tables for stats** — always use materialized views
- **Never implement stats in SQL** — ClickHouse provides aggregates, TypeScript computes test statistics (more testable, more readable)
- **Never use floating-point equality checks** in tests — use `expect(value).toBeCloseTo(expected, 5)` for statistical values
- **Never skip Bessel's correction** — use `n-1` for sample variance, not `n`
- **Never declare a winner before minimum sample size** — even if p-value is tiny
- **Never hardcode Kafka broker addresses** — use environment variables
- **Never modify ClickHouse schema without a numbered migration file** — schema changes must be versioned and reproducible
- **Never write to ClickHouse from the Node.js application** — all writes go through Kafka
