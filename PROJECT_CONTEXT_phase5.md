# MOFSL Internal A/B Testing Platform — Master Project Context

> This document is the single source of truth for all decisions made during this project.
> Paste this at the start of every new Claude chat session to restore full context.
> Append new decisions to the relevant section as phases are completed.
> **Current state: Phase 7 complete (7A + 7B). 140 tests passing. Phase 8 (Backend / Control Plane) is next.**

---

## 1. Organisation & Product Context

- **Company:** Motilal Oswal Financial Services (MOFSL) — leading full-service stock broking firm in India, founded 1987, headquartered in Mumbai
- **Product being experimented on:** Riise — Flutter-based mobile trading app (formerly MO Investor), 40L+ (4 million+) customers, covers stocks, F&O, MFs, IPOs, commodities, US stocks, and insurance
- **Builder:** Internal platform team at MOFSL. The person leading this is a Product Manager with moderate technical knowledge — can read and understand code but does not have hands-on coding experience.

---

## 2. What We Are Building

An **internal, self-hosted, enterprise-grade A/B testing and feature flagging platform** for MOFSL.

### Core Model
- Treat this as a **SaaS product** where Riise is the first customer — the platform is fully self-contained and does not depend on Riise's infrastructure or data warehouse
- We are a **platform team** delivering an SDK to the Riise engineering team — we do not have access to the Riise codebase
- The Riise team integrates our Flutter SDK and decides where in their app to run experiments — we are not involved in their code
- The platform must be extensible to other MOFSL products beyond Riise in the future

### What We Are NOT Building
- We are not integrating directly into the Riise codebase
- We are not using an external SaaS platform (LaunchDarkly, Statsig, etc.)
- There are no SEBI or compliance constraints on this platform
- No experiment approval workflow needed in Phase 1 — PM self-serve

---

## 3. Architecture Model

**Primary reference: GrowthBook architecture**, augmented with patterns from three other platforms.

| Pattern | Source Platform |
|---|---|
| Local SDK evaluation, deterministic hash (MurmurHash3), self-hosted, warehouse-native analysis, open-source stats engine | GrowthBook |
| Type-safe SDK APIs, streaming (SSE), SDK-as-a-product philosophy, integration test harness, comprehensive docs | LaunchDarkly |
| ID list upload for file-based targeting, segment management UI | Statsig |
| `assignmentLogger` callback (decouple exposure logging from SDK), "initialize once, evaluate anywhere" | Eppo |

---

## 4. Five System Layers

### Layer 1 — Flutter SDK (delivered to Riise engineering team)
- Pure Dart implementation (no native wrappers — supports all platforms)
- Thin SDK: download config → evaluate locally → fire exposure callback
- No event ingestion built into SDK — Riise team implements the `onExposure` callback and logs to their own analytics pipeline
- Async, non-blocking initialization — never blocks Riise app's critical path
- Client code is the primary user identity, passed at initialization
- Additional attributes map supported (platform, app version, city, segment)
- Local config cache (SharedPreferences) with TTL and background refresh
- Deterministic assignment: same user always gets same variant, no network call at evaluation time
- Type-safe variation methods: `getBool()`, `getString()`, `getInt()`, `getJSON()`
- Forced variation override for QA testing
- Debug mode with verbose logging

### Layer 2 — Targeting Engine (file-upload pipeline)
- PM uploads CSV/Excel of eligible client codes via dashboard
- Validation: duplicate detection, format errors, row count limits
- Upload preview before confirmation
- Experiment-scoped lists (each experiment has its own eligible client pool)
- Eligibility resolved **server-side** at config generation time — SDK receives a config already scoped to the user, it does not know about the CSV layer
- Eligibility interface **abstracted behind a service layer** — data lake integration in Phase 2 is a drop-in replacement, no SDK or API contract changes required

### Layer 3 — Backend / Control Plane
- Experiment states: Draft → Running → Paused → Completed → Archived
- Traffic allocation percentage + variation weights
- Feature flags independent of experiments (simple on/off or value)
- Flags and experiments share the same evaluation model
- Kill switch: instantly disable any flag or experiment
- Attribute-based targeting rules on top of eligibility (platform, app version, etc.)
- Versioned config endpoint (SDK sends current version, only fetches if changed)
- Redis caching layer in front of config serving
- Audit log: every change logged with timestamp and actor

