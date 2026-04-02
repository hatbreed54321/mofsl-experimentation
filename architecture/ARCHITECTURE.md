# MOFSL Experimentation Platform — Architecture Document

> **Status:** Approved (Phase 4)
> **Last Updated:** 2026-04-01
> **Owner:** Platform Team, MOFSL
> **Classification:** Internal — Confidential

---

## 1. Executive Summary

This document defines the architecture of MOFSL's internal experimentation platform — a self-hosted, enterprise-grade A/B testing and feature flagging system. The platform is designed as a standalone SaaS-style product where the Riise mobile trading app (40L+ customers) is the first client, with extensibility to all MOFSL products.

The architecture follows a **local-evaluation SDK model** inspired by GrowthBook, with patterns drawn from LaunchDarkly (type-safe SDKs, streaming), Statsig (ID-list targeting), and Eppo (decoupled exposure logging). The system comprises five layers: Flutter SDK, Targeting Engine, Control Plane, Data Plane, and Internal Dashboard.

---

## 2. Guiding Principles

| Principle | Implication |
|---|---|
| **Zero-latency evaluation** | SDK evaluates locally from cached config; no network call at evaluation time |
| **Platform as a product** | Platform team delivers SDK + APIs; Riise team integrates independently |
| **Decoupled exposure logging** | SDK fires a callback; it does not own the event transport |
| **Designed for Phase 2** | Every interface is abstracted for future extension (data lake, SSE, Bayesian) without contract-breaking changes |
| **Operational simplicity** | ECS over Kubernetes; managed AWS services over self-hosted equivalents |
| **Deterministic assignment** | Same user + same experiment always yields same variant — no randomness at runtime |
| **Audit everything** | Every mutation to experiments, flags, and eligibility lists is logged with actor and timestamp |

---

