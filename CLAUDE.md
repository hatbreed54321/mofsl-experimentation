# CLAUDE.md — MOFSL Experimentation Platform

> **This file is read automatically by Claude Code.** It defines project-wide conventions, tech stack, and rules that apply to ALL modules.

---

## What This Project Is

An internal, self-hosted A/B testing and feature flagging platform for MOFSL. It is designed as a standalone SaaS-style product where the Riise mobile trading app (40L+ customers) is the first client. The platform is extensible to all MOFSL products.

**We are a platform team.** We deliver an SDK and APIs. We do not have access to the Riise codebase. The Riise engineering team integrates our Flutter SDK and decides where to run experiments.

---

## Monorepo Structure

```
mofsl-experimentation/
├── CLAUDE.md                    ← you are here (project-wide rules)
├── PROJECT_CONTEXT_phase5.md    ← master decision log (read this for full history)
├── architecture/
│   ├── ARCHITECTURE.md          ← master architecture doc
│   ├── adr/                     ← 11 architectural decision records
│   ├── api/
│   │   ├── CONFIG_SERVER_API.md ← SDK ↔ Config Server contract
│   │   └── EVENT_INGESTION_API.md ← Event ingestion contract
│   └── schemas/
│       ├── postgresql_schema.sql
│       ├── clickhouse_schema.sql
│       └── KAFKA_TOPICS.md
├── sdk/                         ← Flutter SDK (pure Dart)
│   └── CLAUDE.md
├── backend/                     ← Node.js/TypeScript API server
│   └── CLAUDE.md
├── dashboard/                   ← Next.js internal dashboard
│   └── CLAUDE.md
├── data/                        ← ClickHouse, Kafka, stats engine
│   └── CLAUDE.md
└── skills/                      ← Domain knowledge for Claude Code
    ├── ab-testing-domain.md
    ├── flutter-sdk-patterns.md
    ├── file-based-targeting.md
    └── stats-engine.md
```

---

## Tech Stack (Locked — Do Not Deviate)

| Component | Technology | Version Target |
|---|---|---|
| Cloud | AWS `ap-south-1` (Mumbai) | — |
| Container Orchestration | AWS ECS + Fargate | — |
| API Server | Node.js + TypeScript | Node 20 LTS, TypeScript 5.x |
| Dashboard | Next.js (React) | Next.js 14+ (App Router) |
| Flutter SDK | Pure Dart | Dart 3.x, Flutter 3.x compatible |
| Transactional DB | PostgreSQL | 15+ on AWS RDS |
| Event/Analytics DB | ClickHouse | 23.x+ |
| Event Queue | Kafka | AWS MSK (Kafka 3.x) |
| Cache | Redis | AWS ElastiCache 7.x |
| File Storage | AWS S3 | — |
| CI/CD | GitHub Actions | — |

---

## Naming Conventions

### Code

| Context | Convention | Example |
|---|---|---|
| TypeScript files | camelCase | `experimentService.ts` |
| TypeScript classes | PascalCase | `ExperimentService` |
| TypeScript functions/variables | camelCase | `getExperiment()`, `experimentId` |
| TypeScript interfaces | PascalCase, no `I` prefix | `Experiment`, not `IExperiment` |
| TypeScript enums | PascalCase members | `ExperimentStatus.Running` |
| Dart files | snake_case | `experiment_client.dart` |
| Dart classes | PascalCase | `MofslExperiment` |
| Dart functions/variables | camelCase | `getBool()`, `experimentKey` |
| React components | PascalCase | `ExperimentList.tsx` |
| Database columns | snake_case | `experiment_id`, `created_at` |
| API endpoints | kebab-case paths, camelCase JSON | `/api/v1/config`, `{ "experimentKey": "..." }` |
| Kafka topics | dot-separated | `exp.exposures`, `exp.conversions` |
| Environment variables | UPPER_SNAKE_CASE | `DATABASE_URL`, `REDIS_HOST` |

### Experiment/Flag Keys

- Lowercase, underscore-separated: `new_chart_ui`, `order_flow_v2`
- Must be URL-safe (letters, numbers, underscores, hyphens)
- Max 100 characters
- Immutable after creation (key is used in hashing — changing it re-shuffles users)

### Metric Keys

- Same convention as experiment keys: `order_placed`, `session_duration`
- Pattern: `{noun}_{verb_past}` for binary, `{noun}_{measurement}` for continuous

---

## API Conventions