### Layer 4 — Data Plane & Stats Engine
- Platform owns its own event storage (SaaS model — Riise sends events to platform)
- Exposure events and conversion events ingested via API
- Events flow: API → Kafka → ClickHouse
- Stats engine: **simple frequentist for Phase 1** (t-test, p-value, confidence intervals, MDE, sample size calculator)
- Sequential testing, CUPED, Bayesian engine — Phase 2
- PM-defined conversion metrics and guardrail metrics
- Results: per-variant summary, significance status, time-series charts, winner declaration, CSV export

### Layer 5 — Internal Dashboard
- Experiment management UI with creation wizard
- Client list upload UI with validation feedback
- Flag management UI with evaluation preview
- Results UI with significance visualization
- SDK documentation portal (getting started, API reference, integration walkthrough, sample app, changelog)

---

## 5. Infrastructure & Tech Stack

| Component | Technology | Reason |
|---|---|---|
| Cloud Provider | AWS (ap-south-1 Mumbai) | Best India regional presence, managed services for all components |
| Container Orchestration | AWS ECS + Docker | Simpler than Kubernetes, production-grade, lower operational overhead |
| API Server | Node.js + TypeScript | Fast to build, strong ecosystem, matches GrowthBook architecture |
| Dashboard | Next.js (React) | Best for internal tools with data-heavy UIs |
| Flutter SDK | Pure Dart | No native wrappers, all-platform support |
| Transactional DB | PostgreSQL on AWS RDS | Strong consistency for experiments, flags, eligibility, audit |
| Event + Analytics DB | ClickHouse | Purpose-built for analytical queries at event scale (hundreds of millions of rows) |
| Event Queue | Kafka on AWS MSK | Decouples ingestion from storage, handles traffic spikes at 40L user scale |
| Cache | Redis on AWS ElastiCache | Config serving at scale, prevents DB overload |
| File Storage | AWS S3 | CSV uploads, config file distribution |
| Stats Engine | SQL queries on ClickHouse | T-test, p-value, confidence intervals computed via SQL |

### Infrastructure Diagram (High Level)
```
┌─────────────────────────────────────────────────────────────────┐
│                        AWS (ap-south-1)                         │
│                                                                 │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │
│  │  API Server  │    │  Dashboard  │    │   Config Server     │  │
│  │  (Node.js/  │    │  (Next.js)  │    │   (config fetch +   │  │
│  │  TypeScript) │    │             │    │    Redis cache)      │  │
│  └──────┬──────┘    └──────┬──────┘    └──────────┬──────────┘  │
│         │                  │                       │             │
│         ▼                  ▼                       ▼             │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                    PostgreSQL (RDS)                      │    │
│  │     Experiments · Flags · Eligible Clients · Audit      │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────┐   │
│  │ Event Ingest │───▶│  Kafka (MSK) │───▶│   ClickHouse     │   │
│  │     API      │    │              │    │  (events + stats) │   │
│  └──────────────┘    └──────────────┘    └──────────────────┘   │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐                           │
│  │    Redis     │    │   S3 Bucket  │                           │
│  │ (ElastiCache)│    │ (CSV uploads)│                           │
│  └──────────────┘    └──────────────┘                           │
│                                                                  │
│  All services run as Docker containers on ECS                   │
└─────────────────────────────────────────────────────────────────┘
          ▲                                  ▲
          │                                  │
   ┌──────────────┐                  ┌───────────────┐
   │  Riise App   │                  │  MOFSL PM     │
   │ (Flutter SDK)│                  │  (Dashboard)  │
   └──────────────┘                  └───────────────┘
```

---

## 6. SDK Contract (Agreed Interface for Riise Team)

```dart
// 1. Initialize once at app startup (async, non-blocking)
final experimentClient = await MofslExperiment.initialize(
  configUrl: "https://experiments.mofsl.com/api/v1/config",
  clientCode: currentUser.clientCode,
  attributes: {
    "platform": "android",
    "app_version": "5.2.1",
    "city": "Mumbai",
    "segment": "premium",
  },
  onExposure: (experiment, variation) {
    // Riise team implements this — logs to their analytics pipeline
    analytics.track("experiment_exposure", {
      "experiment_key": experiment.key,
      "variation": variation.key,
      "client_code": currentUser.clientCode,
    });
  },
);

// 2. Evaluate anywhere — synchronous, local, zero latency
final showNewChart = experimentClient.getBool("new_chart_ui", defaultValue: false);
final orderFlowVariant = experimentClient.getString("order_flow_v2", defaultValue: "control");
```