## 3. System Context

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          MOFSL Internal Network                             │
│                                                                             │
│  ┌──────────────┐          ┌──────────────────────────────────────────────┐ │
│  │  Riise App   │          │       Experimentation Platform               │ │
│  │  (Flutter)   │          │                                              │ │
│  │              │  HTTPS   │  ┌────────────┐  ┌────────────────────────┐  │ │
│  │  ┌────────┐  │ ────────▶│  │  Config    │  │  Event Ingestion API  │  │ │
│  │  │ MOFSL  │  │          │  │  Server    │  │                        │  │ │
│  │  │  SDK   │  │          │  └────────────┘  └────────────────────────┘  │ │
│  │  └────────┘  │          │                                              │ │
│  └──────────────┘          │  ┌────────────┐  ┌─────────┐  ┌──────────┐  │ │
│                            │  │  Control   │  │  Stats  │  │Dashboard │  │ │
│  ┌──────────────┐          │  │  Plane API │  │  Engine │  │ (Next.js)│  │ │
│  │  MOFSL PM    │  HTTPS   │  └────────────┘  └─────────┘  └──────────┘  │ │
│  │  (Browser)   │ ────────▶│                                              │ │
│  └──────────────┘          └──────────────────────────────────────────────┘ │
│                                                                             │
│  ┌──────────────┐                                                           │
│  │ Future MOFSL │  Same SDK + APIs                                         │
│  │   Products   │ ──────────────▶                                          │
│  └──────────────┘                                                           │
└─────────────────────────────────────────────────────────────────────────────┘
```

### External Actors

| Actor | Role | Interface |
|---|---|---|
| **Riise App** | Consumes SDK, evaluates experiments, sends events | Flutter SDK, Event Ingestion API |
| **Riise Engineering Team** | Integrates SDK into Riise codebase | SDK package, SDK docs portal |
| **MOFSL Product Managers** | Create experiments, upload targets, view results | Dashboard |
| **Future MOFSL Products** | Same as Riise App | Same SDK (Dart) or future platform SDKs |

---

## 4. Logical Architecture — Five Layers

### Layer 1: Flutter SDK

**Responsibility:** Download config, evaluate experiments/flags locally, fire exposure callback.

```
┌─────────────────────────────────────────────────────────┐
│                     Flutter SDK                          │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │ ConfigLoader │  │  Evaluator   │  │  ExposureLog  │  │
│  │              │  │              │  │   Callback     │  │
│  │ - fetch()    │  │ - getBool()  │  │               │  │
│  │ - cache()    │  │ - getString()│  │ - onExposure()│  │
│  │ - refresh()  │  │ - getInt()   │  │               │  │
│  └──────┬───────┘  │ - getJSON()  │  └───────────────┘  │
│         │          │              │                      │
│         ▼          │ - hash()     │                      │
│  ┌──────────────┐  │ (MurmurHash3│                      │
│  │SharedPrefs   │  │  bucketing)  │                      │
│  │  Cache       │  └──────────────┘                      │
│  └──────────────┘                                        │
└─────────────────────────────────────────────────────────┘
```

**Key behaviors:**
- Async initialization — never blocks app startup
- Config fetched once, cached in SharedPreferences with TTL
- Background refresh on configurable interval
- Evaluation is synchronous, local, zero-latency
- Deterministic hashing: `MurmurHash3(experimentKey + clientCode) mod 10000` yields bucket 0–9999
- `onExposure` callback fired on first evaluation per experiment per session — Riise team implements this
- Forced variation map for QA override
- Debug mode with verbose console logging

**Config flow:**
1. SDK calls `GET /config?clientCode={code}&version={hash}` at initialization
2. Config server checks eligibility, resolves targeting, returns scoped config
3. SDK caches config locally, uses cached version for all evaluations
4. Background timer re-fetches config on interval (default: 5 minutes)
5. If fetch fails, SDK continues with cached config (stale is better than broken)

### Layer 2: Targeting Engine

**Responsibility:** Determine which users are eligible for which experiments.

```
┌──────────────────────────────────────────────────────────┐
│                   Targeting Engine                         │
│                                                            │
│  ┌────────────────────────────────────────────────────┐   │
│  │          EligibilityService (Interface)             │   │
│  │                                                     │   │
│  │  isEligible(clientCode, experimentId) → boolean     │   │
│  │  getEligibleExperiments(clientCode) → experimentId[]│   │
│  └──────────┬───────────────────────┬─────────────────┘   │
│             │                       │                      │
│     ┌───────▼───────┐      ┌────────▼────────┐            │
│     │  FileUpload   │      │  DataLake       │            │
│     │  Impl (Ph.1)  │      │  Impl (Ph.2)    │            │
│     │               │      │                  │            │
│     │ CSV → validate│      │ Query → resolve  │            │
│     │ → PostgreSQL  │      │ → cache          │            │
│     └───────────────┘      └──────────────────┘            │
│                                                            │
│  ┌────────────────────────────────────────────────────┐   │
│  │          Attribute Targeting Rules                   │   │
│  │                                                     │   │
│  │  Evaluated AFTER eligibility check passes           │   │
│  │  platform = "android" AND app_version >= "5.0.0"    │   │
│  └────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

**Phase 1 flow:**
1. PM uploads CSV/Excel of client codes via dashboard
2. Backend validates file (format, duplicates, row count limit)
3. PM reviews preview → confirms upload
4. Client codes stored in `eligible_clients` table scoped to experiment
5. At config generation time, config server queries eligibility and only includes experiments the requesting client is eligible for

**Key design:** The `EligibilityService` interface is the same regardless of whether the source is a file upload or a data lake query. Phase 2 replaces the implementation without changing any API or SDK contract.

### Layer 3: Control Plane (Backend API)

**Responsibility:** Experiment/flag CRUD, config generation, eligibility management, audit logging.