- REST, JSON, HTTPS only
- Versioned: `/api/v1/...`
- Consistent error format across all endpoints:
  ```json
  {
    "error": "error_code",
    "message": "Human-readable description"
  }
  ```
- HTTP status codes: `200` success, `201` created, `202` accepted (async), `304` not modified, `400` bad request, `401` unauthorized, `404` not found, `409` conflict, `413` payload too large, `429` rate limited, `500` internal error
- All timestamps in ISO 8601 with timezone: `2026-04-01T10:30:00.000Z`
- UUIDs (v4) for all entity IDs
- Pagination: cursor-based for lists (not offset-based)

---

## Authentication Model

| Interface | Method |
|---|---|
| Dashboard → Control Plane API | JWT Bearer token from MOFSL SSO (SAML 2.0/OIDC) |
| SDK → Config Server | `X-API-Key` header (application-level key, e.g., Riise has one key) |
| Riise App → Event Ingestion API | Same `X-API-Key` as config server |

API keys are stored as bcrypt hashes in `api_keys` table. Only the `key_prefix` (first 12 chars) is stored in plain text for identification.

---

## Environment Configuration

All services read configuration from environment variables. No hardcoded connection strings, secrets, or URLs.

```
# Required for all services
NODE_ENV=production|staging|development
LOG_LEVEL=info|debug|warn|error

# PostgreSQL
DATABASE_URL=postgresql://user:pass@host:5432/experimentation
DATABASE_POOL_MIN=2
DATABASE_POOL_MAX=20

# Redis
REDIS_HOST=redis-cluster.xxxxx.cache.amazonaws.com
REDIS_PORT=6379

# Kafka
KAFKA_BROKERS=b-1.msk.kafka.ap-south-1.amazonaws.com:9092,...
KAFKA_CLIENT_ID=experimentation-platform

# ClickHouse
CLICKHOUSE_HOST=clickhouse.internal
CLICKHOUSE_PORT=8123
CLICKHOUSE_DATABASE=experimentation

# S3
S3_BUCKET=mofsl-experimentation-uploads
S3_REGION=ap-south-1

# Auth
SSO_ISSUER_URL=https://sso.mofsl.com
SSO_CLIENT_ID=experimentation-dashboard
SSO_CLIENT_SECRET=...
JWT_SECRET=...
```

---

## Git Conventions

- Branch naming: `feature/{module}/{short-description}` (e.g., `feature/sdk/config-caching`)
- Commit messages: conventional commits — `feat(sdk): add config caching`, `fix(backend): handle null variation weight`
- PRs: one module at a time, reference the relevant CLAUDE.md
- Never commit secrets, `.env` files, or `node_modules`

---

## Testing Requirements

| Module | Unit Test Framework | Coverage Target |
|---|---|---|
| SDK (Dart) | `package:test` | 90%+ |
| Backend (TypeScript) | Jest | 85%+ |
| Dashboard (React) | Jest + React Testing Library | 70%+ |
| Stats Engine | Jest (unit) + ClickHouse test DB (integration) | 95%+ |

All modules must have integration tests that run against real (dockerized) dependencies.

---

## What NOT To Do

**Never:**
- Use a different hashing algorithm than MurmurHash3 x86 32-bit for bucketing
- Add event transport/batching/retry logic to the SDK — the SDK fires a callback only
- Store PII in the experimentation platform — client codes are pseudonymous identifiers
- Use offset-based pagination — use cursor-based only
- Use `localStorage` or any browser storage in the dashboard for auth tokens — use HTTP-only cookies
- Import Riise-specific business logic into the platform — it must be product-agnostic
- Change an experiment's `key` after creation — it's used in the hash and would re-shuffle users
- Skip the audit log — every mutation to experiments, flags, eligibility, and targeting rules must be logged
- Hardcode connection strings or secrets — always use environment variables
- Use floating-point arithmetic for currency/financial values — use integer arithmetic (paise) or Decimal
- Add `any` types in TypeScript — always define proper types/interfaces
- Use `var` in TypeScript — use `const` and `let`
- Break the API contracts defined in `architecture/api/` — these are the integration contracts with the Riise team

**Always:**
- Read the module-specific CLAUDE.md before working in that module
- Read the relevant skill file before implementing domain logic
- Reference `architecture/schemas/postgresql_schema.sql` before writing any database query
- Reference `architecture/api/CONFIG_SERVER_API.md` before changing any config endpoint
- Reference `architecture/api/EVENT_INGESTION_API.md` before changing any event endpoint
- Write tests alongside implementation code (not after)
- Log structured JSON (not plain text) from all services
- Return meaningful error messages in API responses
- Use transactions for multi-table writes in PostgreSQL
- Validate all input at the API boundary (never trust client data)

