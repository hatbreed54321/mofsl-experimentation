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

> Running log of real mistakes made during implementation. Each entry: what broke, why, and the rule that prevents it. Add new entries at the bottom as phases progress.

### Phase 6 — Client Targeting Ingestion Pipeline

| # | What broke | Root cause | Rule |
|---|---|---|---|
| 1 | Config Zod schema rejected `NODE_ENV=test` and `LOG_LEVEL=silent` | Only modeled production values | Always include `test` in `NODE_ENV` enum and `silent` in `LOG_LEVEL` enum |
| 2 | `@types/dotenv` doesn't exist as a package | Reflex `@types/*` for every dep | `dotenv`, `uuid`, `zod`, `pino`, `ioredis` ship their own types — no `@types/` needed |
| 3 | `docker-compose.yml` printed version warning | Copied old template with `version: '3.9'` | Never include `version:` — Compose v2 doesn't need it |
| 4 | Jest coverage config silently ignored | Used `coverageThresholds` (plural) — key is `coverageThreshold` | Jest config key is singular: `coverageThreshold` |
| 5 | `uploaded_by` FK caused 500 in integration tests | Passed JWT user ID into FK referencing `users(id)` — no user rows exist until Phase 8 SSO | Until Phase 8: every FK to `users(id)` must be `null`; track actor via `actor_email` text column only |
| 6 | `audit_log.actor_id` same FK crash | Same as above | `actor_id = null` always until Phase 8. `actor_email` is the authoritative actor field |
| 7 | `EADDRINUSE :3000` when tests imported server.ts | `start()` called at module level with no guard | Wrap `start()` with `if (require.main === module)`; export `app` separately |
| 8 | Jest hung after tests passed | Singleton `pool` + `redis` kept connections open | Integration test `afterAll` must call `closePool()` + `closeRedis()`; `forceExit` is a safety net only |
| 9 | Transaction helper duplicated inside upload.service.ts | Wrote local `runInTransaction` without checking existing utils | Never write local transaction wrappers — use `withTransaction` / `withTransactionOn` from `src/db/postgres.ts` |
| 10 | Multer file-size error returned 500 instead of 413 | Error handler only checked `instanceof AppError`; `multer.MulterError` is a different class | Every new middleware with typed errors needs a matching `instanceof` branch in `error-handler.middleware.ts` |
| 11 | S3 key broke on filenames with spaces/Unicode | Used raw `file.originalname` in key | Sanitize user-controlled strings before S3 keys/paths: keep `[A-Za-z0-9._-]`, replace rest with `_` |
| 12 | bcrypt on every request would collapse at 5K req/s | ~100ms per compare, no caching | Cache validated API key in Redis: `apikey:validated:{prefix}` → `{id, applicationId}`, TTL 5 min |
| 13 | DELETE body stripped by ALB/proxies | Used DELETE-with-body for scoped deletes | Never use DELETE with a body — encode scope in the URL: `DELETE /batches/:batchId` |
| 14 | `new AuditService(pool)` constructed per request | Copy-paste inside route handler | Services are stateless pool wrappers — instantiate once at module scope, reuse as singleton |
| 15 | Mixed-case client codes hit DB unique constraint | `seen.add(code.toUpperCase())` but `valid.push(code)` (original case) | When normalising for dedup, push the normalised form — it must match exactly what gets stored in the DB |
| 16 | `withTransaction` overload used runtime `typeof` + `fn!` non-null assertion | Tried to merge two signatures into one function | Split into two named functions: `withTransaction(fn)` (singleton pool) and `withTransactionOn(pool, fn)` (explicit pool) |
| 17 | `config.ts` read env vars before dotenv loaded them | `require('dotenv').config()` call runs after TypeScript hoists all `import` statements | `import 'dotenv/config'` must be the literal first line of `server.ts` and `test/setup.ts` |
| 18 | `uuidv4()` called per row — 1M allocations for 1M-row upload | Didn't use Postgres native UUID generation | Use `gen_random_uuid()` in SQL `VALUES`; pass codes + shared params as `[$1…$n, experimentId, uploadBatchId]` |
| 19 | Dead exports (`downloadFromS3`, `deleteEligibleClientsBodySchema`, `getEligibleExperimentIds`) forced every future implementor to carry unused methods | Speculative "might need later" exports | Never export without a caller. Interface methods with no caller force every future implementation to stub them needlessly |

### Phase 7A — SDK Foundation (package scaffold, config models, HTTP client, cache)

| # | What broke | Root cause | Rule |
|---|---|---|---|
| 1 | `expect(() async => cache.clear(), returnsNormally)` always passed even when `clear()` would fail | `returnsNormally` only checks that calling the function doesn't throw *synchronously* — it receives the `Future` back and considers that a normal return. The Future's success or failure is never checked. | Never use `returnsNormally` with an async function. Use `await fn()` directly (an unhandled exception fails the test), or `await expectLater(fn(), completes)` when you want an explicit assertion. |
| 2 | Test named "returns null for invalid JSON body" asserted `isNotNull` | Copy-paste of test name without updating it to match what the assertion actually checks | Test name must match the assertion. If the code falls back to cache (returns non-null), the test name must say "falls back to cache for …", not "returns null for …". Mismatched names make failures misleading. |

### Phase 7B — SDK Evaluation Engine & Public API

| # | What broke | Root cause | Rule |
|---|---|---|---|
| 1 | `dart test` failed with `dart:ui not available on this platform` | `shared_preferences` → `shared_preferences_platform_interface` → `flutter` → `dart:ui`. Package was declared as pure Dart with no Flutter SDK constraint. | Any package using `shared_preferences` must declare `flutter: '>=3.0.0'` in environment, add `flutter: sdk: flutter` to dependencies, and run tests with `flutter test` — not `dart test`. |
| 2 | `avoid_dynamic_calls` lint on `'Flag $key: value=$flagValue'` | String interpolation on a `dynamic` variable calls implicit `.toString()`, which triggers `avoid_dynamic_calls`. | Cast to `Object` before interpolating any `dynamic` value: `'value=${flagValue as Object}'`. Safe when a null-check immediately precedes the cast. |
| 3 | Seed test was tautological — always passed even if evaluator used key instead of seed | Used `weights: [1.0]` making all users land on variation 0 regardless of hash; the test never actually exercised the hash input | When testing which field is used as hash input, use `computeBucket` with two configs sharing the same key but different seeds and assert different bucket values for the same clientCode. |
| 4 | `mockito` and `build_runner` added to `dev_dependencies` | Reflex dependency addition at project setup; CLAUDE.md explicitly forbids `build_runner` | Never add `build_runner` or `mockito` to this SDK. Use `FakeHttpClient extends http.BaseClient` — override `send()` directly. No code generation needed. |
