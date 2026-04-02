# Config Server API Contract

> **Owner:** Platform Team
> **Consumers:** Flutter SDK (Riise App), Future MOFSL SDKs
> **Base URL:** `https://experiments.mofsl.com`
> **Authentication:** API Key in `X-API-Key` header
> **Protocol:** HTTPS, REST, JSON

---

## 1. Get SDK Configuration

Fetches the experiment and feature flag configuration scoped to a specific client. This is the primary endpoint consumed by the SDK at initialization and on every background poll.

### Request

```
GET /api/v1/config
```

**Headers:**

| Header | Required | Description |
|---|---|---|
| `X-API-Key` | Yes | Application API key (e.g., Riise's key) |
| `If-None-Match` | No | ETag from the previous config response. If provided and matches current version, server returns `304`. |

**Query Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `clientCode` | string | Yes | The unique client identifier (MOFSL client code) |
| `attributes` | string (URL-encoded JSON) | No | User attributes for targeting evaluation. URL-encoded JSON object. |

**Example Request:**

```http
GET /api/v1/config?clientCode=AB1234&attributes=%7B%22platform%22%3A%22android%22%2C%22app_version%22%3A%225.2.1%22%2C%22city%22%3A%22Mumbai%22%2C%22segment%22%3A%22premium%22%7D HTTP/1.1
Host: experiments.mofsl.com
X-API-Key: mk_live_a1b2c3d4e5f6...
If-None-Match: "e3b0c44298fc1c14..."
```

Decoded `attributes`:
```json
{
  "platform": "android",
  "app_version": "5.2.1",
  "city": "Mumbai",
  "segment": "premium"
}
```

### Response — 200 OK (Config Changed or First Fetch)

**Headers:**

| Header | Value |
|---|---|
| `Content-Type` | `application/json` |
| `ETag` | Config version hash (quoted string), e.g. `"e3b0c44298fc1c14..."` |
| `Cache-Control` | `private, max-age=300` |

**Body:**

```json
{
  "version": "e3b0c44298fc1c14...",
  "generatedAt": "2026-04-01T10:30:00.000Z",
  "experiments": {
    "new_chart_ui": {
      "key": "new_chart_ui",
      "hashAttribute": "clientCode",
      "hashVersion": 1,
      "seed": "new_chart_ui",
      "status": "running",
      "variations": [
        {
          "key": "control",
          "value": false
        },
        {
          "key": "treatment",
          "value": true
        }
      ],
      "weights": [0.5, 0.5],
      "coverage": 1.0,
      "conditionMet": true
    },
    "order_flow_v2": {
      "key": "order_flow_v2",
      "hashAttribute": "clientCode",
      "hashVersion": 1,
      "seed": "order_flow_v2",
      "status": "running",
      "variations": [
        {
          "key": "control",
          "value": "control"
        },
        {
          "key": "variant_a",
          "value": "simplified"
        },
        {
          "key": "variant_b",
          "value": "express"
        }
      ],
      "weights": [0.34, 0.33, 0.33],
      "coverage": 0.5,
      "conditionMet": true
    }
  },
  "features": {
    "dark_mode": {
      "key": "dark_mode",
      "type": "boolean",
      "value": true
    },
    "max_watchlist_size": {
      "key": "max_watchlist_size",
      "type": "integer",
      "value": 50
    },
    "onboarding_copy": {
      "key": "onboarding_copy",
      "type": "string",
      "value": "Welcome to Riise"
    }
  },
  "forcedVariations": {
    "new_chart_ui": "treatment"
  }
}
```

### Response Field Reference

**Top-level fields:**

| Field | Type | Description |
|---|---|---|
| `version` | string | Config version hash (SHA-256). SDK stores this for ETag. |
| `generatedAt` | string (ISO 8601) | Server timestamp when this config was generated |
| `experiments` | object | Map of experiment key → experiment config. Only includes experiments where this client is eligible AND targeting conditions are met. |
| `features` | object | Map of feature flag key → flag value. Only includes flags that are active. |
| `forcedVariations` | object | Map of experiment key → forced variation key. Overrides normal assignment for QA. |

**Experiment object fields:**

| Field | Type | Description |
|---|---|---|
| `key` | string | Unique experiment identifier |
| `hashAttribute` | string | The attribute used for hashing (always `"clientCode"` in Phase 1) |
| `hashVersion` | integer | Hash algorithm version (1 = MurmurHash3 x86 32-bit) |
| `seed` | string | Hash seed string (default: same as experiment key) |
| `status` | string | `"running"` or `"paused"` |
| `variations` | array | Ordered list of variation objects |
| `variations[].key` | string | Variation identifier (e.g., `"control"`, `"treatment"`) |
| `variations[].value` | any | The value returned by SDK evaluation (boolean, string, integer, or JSON object) |
| `weights` | array of floats | Variation traffic weights, same order as `variations`. Must sum to 1.0. |
| `coverage` | float | Traffic allocation (0.0 to 1.0). Fraction of eligible users included in experiment. |
| `conditionMet` | boolean | Whether server-side targeting conditions were met for this client. Always `true` in the config (if `false`, experiment is excluded from the config entirely). |

**Feature flag object fields:**

| Field | Type | Description |
|---|---|---|
| `key` | string | Unique flag identifier |
| `type` | string | Value type: `"boolean"`, `"string"`, `"integer"`, `"json"` |
| `value` | any | Current flag value |

### Response — 304 Not Modified

Returned when the `If-None-Match` header matches the current config version. No body.

```http
HTTP/1.1 304 Not Modified
ETag: "e3b0c44298fc1c14..."
```

### Response — 401 Unauthorized

Invalid or missing API key.

```json
{
  "error": "unauthorized",
  "message": "Invalid or missing API key"
}
```

### Response — 400 Bad Request

Missing required parameters.

```json
{
  "error": "bad_request",
  "message": "clientCode query parameter is required"
}
```

### Response — 500 Internal Server Error

Server-side failure. SDK should fall back to cached config.

```json
{
  "error": "internal_error",
  "message": "Failed to generate config"
}
```

---

## 2. Health Check

Used by load balancers and monitoring.

### Request

```
GET /health
```

### Response — 200 OK

```json
{
  "status": "healthy",
  "version": "1.0.0",
  "uptime": 86400,
  "checks": {
    "postgres": "ok",
    "redis": "ok"
  }
}
```

---

## 3. SDK Evaluation Contract (Client-Side)

This section documents how the SDK uses the config payload. This is not an API endpoint — it is the contract for how the SDK interprets the config data.

### Experiment Evaluation Algorithm

```
function evaluateExperiment(experiment, clientCode):
  // 1. Check forced variations
  if forcedVariations[experiment.key] exists:
    return forcedVariations[experiment.key]

  // 2. Check experiment status
  if experiment.status != "running":
    return null (use default value)

  // 3. Compute bucket
  hashInput = experiment.seed + ":" + clientCode
  bucket = murmurhash3_x86_32(hashInput, seed=0) % 10000

  // 4. Check traffic coverage
  if bucket >= experiment.coverage * 10000:
    return null (user excluded from experiment)

  // 5. Assign variation based on weights
  cumulative = 0
  for i, weight in experiment.weights:
    cumulative += weight * 10000
    if bucket < cumulative:
      return experiment.variations[i]

  // 6. Fallback (should never reach here if weights sum to 1.0)
  return null
```

### Feature Flag Evaluation

```
function evaluateFlag(flag, defaultValue):
  if flag exists in config.features:
    return flag.value
  else:
    return defaultValue
```

### Exposure Firing Rules

- Fire `onExposure` callback on the **first evaluation** of each experiment per SDK session
- Do NOT fire on subsequent evaluations of the same experiment in the same session
- Do NOT fire for feature flags (only experiments)
- Do NOT fire if the user is excluded from the experiment (bucket >= coverage)
- Do NOT fire for forced variations (QA overrides)

---

## 4. Rate Limits

| Endpoint | Limit | Window |
|---|---|---|
| `GET /api/v1/config` | 100 requests per client code | Per minute |
| Global | 10,000 requests | Per second |

Rate limit exceeded returns `429 Too Many Requests`:

```json
{
  "error": "rate_limited",
  "message": "Too many requests",
  "retryAfter": 60
}
```

---

## 5. Versioning

The API is versioned via URL path (`/api/v1/`). Breaking changes will increment the version. Non-breaking additions (new fields in the config payload) are backward-compatible and do not require a version bump. SDKs must ignore unknown fields.

---

## 6. Config Payload Size Targets

| Metric | Target |
|---|---|
| Typical payload (10 experiments, 5 flags) | < 5 KB |
| Maximum payload (50 experiments, 20 flags) | < 50 KB |
| Compressed (gzip) | ~70% reduction |

The config server enables gzip compression. SDKs should send `Accept-Encoding: gzip`.
