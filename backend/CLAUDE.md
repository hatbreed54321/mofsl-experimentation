# CLAUDE.md — Backend / Control Plane Module

> **This file is read automatically by Claude Code** when working in the `/backend` directory.
> Read the root `/CLAUDE.md` first for project-wide conventions.

---

## What This Module Is

A Node.js + TypeScript API server that serves three roles:

1. **Config Server** — serves experiment/flag config to the Flutter SDK (`GET /api/v1/config`)
2. **Control Plane API** — CRUD for experiments, flags, targeting, eligibility, metrics (consumed by the dashboard)
3. **Event Ingestion API** — receives exposure/conversion events from the Riise app and publishes to Kafka

All three run as separate ECS services from the same codebase, sharing models and utilities.

---

## Project Structure

```
backend/
├── CLAUDE.md                          ← you are here
├── src/
│   ├── server.ts                      ← Express app setup, middleware, route mounting
│   ├── config.ts                      ← Environment variable loading + validation
│   ├── routes/
│   │   ├── config.routes.ts           ← GET /api/v1/config (SDK-facing)
│   │   ├── experiment.routes.ts       ← CRUD /api/v1/experiments
│   │   ├── flag.routes.ts             ← CRUD /api/v1/flags
│   │   ├── targeting.routes.ts        ← CRUD /api/v1/targeting-rules
│   │   ├── eligibility.routes.ts      ← Upload + manage eligible clients
│   │   ├── metric.routes.ts           ← CRUD /api/v1/metrics
│   │   ├── results.routes.ts          ← GET /api/v1/experiments/:id/results
│   │   ├── event.routes.ts            ← POST /api/v1/events (event ingestion)
│   │   ├── auth.routes.ts             ← SSO callback, token refresh
│   │   ├── audit.routes.ts            ← GET /api/v1/audit-log
│   │   └── health.routes.ts           ← GET /health
│   ├── services/
│   │   ├── experiment.service.ts      ← Experiment business logic
│   │   ├── flag.service.ts            ← Feature flag business logic
│   │   ├── config-generator.service.ts ← Assembles SDK config payload
│   │   ├── eligibility/
│   │   │   ├── eligibility.interface.ts ← EligibilityService interface
│   │   │   ├── file-upload.eligibility.ts ← Phase 1 implementation (PostgreSQL)
│   │   │   └── data-lake.eligibility.ts   ← Phase 2 placeholder (not implemented)
│   │   ├── targeting.service.ts       ← Attribute targeting rule evaluation
│   │   ├── event.service.ts           ← Event validation + Kafka publishing
│   │   ├── stats.service.ts           ← Stats engine (queries ClickHouse)
│   │   ├── upload.service.ts          ← CSV/Excel parsing + validation
│   │   ├── audit.service.ts           ← Audit log writing
│   │   ├── cache.service.ts           ← Redis cache operations
│   │   └── auth.service.ts            ← JWT validation, SSO token exchange
│   ├── middleware/
│   │   ├── auth.middleware.ts         ← JWT validation for dashboard routes
│   │   ├── api-key.middleware.ts      ← API key validation for SDK/event routes
│   │   ├── error-handler.middleware.ts ← Global error handler
│   │   ├── request-logger.middleware.ts ← Structured request logging
│   │   ├── rate-limiter.middleware.ts  ← Rate limiting
│   │   └── validator.middleware.ts     ← Request validation (zod schemas)
│   ├── models/
│   │   ├── experiment.model.ts        ← TypeScript types matching PostgreSQL schema
│   │   ├── variation.model.ts
│   │   ├── flag.model.ts
│   │   ├── targeting-rule.model.ts
│   │   ├── eligible-client.model.ts
│   │   ├── metric.model.ts
│   │   ├── event.model.ts             ← Exposure + Conversion event types
│   │   ├── config-payload.model.ts    ← SDK config response type
│   │   └── audit.model.ts
│   ├── db/
│   │   ├── postgres.ts                ← PostgreSQL connection pool (pg)
│   │   ├── redis.ts                   ← Redis client (ioredis)
│   │   ├── clickhouse.ts             ← ClickHouse client (@clickhouse/client)
│   │   ├── kafka.ts                   ← Kafka producer (kafkajs)
│   │   └── migrations/               ← Database migration files
│   │       ├── 001_initial_schema.sql
│   │       └── ...
│   ├── validators/
│   │   ├── experiment.validator.ts    ← Zod schemas for experiment CRUD
│   │   ├── flag.validator.ts
│   │   ├── event.validator.ts         ← Zod schema for event ingestion
│   │   └── upload.validator.ts
│   └── utils/
│       ├── logger.ts                  ← Structured JSON logger (pino)
│       ├── hash.ts                    ← MurmurHash3 (for server-side verification)
│       ├── errors.ts                  ← Custom error classes
│       └── s3.ts                      ← S3 upload/download helper
├── test/
│   ├── unit/
│   │   ├── services/
│   │   ├── middleware/
│   │   └── validators/
│   ├── integration/
│   │   ├── config.integration.test.ts
│   │   ├── experiment.integration.test.ts
│   │   └── event.integration.test.ts
│   └── fixtures/
│       ├── sample-upload.csv
│       └── ...
├── Dockerfile
├── docker-compose.yml                 ← Local dev with PostgreSQL, Redis, Kafka, ClickHouse
├── package.json
├── tsconfig.json
├── jest.config.ts
└── .env.example
```

