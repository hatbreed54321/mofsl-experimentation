# Event Ingestion API Contract

> **Owner:** Platform Team
> **Consumers:** Riise App (via `onExposure` callback implementation), Riise Backend (for server-side conversion events), Future MOFSL products
> **Base URL:** `https://experiments.mofsl.com`
> **Authentication:** API Key in `X-API-Key` header
> **Protocol:** HTTPS, REST, JSON

---

## 1. Ingest Events (Batch)

The primary endpoint for sending exposure and conversion events. Supports batching — clients should batch events and send periodically rather than firing one HTTP request per event.

### Request

```
POST /api/v1/events
```

**Headers:**

| Header | Required | Description |
|---|---|---|
| `X-API-Key` | Yes | Application API key (same key as config server) |
| `Content-Type` | Yes | `application/json` |
| `Content-Encoding` | No | `gzip` if payload is compressed |

**Body:**

```json
{
  "events": [
    {
      "type": "exposure",
      "clientCode": "AB1234",
      "experimentKey": "new_chart_ui",
      "variationKey": "treatment",
      "timestamp": "2026-04-01T10:30:00.000Z",
      "attributes": {
        "platform": "android",
        "app_version": "5.2.1",
        "city": "Mumbai",
        "segment": "premium"
      },
      "sessionId": "sess_a1b2c3d4",
      "idempotencyKey": "exp_AB1234_new_chart_ui_sess_a1b2c3d4"
    },
    {
      "type": "conversion",
      "clientCode": "AB1234",
      "metricKey": "order_placed",
      "value": 1,
      "timestamp": "2026-04-01T10:35:22.000Z",
      "attributes": {
        "platform": "android",
        "app_version": "5.2.1",
        "city": "Mumbai",
        "segment": "premium"
      },
      "sessionId": "sess_a1b2c3d4",
      "idempotencyKey": "conv_AB1234_order_placed_1711961722000"
    },
    {
      "type": "conversion",
      "clientCode": "AB1234",
      "metricKey": "order_value",
      "value": 15000.50,
      "timestamp": "2026-04-01T10:35:22.000Z",
      "attributes": {
        "platform": "android",
        "app_version": "5.2.1"
      },
      "sessionId": "sess_a1b2c3d4",
      "idempotencyKey": "conv_AB1234_order_value_1711961722000"
    }
  ]
}
```

### Event Field Reference

**Common fields (all event types):**

| Field | Type | Required | Description |
|---|---|---|---|
| `type` | string | Yes | Event type: `"exposure"` or `"conversion"` |
| `clientCode` | string | Yes | MOFSL client code identifying the user |
| `timestamp` | string (ISO 8601) | Yes | Client-side timestamp when the event occurred |
| `attributes` | object | No | User attributes at the time of the event. Free-form key-value pairs. |
| `sessionId` | string | No | Client-side session identifier. Useful for deduplication and session analysis. |
| `idempotencyKey` | string | No | Unique key for deduplication. If provided, the platform will deduplicate events with the same key within a 24-hour window. |

**Exposure event fields (in addition to common):**

| Field | Type | Required | Description |
|---|---|---|---|
| `experimentKey` | string | Yes | The experiment that the user was exposed to |
| `variationKey` | string | Yes | The variation that the user was assigned to |

**Conversion event fields (in addition to common):**

| Field | Type | Required | Description |
|---|---|---|---|
| `metricKey` | string | Yes | The metric being tracked (e.g., `"order_placed"`, `"order_value"`, `"session_duration"`) |
| `value` | number | Yes | Metric value. For binary metrics, use `1` (converted) or `0` (not converted). For continuous metrics, use the actual value (e.g., order amount in rupees). |

### Response — 202 Accepted

Events successfully received and queued for processing. Events are not yet in ClickHouse — they are in Kafka.

```json
{
  "status": "accepted",
  "eventsReceived": 3,
  "eventsDropped": 0,
  "timestamp": "2026-04-01T10:35:25.000Z"
}
```

### Response — 207 Multi-Status

Some events accepted, some rejected (validation errors).

```json
{
  "status": "partial",
  "eventsReceived": 2,
  "eventsDropped": 1,
  "errors": [
    {
      "index": 1,
      "error": "validation_error",
      "message": "metricKey is required for conversion events"
    }
  ],
  "timestamp": "2026-04-01T10:35:25.000Z"
}
```

### Response — 400 Bad Request

Entire batch rejected due to malformed request.

```json
{
  "error": "bad_request",
  "message": "Request body must contain an 'events' array"
}
```

### Response — 401 Unauthorized

```json
{
  "error": "unauthorized",
  "message": "Invalid or missing API key"
}
```

### Response — 413 Payload Too Large

```json
{
  "error": "payload_too_large",
  "message": "Batch exceeds maximum of 1000 events"
}
```

### Response — 429 Too Many Requests

```json
{
  "error": "rate_limited",
  "message": "Too many requests",
  "retryAfter": 10
}
```

---

## 2. Validation Rules

The server validates every event before publishing to Kafka. Invalid events are dropped (not published) and reported in the response.