---

## 7. Architectural Decision Records (ADRs) — Completed in Phase 4

All ADRs are written and stored in `architecture/adr/`. Summary:

| ADR | Decision | Key Rationale |
|---|---|---|
| ADR-001 | **Local SDK evaluation** over server-side | Zero latency, offline resilience, 10× reduction in server load vs server-side eval |
| ADR-002 | **Eligibility service abstraction** | `EligibilityService` interface — file-upload (Phase 1) and data lake (Phase 2) are interchangeable implementations |
| ADR-003 | **Kafka between ingestion and ClickHouse** | Decouples ingestion from storage, 7-day event durability, handles trading-hours spikes |
| ADR-004 | **ECS over Kubernetes** | Lower operational overhead, Fargate eliminates EC2 management, appropriate for team's technical profile |
| ADR-005 | **Frequentist stats engine first** | T-test, z-test, p-value, CI — fast to implement, PM-familiar. Sequential testing + Bayesian in Phase 2 |
| ADR-006 | **Exposure callback pattern** | SDK fires `onExposure` callback, does not own event transport. Keeps SDK thin, Riise owns all network behavior |
| ADR-007 | **MurmurHash3 deterministic assignment** | `MurmurHash3(experimentKey + ":" + clientCode) % 10000` — 10K bucket space, 0.01% granularity, same as GrowthBook |
| ADR-008 | **PostgreSQL + ClickHouse polyglot persistence** | PostgreSQL for transactional (experiments, flags, eligibility), ClickHouse for analytical (events, stats) |
| ADR-009 | **Redis config caching** | >95% cache hit target, sub-10ms config latency, protects PostgreSQL from 5K req/sec SDK traffic |
| ADR-010 | **Internal SSO for dashboard** | MOFSL's existing IdP (SAML 2.0/OIDC), all users admin in Phase 1, RBAC schema designed-for Phase 2 |
| ADR-011 | **ETag-based config versioning** | SDK sends `If-None-Match`, server returns `304 Not Modified` when config unchanged — saves 95%+ bandwidth |

---

## 8. Phase 1 vs Phase 2 Scope

### Phase 1 (Build Now)
- Full Flutter SDK with local evaluation, caching, exposure callback, debug/QA mode
- File-upload targeting pipeline (CSV/Excel → PostgreSQL eligibility store)
- Experiment and flag management API + dashboard
- Config serving with Redis cache
- Event ingestion API → Kafka → ClickHouse
- Frequentist stats engine (t-test, p-value, confidence intervals, MDE, sample size calculator)
- Results dashboard (per-variant summary, significance, time-series, winner declaration)
- SDK documentation portal
- Audit log

### Phase 2 (Designed For, Built Later)
- Data lake connector (drop-in for file-upload eligibility layer)
- Streaming (SSE) for real-time config updates
- Sequential testing + CUPED variance reduction
- Bayesian stats engine
- Mutual exclusion across experiments
- Anonymous → authenticated identity transition in SDK
- OR logic and nested targeting conditions
- Dimensional results breakdown
- Interactive SDK playground
- Experiment approval workflow (if needed)

---

## 9. Build Approach & Claude Usage Rules

- **IDE:** VS Code with Claude Code CLI (terminal, not chat window)
- **This chat (Claude.ai):** Planning, research, architecture design, guidance — one chat per phase
- **Claude Code (terminal):** All actual building — code generation, file creation, refactoring, testing
- **Model usage:** Opus for architecture decisions, ADR creation, design reviews; Sonnet for all implementation
- **CLAUDE.md files:** One per module, created before any code is written, read automatically by Claude Code
- **Multi-agent:** Parallel Claude Code sessions for SDK, backend, dashboard, data pipeline once contracts are defined
- **Never cut corners. Never contradict prior decisions for convenience.**

### CLAUDE.md Files to Create (Phase 5)
- `/CLAUDE.md` — project overview, tech stack, conventions, what NOT to do
- `/sdk/CLAUDE.md` — Flutter SDK specifics, Dart conventions, SDK integration contract
- `/backend/CLAUDE.md` — API conventions, auth patterns, PostgreSQL schema summary
- `/dashboard/CLAUDE.md` — Next.js conventions, component library, design system
- `/data/CLAUDE.md` — ClickHouse schema, Kafka topics, event schemas