---

## Key Dependencies

```json
{
  "dependencies": {
    "express": "^4.18",
    "@types/express": "^4.17",
    "pg": "^8.11",                    // PostgreSQL client
    "ioredis": "^5.3",               // Redis client
    "@clickhouse/client": "^0.2",     // ClickHouse client
    "kafkajs": "^2.2",               // Kafka producer
    "zod": "^3.22",                  // Runtime validation
    "pino": "^8.16",                 // Structured logging
    "pino-http": "^9.0",             // HTTP request logging
    "bcrypt": "^5.1",                // API key hashing
    "jsonwebtoken": "^9.0",          // JWT validation
    "multer": "^1.4",                // File upload handling
    "csv-parse": "^5.5",             // CSV parsing
    "xlsx": "^0.18",                 // Excel parsing
    "@aws-sdk/client-s3": "^3.400",  // S3 uploads
    "murmurhash-js": "^1.0",         // MurmurHash3 (server-side verification)
    "compression": "^1.7",           // gzip compression
    "helmet": "^7.1",                // Security headers
    "cors": "^2.8"                   // CORS for dashboard
  }
}
```

---

## Config Generator Pipeline (Most Critical Code Path)

This is the logic that assembles the SDK config payload. Reference: `architecture/api/CONFIG_SERVER_API.md`.

```
Request: GET /api/v1/config?clientCode=AB1234&attributes={...}

1. Validate API key (api-key.middleware.ts)
2. Extract clientCode and attributes from query params
3. Check Redis for cached config:
   Key: config:v1:{clientCode}
   If hit AND ETag matches If-None-Match header → return 304
   If hit AND ETag differs → return cached payload with new ETag
4. On cache miss:
   a. Query PostgreSQL: all experiments WHERE status IN ('running', 'paused')
      AND application_id matches the API key's application
   b. For each experiment, check eligibility:
      Call eligibilityService.isEligible(clientCode, experimentId)
      (Phase 1: queries eligible_clients table)
   c. For eligible experiments, evaluate targeting rules:
      Query targeting_rules for this experiment
      Match against client's attributes
      All rules must pass (AND logic in Phase 1)
   d. For passing experiments, include in config with:
      - variations (ordered by sort_order)
      - weights (from variations)
      - coverage
      - hash config (seed, hashVersion, hashAttribute)
   e. Query feature_flags WHERE is_enabled = TRUE AND application_id matches
   f. Query forced_variations for this clientCode
   g. Assemble config payload (see CONFIG_SERVER_API.md for exact shape)
   h. Compute config version hash: SHA-256 of sorted, serialized JSON
   i. Cache in Redis with TTL 300 seconds (5 min)
   j. Return 200 with payload and ETag header
```