---

## Architecture Quick Reference

**Config serving path:** SDK → ALB → Config Server → Redis (95%+ hit rate) → PostgreSQL (fallback) → scoped config payload → SDK caches in SharedPreferences

**Event pipeline path:** Riise App → ALB → Event Ingestion API → validate + enrich → Kafka → ClickHouse Kafka engine → materialized views → stats engine SQL queries

**Experiment lifecycle:** Draft → Running → Paused → Running → Completed → Archived. Deletion only from Draft.

**Bucketing:** `MurmurHash3_x86_32(experimentKey + ":" + clientCode, seed=0) % 10000`. Coverage determines inclusion. Weights determine variation assignment.

**Scale targets:** 5K config req/sec, 10K events/sec, 100K concurrent SDK connections, 50 concurrent experiments, 1M eligible clients per experiment.

---

## Reference Documents

For detailed information, read these files in order of relevance:
1. `architecture/ARCHITECTURE.md` — full system architecture
2. `architecture/api/CONFIG_SERVER_API.md` — SDK ↔ server contract
3. `architecture/api/EVENT_INGESTION_API.md` — event ingestion contract
4. `architecture/schemas/postgresql_schema.sql` — database schema
5. `architecture/schemas/clickhouse_schema.sql` — event storage schema
6. `architecture/schemas/KAFKA_TOPICS.md` — Kafka configuration
7. `architecture/adr/` — individual decision records for "why" behind each choice

---

## Implementation Log — Mistakes & Learnings

> **Purpose:** Running log of mistakes made during implementation, root causes, and the corrected patterns. Future Claude instances must read this before writing code. This is not theory — every item here burned real debugging time.

---

### Phase 6 — Client Targeting Ingestion Pipeline

#### 1. Config schema didn't include `test` and `silent` as valid values
**Mistake:** Zod schema for `NODE_ENV` only allowed `development | staging | production`. `LOG_LEVEL` didn't include `silent`.  
**Root cause:** Wrote the config schema thinking only about production runtime environments, forgot tests run with `NODE_ENV=test` and suppress logs with `LOG_LEVEL=silent`.  
**Fix:** Add `test` to the `NODE_ENV` enum. Add `silent` to the `LOG_LEVEL` enum.  
**Rule:** Always include `test` and `silent` when defining `NODE_ENV` and `LOG_LEVEL` enums in config schemas.

---

#### 2. `@types/dotenv` added as a devDependency — package does not exist
**Mistake:** Added `@types/dotenv` to `devDependencies`.  
**Root cause:** Habit of adding `@types/` for every package. `dotenv` ships its own TypeScript types since v16 — there is no separate `@types/dotenv`.  
**Fix:** Remove `@types/dotenv`.  
**Rule:** Check whether a package ships its own types before reaching for `@types/*`. Packages that bundle their own types: `dotenv`, `uuid`, `zod`, `pino`, `ioredis`.

---

#### 3. `docker-compose.yml` `version` field warning
**Mistake:** Used `version: '3.9'` at the top of `docker-compose.yml`.  
**Root cause:** Copied an older template. Docker Compose v2 (the current default, shipped with Docker Desktop) ignores and warns about the `version` field.  
**Fix:** Remove the `version` field entirely.  
**Rule:** Never include `version:` in `docker-compose.yml`. Compose v2 doesn't need it and warns when it's present.

---

#### 4. Jest config key typo: `coverageThresholds` vs `coverageThreshold`
**Mistake:** Used `coverageThresholds` (plural) in `jest.config.ts`.  
**Root cause:** Typo. Jest's actual key is `coverageThreshold` (singular).  
**Fix:** Rename to `coverageThreshold`.  
**Rule:** Jest config keys are singular: `coverageThreshold`, not `coverageThresholds`.

---

#### 5. `uploaded_by` FK caused 500 errors in integration tests
**Mistake:** Passed `req.user?.id` as `uploaded_by` in `client_list_uploads`. The column is a FK to `users(id)`. No users exist yet (SSO is Phase 8).  
**Root cause:** Assumed the user from the JWT would exist in our `users` table. It doesn't — we have no user rows until Phase 8 SSO is implemented.  
**Fix:** Always insert `null` for `uploaded_by`. Track actor identity via `actor_email` (denormalized text column) in the audit log instead.  
**Rule:** Until Phase 8 SSO is complete, every FK to `users(id)` must be `null`. Never pass a JWT user ID directly into a FK column referencing `users`.