### Pre-Build Skills to Create (Phase 5)
- `ab-testing-domain.md` — experiment lifecycle, bucketing logic, flag evaluation, holdout groups, stat significance concepts
- `flutter-sdk-patterns.md` — Flutter/Dart SDK design conventions, package structure, pure Dart principles
- `file-based-targeting.md` — eligibility service interface, CSV ingestion, data lake swap pattern
- `stats-engine.md` — t-test, p-value, MDE, confidence intervals, frequentist methodology

---

## 10. Phases Completed

- [x] Phase 1 — Research & Competitive Analysis (Opus)
- [x] Phase 2 — Gap Mapping (Opus)
- [x] Phase 3 — Feature Finalization
- [x] Phase 4 — Architecture Design
- [x] Phase 5 — CLAUDE.md & Skill Creation
- [x] Phase 6 — Client Targeting Ingestion Pipeline
- [x] Phase 7 — SDK Development (Flutter) — complete
  - [x] Phase 7A — Package scaffold, data models, config cache, config loader, logger, version, tests (27 test cases)
  - [x] Phase 7B — MurmurHash3, bucket mapper, evaluator, exposure tracker, MofslExperiment client, full test suite (113 test cases)
- [ ] Phase 8 — Backend / Control Plane
- [ ] Phase 9 — Data Plane & Stats Engine
- [ ] Phase 10 — Internal Dashboard
- [ ] Phase 11 — SDK Documentation & Developer Experience
- [ ] Phase 12 — Testing, Observability & Hardening
- [ ] Phase 13 — Internal Rollout

---

## 11. Decisions Resolved in Phase 4

| Question | Resolution |
|---|---|
| PostgreSQL schema | 16 tables: `applications`, `api_keys`, `users`, `experiments`, `variations`, `feature_flags`, `targeting_rules`, `eligible_clients`, `client_list_uploads`, `metrics`, `experiment_metrics`, `forced_variations`, `audit_log`, `config_versions` + triggers + seed data. Full DDL in `schemas/postgresql_schema.sql` |
| Kafka topic design | 2 topics: `exp.exposures` (partitioned by `experimentKey`, 8 partitions) and `exp.conversions` (partitioned by `clientCode`, 8 partitions). 3 MSK brokers, replication factor 3, 7-day retention. Full config in `schemas/KAFKA_TOPICS.md` |
| ClickHouse schema | `exposure_events` and `conversion_events` tables (ReplacingMergeTree, partitioned by month, TTL 1 year). Kafka engine source tables + materialized views for ingestion. Pre-aggregated MVs for stats engine (`mv_daily_exposures`, `mv_daily_conversions`). Full DDL in `schemas/clickhouse_schema.sql` |
| SDK ↔ Config Server API | `GET /api/v1/config?clientCode={code}&attributes={json}` with `X-API-Key` header and `If-None-Match` ETag. Returns `200` with experiments + features + forcedVariations payload, or `304 Not Modified`. Full contract in `api/CONFIG_SERVER_API.md` |
| Event Ingestion API | `POST /api/v1/events` with batch of exposure and conversion events (max 1000 per batch). Returns `202 Accepted`. Supports idempotency keys for dedup. Full contract in `api/EVENT_INGESTION_API.md` |
| Dashboard authentication | MOFSL internal SSO (SAML 2.0/OIDC). All authenticated users get `admin` role in Phase 1. RBAC designed-for in schema (`role` column on `users` table). SDK/event APIs use application-level API keys (`X-API-Key` header). |
| Bucketing algorithm | `MurmurHash3_x86_32(experimentKey + ":" + clientCode, seed=0) % 10000` — 10K bucket space. Coverage determines inclusion, weights determine variation assignment. |
| Config versioning | ETag-based. Server computes SHA-256 hash of serialized config. SDK sends `If-None-Match` → server returns `304` if unchanged. Version hash stored in Redis for O(1) lookup. |
| Conversion event → experiment attribution | Conversions are NOT tied to experiments at ingestion time. Stats engine joins `conversion_events` to `exposure_events` on `client_code` + time window (conversion within 30 days of exposure) at query time. |
| ECS compute sizing | 5 services on Fargate: config-server (2–10 tasks), control-plane (2–6), event-ingest (2–10), kafka-consumer (2–6), dashboard (2–4). Auto-scaling on CPU 60%. |

