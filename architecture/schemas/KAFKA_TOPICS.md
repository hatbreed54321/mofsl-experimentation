# Kafka Topics Design

> **Cluster:** AWS MSK (ap-south-1)
> **Brokers:** 3 × kafka.m5.large (multi-AZ)
> **Replication Factor:** 3 (all topics)
> **Default Retention:** 7 days

---

## 1. Topic Inventory

| Topic | Purpose | Partition Key | Partitions | Retention |
|---|---|---|---|---|
| `exp.exposures` | Exposure events (user saw a variant) | `experimentKey` | 8 | 7 days |
| `exp.conversions` | Conversion events (user performed action) | `clientCode` | 8 | 7 days |

---

## 2. Topic Details

### `exp.exposures`

**Purpose:** Carries exposure events from the Event Ingestion API to ClickHouse.

**Partition key:** `experimentKey` — all exposure events for a given experiment are on the same partition. This ensures:
- Ordered processing per experiment (exposure timestamps are preserved in order)
- Efficient ClickHouse batch inserts grouped by experiment
- Consumer parallelism: different experiments can be processed in parallel across partitions

**Message format:** JSON (one message per event)

```json
{
  "event_id": "550e8400-e29b-41d4-a716-446655440000",
  "idempotency_key": "exp_AB1234_new_chart_ui_sess_a1b2c3d4",
  "app_id": "riise",
  "client_code": "AB1234",
  "experiment_key": "new_chart_ui",
  "variation_key": "treatment",
  "timestamp": "2026-04-01T10:30:00.000+05:30",
  "received_at": "2026-04-01T10:30:00.250+05:30",
  "session_id": "sess_a1b2c3d4",
  "attr_platform": "android",
  "attr_app_version": "5.2.1",
  "attr_city": "Mumbai",
  "attr_segment": "premium",
  "attributes": "{\"platform\":\"android\",\"app_version\":\"5.2.1\",\"city\":\"Mumbai\",\"segment\":\"premium\"}",
  "api_key_id": "key_riise_prod_001"
}
```

**Throughput estimate:**
- Average: 2,000 messages/sec
- Peak (market open): 10,000 messages/sec
- Average message size: ~500 bytes
- Daily volume: ~170M messages (~85 GB uncompressed)

### `exp.conversions`

**Purpose:** Carries conversion events from the Event Ingestion API to ClickHouse.

**Partition key:** `clientCode` — all conversion events for a given user are on the same partition. This ensures:
- All of a user's conversions can be processed in order
- Enables per-user deduplication at the consumer level if needed
- Different partition key from exposures (conversions are not tied to a specific experiment at ingestion time)

**Message format:** JSON (one message per event)

```json
{
  "event_id": "660e8400-e29b-41d4-a716-446655440001",
  "idempotency_key": "conv_AB1234_order_placed_1711961722000",
  "app_id": "riise",
  "client_code": "AB1234",
  "metric_key": "order_placed",
  "value": 1,
  "timestamp": "2026-04-01T10:35:22.000+05:30",
  "received_at": "2026-04-01T10:35:22.150+05:30",
  "session_id": "sess_a1b2c3d4",
  "attr_platform": "android",
  "attr_app_version": "5.2.1",
  "attr_city": "Mumbai",
  "attr_segment": "premium",
  "attributes": "{\"platform\":\"android\",\"app_version\":\"5.2.1\",\"city\":\"Mumbai\",\"segment\":\"premium\"}",
  "api_key_id": "key_riise_prod_001"
}
```

**Throughput estimate:**
- Average: 1,000 messages/sec
- Peak (market open): 5,000 messages/sec
- Average message size: ~450 bytes
- Daily volume: ~85M messages (~38 GB uncompressed)

---

## 3. Partitioning Strategy

**8 partitions per topic** for Phase 1.