```
┌────────────────────────────────────────────────────────────┐
│                      Control Plane                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │                  API Server (Node.js/TS)              │   │
│  │                                                       │   │
│  │  ┌──────────────┐  ┌───────────────┐  ┌───────────┐  │   │
│  │  │ Experiment   │  │ Flag          │  │ Targeting │  │   │
│  │  │ Service      │  │ Service       │  │ Service   │  │   │
│  │  └──────────────┘  └───────────────┘  └───────────┘  │   │
│  │                                                       │   │
│  │  ┌──────────────┐  ┌───────────────┐  ┌───────────┐  │   │
│  │  │ Config       │  │ Audit         │  │ Auth      │  │   │
│  │  │ Generator    │  │ Service       │  │ Service   │  │   │
│  │  └──────────────┘  └───────────────┘  └───────────┘  │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌────────────┐                │
│  │PostgreSQL│  │  Redis   │  │    S3      │                │
│  │  (RDS)   │  │(ElastiC.)│  │ (uploads)  │                │
│  └──────────┘  └──────────┘  └────────────┘                │
└────────────────────────────────────────────────────────────┘
```

**Experiment lifecycle:**

```
Draft ──▶ Running ──▶ Paused ──▶ Running ──▶ Completed ──▶ Archived
  │                      │                       │
  │                      └───────────────────────┘
  │                              (resume)
  └──▶ (delete — only from Draft)
```

**Config generation pipeline:**
1. SDK requests config for `clientCode=X`
2. Redis checked for cached config matching this client + config version
3. On cache miss: query PostgreSQL for all active experiments/flags
4. Filter by eligibility: only include experiments where client is in eligible list
5. For each eligible experiment, evaluate attribute targeting rules against client attributes
6. For passing experiments, compute variant assignment: `MurmurHash3(expKey + clientCode) % 10000` mapped to traffic allocation and variation weights
7. Assemble config payload, cache in Redis with TTL, return to SDK

### Layer 4: Data Plane & Stats Engine

**Responsibility:** Ingest exposure/conversion events, store in ClickHouse, compute experiment results.