**Performance target:** < 50ms for cache hit, < 200ms for cache miss.

---

## Eligibility Service Interface

```typescript
interface EligibilityService {
  isEligible(clientCode: string, experimentId: string): Promise<boolean>;
  getEligibleExperimentIds(clientCode: string): Promise<string[]>;
  bulkCheckEligibility(
    clientCode: string,
    experimentIds: string[]
  ): Promise<Map<string, boolean>>;
}
```

**Phase 1 implementation (`FileUploadEligibilityService`):**
- Queries `eligible_clients` table: `SELECT 1 FROM eligible_clients WHERE client_code = $1 AND experiment_id = $2`
- `bulkCheckEligibility` uses a single query with `IN` clause for efficiency
- If an experiment has zero rows in `eligible_clients`, ALL users are eligible (no targeting list = open to everyone)

**Phase 2:** `DataLakeEligibilityService` implements the same interface, querying the data lake instead.

---

## Experiment Lifecycle Rules

State machine enforcement — **the backend must validate every state transition:**

| From | Allowed To | Conditions |
|---|---|---|
| `draft` | `running` | Must have ≥2 variations, weights must sum to 1.0, must have ≥1 metric assigned |
| `draft` | (deleted) | Only state that allows deletion |
| `running` | `paused` | Immediate — no conditions |
| `running` | `completed` | Immediate — experiment stops, config removed from SDK |
| `paused` | `running` | Resume — no conditions |
| `paused` | `completed` | Immediate |
| `completed` | `archived` | Immediate — removes from dashboard active list |

Any invalid transition must return `409 Conflict` with a clear error message.

**On status change to `running`:**
1. Set `started_at = NOW()` if not already set
2. Write audit log entry
3. Invalidate Redis config cache (triggers SDK refresh)
4. Recompute global config version hash

**On status change to `completed` or `paused`:**
1. Set `completed_at = NOW()` or `paused_at = NOW()`
2. Write audit log entry
3. Invalidate Redis config cache

---

## Audit Log Rules

Every mutation in the system must write to the `audit_log` table. Use the `AuditService`:

```typescript
await auditService.log({
  entityType: 'experiment',           // matches audit_log.entity_type
  entityId: experiment.id,
  action: 'status_changed',           // 'created', 'updated', 'deleted', 'status_changed', 'uploaded'
  changes: {
    status: { old: 'draft', new: 'running' }
  },
  metadata: { reason: 'Experiment launched by PM' },
  actorId: currentUser.id,
  actorEmail: currentUser.email
});
```

**Audit log is append-only.** Never update or delete audit log entries.

---

## Event Ingestion Pipeline

Reference: `architecture/api/EVENT_INGESTION_API.md`

```
Request: POST /api/v1/events { events: [...] }

1. Validate API key (api-key.middleware.ts)
2. Validate batch: max 1000 events, must be array
3. For each event:
   a. Validate schema (zod) — type, clientCode, timestamp, type-specific fields
   b. Reject invalid events, collect errors
   c. Enrich valid events: add receivedAt, eventId (UUID), apiKeyId, appId
   d. Check idempotency (Redis): if idempotencyKey exists, skip (silent dedup)
   e. Publish to Kafka topic (exp.exposures or exp.conversions)
   f. Set idempotency key in Redis with 24h TTL
4. Return 202 (all accepted) or 207 (partial — some rejected)
```