Rationale:
- At 10K messages/sec peak, each partition handles ~1,250 msg/sec — well within Kafka's per-partition capacity
- 8 partitions allow up to 8 parallel consumers (aligns with ClickHouse Kafka engine's `kafka_num_consumers = 2` initially, scalable to 8)
- Partition count can be increased later (Kafka supports adding partitions) but not decreased — starting with 8 provides headroom

**Partition assignment:**
- `exp.exposures`: `hash(experimentKey) % 8`
- `exp.conversions`: `hash(clientCode) % 8`

Kafka's default partitioner (murmur2 hash of the key bytes) is used. No custom partitioner.

---

## 4. Consumer Groups

| Consumer Group | Topic(s) | Purpose | Instances |
|---|---|---|---|
| `clickhouse_exposures_consumer` | `exp.exposures` | ClickHouse Kafka engine (or dedicated consumer) writes to `exposure_events` table | 2 (scalable to 8) |
| `clickhouse_conversions_consumer` | `exp.conversions` | ClickHouse Kafka engine (or dedicated consumer) writes to `conversion_events` table | 2 (scalable to 8) |

**Consumer configuration:**
- `auto.offset.reset = earliest` — process all unprocessed events on startup
- `enable.auto.commit = false` — commit offsets after successful write to ClickHouse
- `max.poll.records = 10000` — batch size for ClickHouse inserts (ClickHouse prefers large batches)
- `session.timeout.ms = 30000`
- `heartbeat.interval.ms = 10000`

---

## 5. Producer Configuration

The Event Ingestion API is the sole producer for both topics.

| Setting | Value | Reason |
|---|---|---|
| `acks` | `all` | Wait for all replicas to acknowledge — no data loss |
| `retries` | `3` | Retry transient failures |
| `retry.backoff.ms` | `100` | Backoff between retries |
| `compression.type` | `lz4` | Fast compression, good ratio for JSON payloads |
| `batch.size` | `65536` (64 KB) | Batch messages for throughput |
| `linger.ms` | `5` | Wait up to 5ms to fill batches |
| `max.in.flight.requests.per.connection` | `5` | Allows pipelining while maintaining ordering with idempotent producer |
| `enable.idempotence` | `true` | Prevents duplicate messages from producer retries |

---

## 6. Broker Configuration (MSK)

| Setting | Value | Reason |
|---|---|---|
| `default.replication.factor` | `3` | All replicas on different AZs |
| `min.insync.replicas` | `2` | Write succeeds if 2 of 3 replicas acknowledge |
| `log.retention.hours` | `168` (7 days) | Retain events for replay capability |
| `log.retention.bytes` | `-1` (unlimited) | Rely on time-based retention only |
| `log.segment.bytes` | `1073741824` (1 GB) | Standard segment size |
| `message.max.bytes` | `1048576` (1 MB) | Max message size (individual events are ~500 bytes; this allows batch messages if needed in future) |
| `auto.create.topics.enable` | `false` | Topics are created explicitly, not auto-created |

---

## 7. Monitoring & Alerting

| Metric | Alert Threshold | Description |
|---|---|---|
| Consumer lag (per group) | > 100,000 messages | Consumer falling behind producer; ClickHouse may be overloaded |
| Under-replicated partitions | > 0 | Broker failure or replication issue |
| ISR shrink rate | > 0 sustained | Replicas falling out of sync |
| Broker disk usage | > 80% | Risk of data loss if disk fills |
| Producer error rate | > 1% | Event Ingestion API failing to publish |
| Consumer error rate | > 1% | ClickHouse write failures |

All metrics available via MSK CloudWatch integration.

---

## 8. Scaling Plan

| Trigger | Action |
|---|---|
| Consumer lag > 100K sustained for 30 min | Increase consumer instances (up to partition count) |
| Per-partition throughput > 3K msg/sec | Add partitions (irreversible — plan carefully) |
| Broker disk > 70% | Increase broker storage or reduce retention |
| Need for new event types (Phase 2) | Add new topics rather than overloading existing ones |

---

## 9. Future Topics (Phase 2)

| Topic | Purpose | Trigger |
|---|---|---|
| `exp.config-changes` | Real-time config change notifications for SSE streaming | Phase 2 SSE feature |
| `exp.audit` | Audit log events for async processing | If audit volume grows |