```
┌─────────────────────────────────────────────────────────────┐
│                        Data Plane                            │
│                                                               │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐ │
│  │  Event       │     │              │     │              │ │
│  │  Ingestion   │────▶│  Kafka (MSK) │────▶│  ClickHouse  │ │
│  │  API         │     │              │     │              │ │
│  └──────────────┘     └──────────────┘     └──────────────┘ │
│                                                    │         │
│                                             ┌──────▼──────┐ │
│                                             │   Stats     │ │
│                                             │   Engine    │ │
│                                             │ (SQL-based) │ │
│                                             └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

**Event flow:**
1. Riise app sends exposure events (from `onExposure` callback) and conversion events to Event Ingestion API
2. API validates payload, enriches with server timestamp, publishes to Kafka
3. Kafka consumer (ClickHouse Kafka engine or dedicated consumer) writes to ClickHouse
4. Stats engine runs SQL queries on ClickHouse to compute results on demand

**Two Kafka topics:**
- `exp.exposures` — partitioned by experiment_id for ordering guarantees per experiment
- `exp.conversions` — partitioned by experiment_id

**Stats engine (Phase 1 — Frequentist):**
- Two-sample t-test for continuous metrics
- Two-proportion z-test for binary metrics
- P-value with configurable significance threshold (default α = 0.05)
- 95% confidence intervals
- Minimum Detectable Effect (MDE) calculator
- Sample size calculator (pre-experiment power analysis)
- Per-variant aggregations: count, mean, std dev, conversion rate
- Time-series data points for results visualization
- Winner declaration logic based on significance + minimum sample size

### Layer 5: Internal Dashboard

**Responsibility:** PM-facing UI for experiment management, targeting, results, SDK docs.

**Key pages:**
- Experiment list with status filters and search
- Experiment creation wizard (multi-step: name → targeting → variations → metrics → traffic → review)
- Experiment detail with live results
- Flag management (create, toggle, value editing)
- Client list upload with validation preview
- Results page with significance visualization, time-series charts, winner badge, CSV export
- Audit log viewer
- SDK documentation portal (getting started, API reference, integration walkthrough, sample app, changelog)

**Authentication:** Internal SSO via MOFSL's existing identity provider (SAML/OIDC). All dashboard users are MOFSL employees. No external access. Role model is simple for Phase 1: all authenticated users have full access. RBAC is a Phase 2 consideration.

---

## 5. Infrastructure Architecture

### 5.1 AWS Region & Networking

| Aspect | Decision |
|---|---|
| Region | `ap-south-1` (Mumbai) — lowest latency for Indian users |
| VPC | Dedicated VPC for experimentation platform |
| Subnets | Public subnets for ALB; private subnets for all services, databases |
| Security Groups | Least-privilege: SDK-facing services accept only HTTPS; databases accept only from ECS tasks |

### 5.2 Compute — ECS + Docker

All services run as Docker containers on AWS ECS (Fargate launch type for operational simplicity).

| Service | Container | Min Tasks | Max Tasks | CPU | Memory |
|---|---|---|---|---|---|
| Config Server | `config-server` | 2 | 10 | 512 | 1024 MB |
| Control Plane API | `control-plane` | 2 | 6 | 512 | 1024 MB |
| Event Ingestion API | `event-ingest` | 2 | 10 | 512 | 1024 MB |
| Kafka Consumer | `kafka-consumer` | 2 | 6 | 512 | 1024 MB |
| Dashboard | `dashboard` | 2 | 4 | 256 | 512 MB |

Auto-scaling based on CPU utilization (target 60%) and request count.

### 5.3 Load Balancing

- **External ALB** (internet-facing): Routes SDK traffic (`/config/*`, `/events/*`) — this is what the Riise app hits
- **Internal ALB**: Routes dashboard and control plane API traffic — only accessible within MOFSL network

### 5.4 Data Stores

| Store | Service | Instance | Storage | Backup |
|---|---|---|---|---|
| PostgreSQL | RDS | `db.r6g.large` | 100 GB gp3, auto-scaling | Daily automated snapshots, 7-day retention |
| ClickHouse | EC2 (self-managed) or ClickHouse Cloud | `r6g.xlarge` | 500 GB gp3 | Daily S3 backup |
| Redis | ElastiCache | `cache.r6g.large` | — | Multi-AZ with automatic failover |
| Kafka | MSK | `kafka.m5.large` × 3 brokers | 100 GB per broker | 7-day retention |
| S3 | S3 | — | — | Versioning enabled, lifecycle policy to archive after 90 days |

### 5.5 Deployment Pipeline

```
GitHub (monorepo)
    │
    ▼
GitHub Actions CI
    │
    ├── Lint + Unit Tests
    ├── Integration Tests
    ├── Docker Build
    ├── Push to ECR
    │
    ▼
ECS Rolling Deployment (zero-downtime)
```

---

## 6. Data Architecture

### 6.1 Polyglot Persistence Strategy

```
┌──────────────────┐     ┌──────────────────┐
│   PostgreSQL     │     │   ClickHouse      │
│   (Transactional)│     │   (Analytical)    │
│                  │     │                   │
│  • Experiments   │     │  • Exposure events│
│  • Flags         │     │  • Conversion     │
│  • Variations    │     │    events         │
│  • Eligible      │     │  • Pre-aggregated │
│    clients       │     │    metrics        │
│  • Targeting     │     │                   │
│    rules         │     │                   │
│  • Audit log     │     │                   │
│  • Users         │     │                   │
└──────────────────┘     └──────────────────┘
         │                        ▲
         │                        │
         ▼                        │
┌──────────────────┐     ┌──────────────────┐
│     Redis        │     │     Kafka        │
│   (Cache)        │     │   (Event Queue)  │
│                  │     │                  │
│  • SDK config    │     │  • exp.exposures │
│    payloads      │     │  • exp.conversions│
│  • Config version│     │                  │
│    hashes        │     │                  │
└──────────────────┘     └──────────────────┘
```

### 6.2 Config Versioning

The platform maintains a global config version — a SHA-256 hash of the serialized active config state. When any experiment, flag, variation, or targeting rule changes:

1. Control plane computes new config version hash
2. Redis cache for all affected clients is invalidated
3. SDK polls with `?version={currentHash}` — if hash matches, server returns `304 Not Modified`
4. On mismatch, server returns full config payload with new version hash

This ensures SDKs only download config when something actually changed, minimizing bandwidth and server load.

### 6.3 Event Schema Design

Events are immutable, append-only records. Two event types:

**Exposure Event:** Records that a user was shown a specific variant.
- Fired by Riise app via `onExposure` callback → sent to Event Ingestion API
- Deduplicated: one exposure per user per experiment per session

**Conversion Event:** Records that a user performed a target action.
- Fired by Riise app when conversion metric is triggered → sent to Event Ingestion API
- Attributed to experiment via client_code + experiment_key + timestamp windowing

---

## 7. Security Architecture

### 7.1 Authentication & Authorization

| Interface | Auth Method |
|---|---|
| Dashboard | MOFSL internal SSO (SAML 2.0 / OIDC) |
| Control Plane API | JWT issued by SSO provider, validated by API |
| Config Server (SDK) | API key per client application (e.g., Riise has one key) |
| Event Ingestion API | Same API key as config server |

**API keys** are long-lived, rotatable tokens scoped to a client application. They authenticate the calling app, not the end user. The end user's identity is the `clientCode` passed in the request body.

### 7.2 Network Security

- All external traffic over HTTPS (TLS 1.2+)
- SDK-facing endpoints behind AWS WAF with rate limiting
- Dashboard accessible only from MOFSL internal network (VPN or office IP allowlist)
- Database ports not exposed — only reachable from ECS task security groups
- S3 buckets are private, accessed via IAM roles attached to ECS tasks

### 7.3 Data Security

- Client codes are pseudonymous identifiers — no PII stored in the experimentation platform
- ClickHouse event data retained for 1 year, then TTL-deleted
- Audit log retained indefinitely
- S3 uploads encrypted at rest (SSE-S3)
- Database encryption at rest enabled on RDS and ElastiCache

---

## 8. Scalability & Performance

### 8.1 Scale Targets (Phase 1)

| Metric | Target |
|---|---|
| Concurrent SDK connections | 100,000 (peak trading hours) |
| Config fetches per second | 5,000 |
| Event ingestion per second | 10,000 |
| Active experiments | 50 concurrent |
| Eligible client lists | Up to 1M client codes per experiment |
| ClickHouse query (results page) | < 5 seconds for 30-day experiment |

### 8.2 Performance Design

- **Config serving:** Redis cache hit rate target > 95%. Cache warm-up on deployment. Config payload target < 50 KB compressed.
- **SDK initialization:** Target < 500ms on 4G connection (config fetch + parse + cache write)
- **Event ingestion:** Kafka absorbs write spikes; ClickHouse batch inserts via Kafka engine for throughput
- **Stats computation:** Pre-aggregated materialized views in ClickHouse for common queries; on-demand SQL for custom analysis

### 8.3 Resilience

- **SDK:** Falls back to cached config if network fails; falls back to default values if no config exists
- **Config server:** Redis failure → direct PostgreSQL query (degraded but functional)
- **Event ingestion:** Kafka provides durability — if ClickHouse consumer falls behind, events are buffered in Kafka (7-day retention)
- **Dashboard:** Read failures show stale data with "last updated" timestamp; write failures show clear error messages

---

## 9. Observability

### 9.1 Logging

- Structured JSON logs from all services
- Log levels: ERROR, WARN, INFO, DEBUG
- Shipped to CloudWatch Logs → optionally to a centralized log system
- Request ID propagated across all services for tracing

### 9.2 Metrics

| Metric | Source |
|---|---|
| Config fetch latency (p50, p95, p99) | Config server |
| Config cache hit rate | Redis |
| Event ingestion rate | Event API |
| Kafka consumer lag | MSK metrics |
| ClickHouse query latency | ClickHouse system tables |
| ECS task CPU/memory utilization | CloudWatch |
| API error rates (4xx, 5xx) | ALB + application |

### 9.3 Alerting

- Config server p99 latency > 500ms
- Redis cache hit rate < 80%
- Kafka consumer lag > 100,000 messages
- API 5xx rate > 1%
- ECS task restart count > 3 in 5 minutes
- ClickHouse disk usage > 80%

---

## 10. Architectural Decision Records

All major architectural decisions are documented in the `adr/` directory:

| ADR | Decision |
|---|---|
| [ADR-001](adr/ADR-001-local-sdk-evaluation.md) | Local SDK evaluation over server-side evaluation |
| [ADR-002](adr/ADR-002-eligibility-service-abstraction.md) | Eligibility service abstraction for file-upload and data-lake swap |
| [ADR-003](adr/ADR-003-kafka-event-pipeline.md) | Kafka between event ingestion and ClickHouse |
| [ADR-004](adr/ADR-004-ecs-over-kubernetes.md) | ECS over Kubernetes for container orchestration |
| [ADR-005](adr/ADR-005-frequentist-stats-first.md) | Frequentist statistics engine for Phase 1 |
| [ADR-006](adr/ADR-006-exposure-callback-pattern.md) | Exposure callback pattern — no event transport in SDK |
| [ADR-007](adr/ADR-007-murmurhash3-deterministic-assignment.md) | MurmurHash3 for deterministic variant assignment |
| [ADR-008](adr/ADR-008-polyglot-persistence.md) | PostgreSQL + ClickHouse polyglot persistence |
| [ADR-009](adr/ADR-009-redis-config-caching.md) | Redis caching layer for config serving |
| [ADR-010](adr/ADR-010-dashboard-auth.md) | Internal SSO for dashboard authentication |
| [ADR-011](adr/ADR-011-config-versioning-etag.md) | ETag-based config versioning for SDK polling |

---

## 11. API Contracts

Detailed API contracts are in the `api/` directory:

- [Config Server API](api/CONFIG_SERVER_API.md) — SDK ↔ Config Server contract
- [Event Ingestion API](api/EVENT_INGESTION_API.md) — Riise App ↔ Event Ingestion contract

---

## 12. Database Schemas

Detailed schemas are in the `schemas/` directory:

- [PostgreSQL Schema](schemas/postgresql_schema.sql) — Experiments, flags, eligibility, audit
- [ClickHouse Schema](schemas/clickhouse_schema.sql) — Exposure and conversion events
- [Kafka Topics](schemas/KAFKA_TOPICS.md) — Topic design and partitioning strategy

---

## 13. Future Architecture (Phase 2 Hooks)

The following capabilities are designed-for but not built in Phase 1. The architecture ensures these are additive changes, not breaking changes:

| Capability | Architecture Hook |
|---|---|
| **Data lake eligibility** | `EligibilityService` interface — new implementation, same contract |
| **SSE streaming** | Config server adds SSE endpoint; SDK adds listener alongside polling |
| **Sequential testing** | Stats engine adds new SQL queries; no schema change |
| **CUPED variance reduction** | Requires pre-experiment covariate data in ClickHouse; additive table |
| **Bayesian engine** | New stats module alongside frequentist; results API adds `engine` field |
| **Mutual exclusion** | New `exclusion_groups` table in PostgreSQL; config generator adds layer logic |
| **Anonymous → authenticated** | SDK adds `identify()` method; exposure events gain `anonymous_id` field |
| **RBAC** | New `roles` and `permissions` tables; middleware checks on API routes |

---

*This document is the architectural foundation for all implementation phases (Phase 6 onwards). All code, schemas, and APIs must conform to the contracts defined here and in the referenced sub-documents.*
