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
