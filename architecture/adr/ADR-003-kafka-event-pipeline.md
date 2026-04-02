# ADR-003: Kafka Between Event Ingestion and ClickHouse

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** Data Pipeline

---

## Context

The platform ingests two types of events at high volume: exposure events (user was shown a variant) and conversion events (user performed a target action). These events must flow from the Riise app (via the Event Ingestion API) into ClickHouse for analysis.

With 40L+ users and peak trading hours, event volume can spike dramatically. During market open (9:15 AM IST), event rates could increase 10–50× compared to off-peak. The ingestion pipeline must handle these spikes without dropping events or overwhelming ClickHouse.

## Decision

**We place Apache Kafka (AWS MSK) between the Event Ingestion API and ClickHouse.** The API publishes events to Kafka topics. A separate consumer process (or ClickHouse's native Kafka engine) reads from Kafka and writes to ClickHouse.

Two topics:
- `exp.exposures` — partitioned by `experiment_id` (8 partitions initially)
- `exp.conversions` — partitioned by `experiment_id` (8 partitions initially)

## Rationale

| Factor | Direct Write to ClickHouse | Kafka → ClickHouse |
|---|---|---|
| Spike handling | ClickHouse must absorb all spikes | Kafka buffers, ClickHouse consumes at steady rate |
| Durability | If ClickHouse is down, events are lost | Kafka retains events for 7 days |
| Backpressure | API must wait for ClickHouse write | API returns immediately after Kafka publish |
| Ingestion latency (API response) | 10–50ms (ClickHouse write) | 2–5ms (Kafka publish) |
| Operational complexity | Lower | Higher (MSK cluster to manage) |
| Replay capability | None | Full replay from any offset |

The 40L user scale with trading-hours spikes makes Kafka essential. Without it, a ClickHouse maintenance window or temporary overload would cause data loss.

**Partitioning by `experiment_id`:** ensures all events for a given experiment land on the same partition, enabling ordered processing per experiment. 8 partitions is sufficient for Phase 1 throughput (each partition handles ~1,250 events/sec at our target of 10K/sec total).

## Consequences

**Positive:**
- Event Ingestion API response time is fast and consistent (~5ms)
- ClickHouse is protected from write spikes
- Events are durable — Kafka retains for 7 days even if ClickHouse is temporarily unavailable
- Replay capability: if ClickHouse schema changes, we can replay events from Kafka
- Consumer can batch inserts for ClickHouse efficiency

**Negative:**
- Added infrastructure cost (MSK cluster: 3 brokers)
- Events are eventually consistent — a few seconds delay before they appear in ClickHouse
- Operational overhead of Kafka cluster management
- Additional failure mode (Kafka broker failure)

**Mitigations:**
- AWS MSK is fully managed — reduces operational burden
- Multi-AZ MSK deployment for broker failure resilience
- A few seconds of event delay is completely acceptable for A/B test analysis (results are viewed hours/days later)
- Consumer lag monitoring with alerting

## Alternatives Considered

1. **Direct ClickHouse inserts from API:** Simpler architecture, but no spike buffering, no durability if ClickHouse is down. Rejected for reliability concerns at scale.

2. **SQS instead of Kafka:** Lower operational overhead, but no ordering guarantees, no replay capability, higher per-message cost at our volume. Rejected because Kafka's ordering and replay are valuable.

3. **Kinesis Data Streams:** AWS-native alternative to Kafka. Rejected because MSK provides standard Kafka compatibility (important if we ever need Kafka Connect, Schema Registry, etc.) and our team's familiarity with Kafka ecosystem.