**Kafka producer config:**
- `acks: 'all'` — wait for all replicas
- `compression: CompressionTypes.LZ4`
- `idempotent: true`
- Partition key: `experimentKey` for exposures, `clientCode` for conversions

---

## Database Access Patterns

**PostgreSQL (via `pg` pool):**
- Use parameterized queries only — never string concatenation
- Use transactions for multi-table writes: `BEGIN → INSERT experiment → INSERT variations → INSERT metrics → COMMIT`
- Connection pool: min 2, max 20 connections
- Set `statement_timeout = 5000` (5 seconds) to prevent long-running queries

**Redis (via `ioredis`):**
- Config cache key: `config:v1:{clientCode}` → JSON string, TTL 300s
- Config version key: `config:version:{applicationId}` → hash string
- Idempotency key: `idemp:{idempotencyKey}` → `"1"`, TTL 86400s (24h)
- Use `SET ... EX` for TTL-based keys, never `SET` + separate `EXPIRE`

**ClickHouse (via `@clickhouse/client`):**
- Read-only from the backend — ClickHouse writes happen via Kafka consumer
- Used only by `stats.service.ts` for experiment results queries
- Use parameterized queries with `query_params`
- Reference `architecture/schemas/clickhouse_schema.sql` for table names and views

---

## Request Validation

Use Zod for all request validation. Define schemas in `/src/validators/`.

```typescript
// Example: experiment creation schema
const createExperimentSchema = z.object({
  key: z.string().min(1).max(100).regex(/^[a-z0-9_-]+$/),
  name: z.string().min(1).max(200),
  description: z.string().optional(),
  hypothesis: z.string().optional(),
  variations: z.array(z.object({
    key: z.string().min(1).max(100),
    name: z.string().min(1).max(200),
    value: z.unknown(),             // boolean, string, number, or JSON
    weight: z.number().min(0).max(1),
    isControl: z.boolean().default(false),
  })).min(2),
  coverage: z.number().min(0).max(1).default(1),
});
```

Validation errors return `400` with field-level details:
```json
{
  "error": "validation_error",
  "message": "Request validation failed",
  "details": [
    { "field": "variations[0].weight", "message": "Must be between 0 and 1" }
  ]
}
```

---

## Error Handling

Use a global error handler middleware. Define custom error classes:

```typescript
class AppError extends Error {
  constructor(
    public statusCode: number,
    public errorCode: string,
    message: string
  ) { super(message); }
}

class NotFoundError extends AppError {
  constructor(entity: string, id: string) {
    super(404, 'not_found', `${entity} with id ${id} not found`);
  }
}

class ConflictError extends AppError {
  constructor(message: string) {
    super(409, 'conflict', message);
  }
}
```

The global error handler catches all errors and returns the standard error response format. Unhandled errors return `500` with a generic message (never leak stack traces in production).

---

## Logging

Use `pino` for all logging. Structured JSON format:

```typescript
logger.info({
  event: 'config_served',
  clientCode: 'AB1234',
  experimentCount: 5,
  cacheHit: true,
  latencyMs: 3
});
```

**Required fields in every log entry:** `timestamp`, `level`, `event`, `requestId` (from middleware).

**Never log:** API keys (full), client code lists, event payloads in production (too verbose), stack traces in non-error logs.

---

## What NOT To Do in This Module

- **Never return HTML from API endpoints** — JSON only
- **Never use `SELECT *`** — always specify columns explicitly
- **Never write raw SQL strings without parameterization** — use `$1, $2` placeholders
- **Never cache in Node.js process memory** — use Redis (ECS tasks scale horizontally; in-memory cache causes inconsistency)
- **Never write directly to ClickHouse from the API** — events go through Kafka
- **Never expose internal error details** in production API responses
- **Never skip audit logging** for any mutation — it's a hard requirement
- **Never allow experiment key changes** after creation — it would re-shuffle all users
- **Never validate variation weights only individually** — always validate that weights sum to 1.0 for the entire experiment