---

## 12. Phase 4 Outputs — Architecture Artifacts

All files stored in `architecture/` directory in the repository:

```
architecture/
├── ARCHITECTURE.md                          # Master architecture document (13 sections)
├── adr/
│   ├── ADR-001-local-sdk-evaluation.md
│   ├── ADR-002-eligibility-service-abstraction.md
│   ├── ADR-003-kafka-event-pipeline.md
│   ├── ADR-004-ecs-over-kubernetes.md
│   ├── ADR-005-frequentist-stats-first.md
│   ├── ADR-006-exposure-callback-pattern.md
│   ├── ADR-007-murmurhash3-deterministic-assignment.md
│   ├── ADR-008-polyglot-persistence.md
│   ├── ADR-009-redis-config-caching.md
│   ├── ADR-010-dashboard-auth.md
│   └── ADR-011-config-versioning-etag.md
├── api/
│   ├── CONFIG_SERVER_API.md                 # SDK ↔ Config Server contract
│   └── EVENT_INGESTION_API.md               # Riise App ↔ Event Ingestion contract
└── schemas/
    ├── postgresql_schema.sql                # 16 tables, full DDL with indexes + triggers
    ├── clickhouse_schema.sql                # Event tables, Kafka engine, MVs, stats views
    └── KAFKA_TOPICS.md                      # Topic config, producer/consumer settings, monitoring
```

### Key Architecture Highlights (for quick reference in future chats)

**Scale targets:** 5K config fetches/sec, 10K events/sec ingestion, 100K concurrent SDK connections, 50 concurrent experiments, up to 1M eligible clients per experiment.

**Config serving path:** SDK → ALB → Config Server → Redis (95%+ hit) → PostgreSQL (fallback) → SDK gets scoped config payload (<50 KB). ETag-based `304` for unchanged configs.

**Event pipeline path:** Riise App → ALB → Event Ingestion API → validates + enriches → Kafka (exp.exposures / exp.conversions) → ClickHouse Kafka engine → materialized views → stats engine queries.

**Stats engine:** Welch's t-test (continuous), two-proportion z-test (binary), computed in TypeScript from ClickHouse aggregates. Pre-aggregated materialized views for performance. Winner declared when p < α AND minimum sample size reached.

**Security:** External ALB (SDK/events traffic) + Internal ALB (dashboard). WAF on external. Dashboard behind VPN/IP allowlist. API keys (bcrypt-hashed) for SDK/events. JWT from SSO for dashboard.

**Networking:** Dedicated VPC, public subnets for ALBs only, private subnets for all services and databases. All traffic TLS 1.2+.

---

## 13. Phase 5 Outputs — CLAUDE.md & Skill Files

All files stored in the repository:

```
mofsl-experimentation/
├── CLAUDE.md                              ← project-wide conventions, tech stack, naming rules, what NOT to do
├── sdk/
│   └── CLAUDE.md                          ← pure Dart SDK: package structure, evaluation algorithm, caching, exposure rules, error handling
├── backend/
│   └── CLAUDE.md                          ← Node.js/TS: project structure, config generator pipeline, eligibility interface, lifecycle rules, audit rules
├── dashboard/
│   └── CLAUDE.md                          ← Next.js: page inventory, creation wizard steps, auth flow, results visualization, component library
├── data/
│   └── CLAUDE.md                          ← ClickHouse schema reference, Kafka topics, stats engine architecture, query patterns
└── skills/
    ├── ab-testing-domain.md               ← experiment lifecycle, bucketing logic, exposure dedup, metrics, significance concepts
    ├── flutter-sdk-patterns.md            ← pure Dart principles, API design, error handling philosophy, MurmurHash3, caching patterns
    ├── file-based-targeting.md            ← EligibilityService interface, CSV pipeline, validation, bulk insert, Phase 2 swap pattern
    └── stats-engine.md                    ← z-test, t-test formulas, normal/t CDF implementations, sample size calc, winner declaration, test validation
```

### Key Conventions Established in Phase 5