| Rule | Error |
|---|---|
| `type` must be `"exposure"` or `"conversion"` | `invalid_event_type` |
| `clientCode` must be a non-empty string, max 50 chars | `invalid_client_code` |
| `timestamp` must be valid ISO 8601, not more than 24 hours in the past or future | `invalid_timestamp` |
| For exposure: `experimentKey` must be non-empty, max 100 chars | `missing_experiment_key` |
| For exposure: `variationKey` must be non-empty, max 100 chars | `missing_variation_key` |
| For conversion: `metricKey` must be non-empty, max 100 chars | `missing_metric_key` |
| For conversion: `value` must be a finite number | `invalid_value` |
| `attributes` values must be strings, numbers, or booleans (no nested objects) | `invalid_attributes` |
| Batch size must be 1–1000 events | `invalid_batch_size` |

---

## 3. Server-Side Enrichment

Before publishing to Kafka, the server enriches each event:

| Field | Description |
|---|---|
| `receivedAt` | Server timestamp (ISO 8601) when the event was received |
| `apiKeyId` | Identifier of the API key that sent the event (for audit) |
| `eventId` | Server-generated UUID for each event |
| `appId` | Application identifier derived from the API key (e.g., `"riise"`) |

These enriched fields are included in the Kafka message but are not returned in the API response.

---

## 4. Kafka Topic Mapping

| Event Type | Kafka Topic | Partition Key |
|---|---|---|
| `exposure` | `exp.exposures` | `experimentKey` |
| `conversion` | `exp.conversions` | `experimentKey` |

**Partition key = `experimentKey`** ensures all events for a given experiment are on the same partition, enabling ordered processing per experiment.

**Note for conversion events:** Conversions are partitioned by `metricKey` since they are not tied to a specific experiment at ingestion time. The stats engine joins conversions to experiments at query time based on `clientCode` and time window.

*Correction:* Conversion events do not have an `experimentKey`. They are partitioned by a hash of `clientCode` to distribute load evenly while keeping all events for a given user on the same partition for ordered processing.

**Revised mapping:**

| Event Type | Kafka Topic | Partition Key |
|---|---|---|
| `exposure` | `exp.exposures` | `experimentKey` |
| `conversion` | `exp.conversions` | `clientCode` |

---

## 5. Deduplication

**Client-side deduplication (recommended):** The SDK should fire exposure events only once per experiment per session. The Riise team's `onExposure` implementation should enforce this.

**Server-side deduplication:** If `idempotencyKey` is provided, the server maintains a 24-hour deduplication window in Redis. Events with the same `idempotencyKey` within this window are silently dropped (still return `202`).

**ClickHouse-side deduplication:** ClickHouse's `ReplacingMergeTree` with `(event_id)` as the dedup key provides eventual deduplication at the storage layer as a final safety net.

---

## 6. Batching Recommendations

| Parameter | Recommendation |
|---|---|
| Batch size | 10–100 events per request |
| Flush interval | Every 30 seconds or when batch reaches 100 events |
| Max batch size | 1,000 events (server-enforced) |
| Retry policy | Exponential backoff: 1s, 2s, 4s, 8s, max 3 retries |
| Compression | Enable gzip for batches > 10 events |

These are recommendations for the Riise team's event transport implementation, not enforced by the server.

---

## 7. Rate Limits

| Scope | Limit | Window |
|---|---|---|
| Per API key | 1,000 requests | Per minute |
| Per API key (events/sec) | 10,000 events | Per second |
| Global | 50,000 events | Per second |

---

## 8. Event Flow Diagram

```
Riise App                    Event Ingestion API          Kafka              ClickHouse
   │                               │                       │                    │
   │  POST /api/v1/events          │                       │                    │
   │  (batch of N events)          │                       │                    │
   │──────────────────────────────▶│                       │                    │
   │                               │                       │                    │
   │                               │ Validate each event   │                    │
   │                               │ Enrich with server    │                    │
   │                               │   metadata            │                    │
   │                               │ Check idempotency     │                    │
   │                               │   (Redis)             │                    │
   │                               │                       │                    │
   │                               │ Publish to Kafka      │                    │
   │                               │──────────────────────▶│                    │
   │                               │                       │                    │
   │  202 Accepted                 │                       │                    │
   │◀──────────────────────────────│                       │                    │
   │                               │                       │                    │
   │                               │                       │ Kafka Consumer     │
   │                               │                       │ (batch insert)     │
   │                               │                       │───────────────────▶│
   │                               │                       │                    │
```

---

## 9. Metric Key Conventions

Metric keys are defined by PMs in the dashboard when creating experiments. The Event Ingestion API accepts any metric key — it does not validate against defined metrics. The stats engine joins conversion events to experiment metrics at query time.

**Recommended naming convention:**

| Pattern | Example | Description |
|---|---|---|
| `{noun}_{verb_past}` | `order_placed` | Binary event (value = 1) |
| `{noun}_{measurement}` | `order_value` | Continuous metric (value = amount) |
| `{noun}_{verb_past}_{qualifier}` | `order_placed_first` | Qualified event |
| `session_{measurement}` | `session_duration` | Session-level metric |

---

## 10. Error Handling Guidance for Consumers

| Scenario | Recommended Action |
|---|---|
| `202 Accepted` | Success — events are queued |
| `207 Multi-Status` | Log dropped events, fix validation errors, do not retry dropped events |
| `400 Bad Request` | Fix request format, do not retry |
| `401 Unauthorized` | Check API key configuration |
| `413 Payload Too Large` | Split batch into smaller chunks, retry |
| `429 Too Many Requests` | Back off for `retryAfter` seconds, then retry |
| `500 Internal Server Error` | Retry with exponential backoff (max 3 retries) |
| Network timeout | Retry with exponential backoff (max 3 retries) |