---

#### 6. Same FK problem in `audit_log.actor_id`
**Mistake:** Passed `actorId` from JWT claims into `audit_log.actor_id`.  
**Root cause:** Same as above — `actor_id` is a FK to `users(id)`, no user rows exist until Phase 8.  
**Fix:** Always insert `null` for `actor_id`. Use `actor_email` for identity tracking.  
**Rule:** `audit_log.actor_id` = `null` always until Phase 8. `actor_email` is the authoritative actor identity for now.

---

#### 7. `app.listen()` called when server.ts was imported by tests → `EADDRINUSE`
**Mistake:** `start()` (which calls `app.listen()`) was called at module level in `server.ts`.  
**Root cause:** No guard around the startup call. When Jest imports `server.ts` to get the `app` export for supertest, the side effect fires.  
**Fix:** Wrap `start()` in `if (require.main === module)`.  
**Rule:** Every Express `server.ts` must guard `start()` with `if (require.main === module)`. The file must export `app` without starting the HTTP listener.

---

#### 8. Jest didn't exit cleanly — open pg and Redis connections
**Mistake:** Tests passed but Jest hung after completion with `Force exiting Jest`.  
**Root cause:** The singleton `pool` (pg) and `redis` (ioredis) clients from `db/postgres.ts` and `db/redis.ts` kept their connections open. Jest can't exit while async handles are live.  
**Fix:** `afterAll` in integration tests must call `closePool()` and `closeRedis()` from the db modules.  
**Rule:** Integration tests that touch the real DB or Redis must call `closePool()` + `closeRedis()` in `afterAll`. `forceExit: true` in jest config is a safety net only — always close connections explicitly.

---

#### 9. Transaction helper duplicated in upload.service.ts
**Mistake:** `upload.service.ts` defined its own local `runInTransaction` function that duplicated `withTransaction` from `postgres.ts`.  
**Root cause:** Wrote the service without checking what db utilities already existed.  
**Fix:** Delete the local copy, use `withTransactionOn(db, fn)` from `postgres.ts`.  
**Rule:** Never define transaction wrappers locally in a service. Always use the shared utilities in `src/db/postgres.ts`.

---

#### 10. `multer.MulterError` fell through to the generic 500 handler
**Mistake:** File-too-large errors returned 500 instead of 413.  
**Root cause:** The global error handler only checked `instanceof AppError`. `multer.MulterError` is a different class and wasn't caught.  
**Fix:** Add `instanceof multer.MulterError` check in the error handler: `LIMIT_FILE_SIZE` → 413, all others → 400.  
**Rule:** When adding any new middleware that throws typed errors (multer, busboy, formidable, etc.), immediately add a corresponding `instanceof` branch in `error-handler.middleware.ts`.

---

#### 11. S3 key contained raw `file.originalname` — unsafe characters
**Mistake:** Used `file.originalname` directly in the S3 key string.  
**Root cause:** Didn't account for spaces, parentheses, and Unicode in filenames that users upload.  
**Fix:** Sanitize with `/[^a-zA-Z0-9.\-_]/g` → `_` before building the S3 key.  
**Rule:** Never put user-controlled strings directly into S3 keys, file paths, or URL segments. Always sanitize: keep only `[A-Za-z0-9._-]`, replace everything else with `_`.

---