- **TypeScript:** camelCase files, PascalCase classes, no `any` types, Zod for validation, Pino for logging
- **Dart:** snake_case files, PascalCase classes, pure Dart only, hand-written JSON parsing, no code generation
- **API:** REST/JSON, `/api/v1/` versioned, cursor-based pagination, standard error format
- **Testing:** 90%+ SDK, 85%+ backend, 70%+ dashboard, 95%+ stats engine math module
- **Git:** conventional commits, `feature/{module}/{description}` branches

---

## 14. Phase 6 Outputs — Client Targeting Ingestion Pipeline

### What Was Built

The backend service (`/backend`) is a fully functional Node.js + TypeScript Express server with the eligibility ingestion pipeline working end-to-end. 43 tests (unit + integration) pass against real PostgreSQL and Redis via Docker.

**Project scaffold:**
```
backend/
├── src/
│   ├── server.ts                          ← Express app, middleware, route mounting, graceful shutdown
│   ├── config.ts                          ← Zod-validated env vars (DATABASE_URL, Redis, S3, JWT, etc.)
│   ├── db/
│   │   ├── postgres.ts                    ← pg Pool, withTransaction(fn), withTransactionOn(pool, fn)
│   │   ├── redis.ts                       ← ioredis client, connectRedis(), closeRedis()
│   │   ├── migrate.ts                     ← Migration runner (schema_migrations table)
│   │   └── migrations/001_initial_schema.sql  ← Full PostgreSQL schema (16 tables)
│   ├── services/
│   │   ├── eligibility/
│   │   │   ├── eligibility.interface.ts   ← EligibilityService: isEligible(), bulkCheckEligibility()
│   │   │   └── file-upload.eligibility.ts ← Phase 1 impl: queries eligible_clients table
│   │   ├── upload.service.ts              ← parseFile(), validateClientCodes(), processUpload()
│   │   ├── audit.service.ts               ← Append-only audit log writer
│   │   └── cache.service.ts               ← Redis cache ops (config, API key, idempotency)
│   ├── routes/
│   │   ├── eligibility.routes.ts          ← Upload, list, delete endpoints
│   │   └── health.routes.ts               ← GET /health
│   ├── middleware/
│   │   ├── auth.middleware.ts             ← JWT validation (requireAuth)
│   │   ├── api-key.middleware.ts          ← X-API-Key validation with Redis bcrypt cache
│   │   └── error-handler.middleware.ts    ← Global handler (AppError, multer, Zod, generic 500)
│   ├── validators/
│   │   └── upload.validator.ts            ← uploadQuerySchema, listQuerySchema
│   └── utils/
│       ├── s3.ts                          ← uploadToS3() only (LocalStack-compatible)
│       ├── errors.ts                      ← AppError, NotFoundError, ValidationError, PayloadTooLargeError
│       └── logger.ts                      ← Pino structured JSON logger
├── test/
│   ├── setup.ts                           ← dotenv + test env defaults, LOG_LEVEL=silent
│   ├── unit/
│   │   ├── services/upload.validation.test.ts   ← 29 tests: CSV/Excel parsing, code validation
│   │   └── services/file-upload.eligibility.test.ts ← isEligible, bulkCheckEligibility
│   └── integration/
│       └── eligibility.integration.test.ts      ← Full HTTP integration tests against real DB
├── docker-compose.yml                     ← postgres:15, redis:7, localstack:3 (auto-creates S3 bucket)
└── package.json
```

### API Endpoints Built

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/v1/experiments/:id/eligible-clients/upload?mode=replace\|append` | Upload CSV/Excel file of client codes |
| `GET` | `/api/v1/experiments/:id/eligible-clients` | List upload batches with cursor pagination |
| `DELETE` | `/api/v1/experiments/:id/eligible-clients` | Clear all eligible clients for experiment |
| `DELETE` | `/api/v1/experiments/:id/eligible-clients/batches/:batchId` | Remove one upload batch |
| `GET` | `/health` | Health check |

### Key Implementation Decisions Made in Phase 6

| Decision | What was chosen | Why |
|---|---|---|
| `uploaded_by` and `actor_id` | Always `null` until Phase 8 | These are FKs to `users(id)` — no user rows exist until SSO is built |
| Actor identity tracking | `actor_email` text column in `audit_log` | Denormalized text survives without the users FK; filled from JWT claims |
| API key validation caching | bcrypt result cached in Redis `apikey:validated:{prefix}`, TTL 5 min | bcrypt is ~100ms; direct use would collapse at 5K req/s |
| DELETE endpoint design | Sub-resource URL `/batches/:batchId` instead of DELETE-with-body | ALB and many proxies strip DELETE request bodies |
| Transaction helpers | Two functions: `withTransaction(fn)` and `withTransactionOn(pool, fn)` | Services receive a `Pool` param (for test isolation) — `withTransactionOn` avoids runtime type-switching |
| UUID generation in bulk insert | `gen_random_uuid()` in SQL `VALUES` clause | Avoids generating 1M UUIDs in Node.js per upload; param layout: `[$1…$n=codes, $n+1=experimentId, $n+2=uploadBatchId]` |
| Client code normalisation | Stored as `UPPERCASE` | MOFSL client codes are case-insensitive; `AB1234` and `ab1234` are the same client |
| Upload mode | Synchronous (blocking HTTP connection) | Known Phase 10 concern — for 1M-row files this holds the connection ~20s. `status` column exists for future async pattern |
| Service instantiation | Module-level singletons in route files | Services are stateless pool wrappers; per-request `new AuditService(pool)` wastes GC |
| dotenv load order | `import 'dotenv/config'` as literal first import | TypeScript hoists all `import` statements — a `require()` call runs after `config.ts` has already read `process.env` |

### EligibilityService Interface (Final — Phase 6)

```typescript
interface EligibilityService {
  // Returns true if experiment has no list (open to all) OR client is in the list
  isEligible(clientCode: string, experimentId: string): Promise<boolean>;