#### 12. bcrypt called on every API request — would collapse at 5K req/s
**Mistake:** `api-key.middleware.ts` called `bcrypt.compare()` on every incoming request.  
**Root cause:** Did not think about bcrypt's intentional slowness (~100ms per compare) in the context of 5K req/s target throughput.  
**Fix:** Cache validated API key results in Redis with a 5-minute TTL (`apikey:validated:{prefix}` → `{id, applicationId}`). Check Redis first; only call bcrypt on cache miss.  
**Rule:** bcrypt must never be on a hot path. Always cache bcrypt results in Redis when the input is stable (API keys don't change per-request). Cache key: `apikey:validated:{key_prefix}`.

---

#### 13. DELETE with request body — body stripped by HTTP proxies
**Mistake:** Designed a `DELETE /eligible-clients` endpoint that accepted an optional `uploadBatchId` in the request body.  
**Root cause:** DELETE-with-body is technically valid HTTP but many CDNs, ALBs, and reverse proxies strip DELETE bodies. It's also not idiomatic REST.  
**Fix:** Use a sub-resource URL: `DELETE /eligible-clients/batches/:batchId` for batch deletion; `DELETE /eligible-clients` for clearing all.  
**Rule:** Never use DELETE with a request body. Encode the target in the URL path. Use sub-resource URLs for scoped deletes.

---

#### 14. Service instances created per-request inside route handlers
**Mistake:** Wrote `new AuditService(pool)` and `new CacheService(redis)` inside the route handler function body.  
**Root cause:** Copy-paste without thinking about object lifecycle. Every request constructed a new object.  
**Fix:** Instantiate services once at module level in the router file and reuse the singleton.  
**Rule:** Services are stateless wrappers over connection pools. Construct them once at module scope, not per-request. Constructing per-request wastes GC pressure and makes connection-sharing impossible.

---

#### 15. Client code dedup stored mixed-case strings despite normalising to uppercase for the Set
**Mistake:** `seen.add(code.toUpperCase())` but `valid.push(code)` (original mixed-case).  
**Root cause:** The dedup key was normalised but the value pushed into the output array was the original. Downstream DB insert would then hit the unique constraint on `(experiment_id, client_code)` because `AB1234` and `ab1234` are different strings.  
**Fix:** `const normalised = code.toUpperCase(); valid.push(normalised)` — always push the normalised form.  
**Rule:** When normalising for dedup, push the normalised form into the output, not the original. The normalised form is what gets stored in the DB, so the output must match exactly.

---

#### 16. `withTransaction` used an overloaded signature with a runtime `typeof` check
**Mistake:** A single `withTransaction` function accepted either `(fn)` or `(pool, fn)` and used `typeof` at runtime to distinguish them.  
**Root cause:** Tried to make a convenience API but produced a fragile overloaded function with a non-null assertion (`fn!`).  
**Fix:** Split into two unambiguous exported functions: `withTransaction(fn)` uses the singleton pool; `withTransactionOn(pool, fn)` accepts an explicit pool. Used `withTransactionOn` in services that receive the pool as a parameter (e.g., tests use a separate test pool).  
**Rule:** Don't overload functions with mixed argument positions. Two clear function names are always better than a runtime type-switch. Services that take a `Pool` parameter must use `withTransactionOn`.

---

#### 17. `import 'dotenv/config'` must be the very first import in server.ts
**Mistake:** Used `require('dotenv').config()` as a function call early in `server.ts`, or placed the dotenv import after other imports.  
**Root cause:** TypeScript compiles `import` statements and hoists them — all `import` side effects run before any function call in the module body. If `config.ts` is imported before dotenv fires, it reads `process.env` before `.env` has been loaded.  
**Fix:** `import 'dotenv/config'` must be literally the first line of `server.ts` and `test/setup.ts`.  
**Rule:** dotenv must be a bare `import 'dotenv/config'` as the very first line of any entry point. A `require()` call or mid-file import will run too late because TypeScript hoists all imports.

---

#### 18. `uuidv4()` called per row in bulk insert — O(n) Node.js allocations for 1M rows
**Mistake:** Called `uuidv4()` in a loop to generate an ID for each eligible client row before inserting.  
**Root cause:** Didn't consider that PostgreSQL can generate UUIDs natively and that pushing 1M UUID strings from Node.js into a parameterized query is expensive.  
**Fix:** Use `gen_random_uuid()` directly in the SQL `VALUES` clause. Restructure params as `[...codes, experimentId, uploadBatchId]` with per-code placeholders `$1…$n` and shared params at positions `$n+1`, `$n+2`.  
**Rule:** Never generate UUIDs in Node.js for bulk inserts. Use `gen_random_uuid()` in the SQL. For a 5K-row batch this avoids 5000 crypto calls and 5000 string allocations per batch.

---

#### 19. Dead code exported but never called — dead weight on future implementors
**Mistake:** `downloadFromS3`, `deleteEligibleClientsBodySchema`, and `getEligibleExperimentIds` were all exported but never imported or called anywhere.  
**Root cause:** Wrote them speculatively ("might need this later") during initial implementation.  
**Fix:** Delete all three. `getEligibleExperimentIds` was particularly harmful — every future `EligibilityService` implementation would have had to implement a method that serves no caller.  
**Rule:** Do not export functions or types speculatively. If a function has no caller at the time it's written, don't write it. Dead exported symbols impose a maintenance burden on every future implementor of the same interface.