  // Batch-checks eligibility for multiple experiments in one SQL query
  // Returns Map<experimentId, isEligible>
  bulkCheckEligibility(clientCode: string, experimentIds: string[]): Promise<Map<string, boolean>>;
}
```

Note: `getEligibleExperimentIds` was removed — it had no callers and would have forced every future implementation to stub it. The config generator will use `bulkCheckEligibility`.

### Test Coverage

- **29 unit tests** — CSV/Excel parsing (BOM, header detection, empty files, encoding), client code validation (alphanumeric rules, dedup, case-normalisation), eligibility service (open experiments, restricted experiments, bulk check)
- **14 integration tests** — full HTTP round-trips against real PostgreSQL + Redis: upload replace/append, list pagination, delete batch, delete all, experiment-not-found 404, invalid file 400, oversized file 413

---

## 15. Open Decisions / To Be Resolved in Phase 7+

- SDK package name and distribution method (pub.dev vs internal git package vs private Dart package server)
- Internal product name for the platform (used in dashboard, docs, SDK package name)
- Exact MOFSL SSO IdP details (SAML 2.0 vs OIDC, redirect URIs, token claims)
- MSK broker endpoints (placeholder in ClickHouse Kafka engine config)
- RDS instance sizing finalization (estimated `db.r6g.large` but depends on load testing)
- ClickHouse deployment model (self-hosted on EC2 vs ClickHouse Cloud)
- GitHub repository structure (monorepo vs multi-repo — monorepo recommended)
- CI/CD pipeline details (GitHub Actions workflow specifics)
- Domain name for config/event endpoints (placeholder: `experiments.mofsl.com`)

---

---

## 16. Phase 7A Decisions & What 7B Needs to Know

### Package: `mofsl_experiment` (resolved)
- Package name: `mofsl_experiment` (not `mofsl_sdk`, not `riise_experiments`)
- Distribution: git package for now (`path:` dep in host app during dev, later pub.dev or private server)
- Pure Dart, no Flutter widget imports, no `dart:io`

### Data model decisions (locked — do not change)
- `Variation.value` is `dynamic` — handles bool/String/int/Map uniformly across experiment types
- `Experiment.seed` defaults to `experiment.key` when `seed` field is absent from JSON
- `SdkConfig.forcedVariations` contains **server-side** forced variations (from config payload). **Client-side** forced variations are passed via `initialize(forcedVariations: {...})` and override server-side ones.
- ETag stored as raw version string (not quoted). The `If-None-Match` header adds quotes: `'"$etag"'`

### Config layer decisions (locked)
- `ConfigCache` takes `SharedPreferences` instance via constructor (not a static wrapper) — required for testability
- `ConfigLoader.fetch()` is the only public method — no separate "load from cache" — callers get `SdkConfig?`
- `unawaited(_cache.save(...))` — cache write never blocks the fetch return path
- `TimeoutException` caught separately from general `Exception` so the log message is specific

### What 7B built (evaluation + exposure + client) — COMPLETE

All files in `sdk/lib/src/`:

- `evaluation/hasher.dart` — MurmurHash3 x86 32-bit. All intermediates masked with `& 0xFFFFFFFF`. `_multiply32` uses 16-bit split trick. Tail uses if-chains (no switch fallthrough in Dart 3). `murmurhash3('') == 0`.
- `evaluation/bucket_mapper.dart` — `mapBucket(bucket, coverage, weights)`. Coverage check: `bucket >= coverage * 10000 → null`. Cumulative weight walk: `cumulative += weight * 10000; if bucket < cumulative → return index`.
- `evaluation/evaluator.dart` — Stateless `const Evaluator()`. `evaluateExperiment` follows 6-step algorithm. Hash input: `experiment.seed + ":" + clientCode` (seed, NOT key). `evaluateFlag` returns flag value or null. `computeBucket` helper for debug logging.
- `exposure/exposure_tracker.dart` — `Set<String> _firedExposures`. Null callback does NOT mark experiment as fired (allows later real callback). `reset()` clears state.
- `client.dart` — `MofslExperiment` with `static Future<MofslExperiment> initialize(...)`. Cache-first init (background fetch if cached, awaited if not). `getBool/getString/getInt/getJSON` sync, try-catch, return defaultValue. `dispose()` cancels timer + resets tracker + closes http client. `httpClientOverride` param for test injection.
- `mofsl_experiment.dart` barrel — exports only `MofslExperiment`, `Experiment`, `Variation`.

### Key design decisions locked in 7B
- `forcedVariations` merged at client level: `{...config.forcedVariations, ...sdkLevel}` — SDK wins
- Exposure NOT fired for forced variations; client checks `merged.containsKey(key)` before calling tracker
- Feature flag evaluated only if experiment returns null — prevents false exposure fires
- pubspec declares `flutter: sdk: flutter` and `flutter_test: sdk: flutter` — required because `shared_preferences` depends on `dart:ui`; tests run with `flutter test`, not `dart test`

### Phase 7B test results — 113 tests, all passing
- `test/evaluation/hasher_test.dart` — determinism, range, chi-square (100K inputs, 10K buckets, χ² < 10090), stddev, byte-boundary (1–5 bytes), empty string → 0
- `test/evaluation/bucket_mapper_test.dart` — 0%/50%/80%/100% coverage, 50-50/33-33-34/zero-weight splits
- `test/evaluation/evaluator_test.dart` — all branches; seed test uses `computeBucket` with same key + different seeds to assert different buckets (proves seed, not key, is hashed)
- `test/exposure/exposure_tracker_test.dart` — first fires, second doesn't, multi-exp independence, null callback (doesn't mark fired), reset
- `test/client_test.dart` — typed getter values + type fallback, exposure once, no exposure for flags/forced, dispose, refresh
- `test/integration/full_flow_test.dart` — full lifecycle: init → eval → exposure once → no re-fire → flag eval → paused/missing defaults → dispose → network-fail fallback

### Implementation mistakes & lessons from Phase 7 (append to CLAUDE.md log)
| # | What broke | Root cause | Rule |
|---|---|---|---|
| 1 | `returnsNormally` with async function always passed | `returnsNormally` only checks synchronous throw; the Future's failure is never observed | Never use `returnsNormally` with async functions — use `await fn()` directly or `await expectLater(fn(), completes)` |
| 2 | Test name said "returns null" but assertion was `isNotNull` | Copy-paste | Test name must match assertion exactly |
| 3 | `dart test` failed with `dart:ui` not available | `shared_preferences` → Flutter → `dart:ui`; package was declared as pure Dart | Any package using `shared_preferences` must declare `flutter: sdk: flutter` and run tests with `flutter test` |
| 4 | `avoid_dynamic_calls` lint on `$flagValue` interpolation | String interpolation on `dynamic` calls implicit `.toString()` which triggers the lint | Cast to `Object` before interpolating dynamic values: `${flagValue as Object}` |

*Last updated: Phase 7 complete (7A + 7B). 140 tests passing. Ready for Phase 8 — Backend / Control Plane.*
