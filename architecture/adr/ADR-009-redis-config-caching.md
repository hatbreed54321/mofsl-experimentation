# ADR-009: Redis Caching Layer for Config Serving

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** Performance

---

## Context

The config server must handle up to 5,000 requests/sec during peak trading hours. Each config request requires querying PostgreSQL for active experiments, eligibility, targeting rules, and variations — a multi-JOIN query. Without caching, PostgreSQL would be overwhelmed and config latency would be unacceptable.

## Decision

**We place a Redis (AWS ElastiCache) caching layer in front of config serving.** The config server checks Redis first; on cache miss, it queries PostgreSQL, assembles the config, caches it in Redis, and returns it.

**Cache key structure:**
```
config:v1:{clientCode}  →  JSON config payload
config:version           →  global config version hash (SHA-256)
```

**Cache invalidation strategy:**
- When any experiment, flag, variation, or targeting rule changes, the control plane:
  1. Computes new global config version hash
  2. Updates `config:version` in Redis
  3. Deletes all `config:v1:*` keys (bulk invalidation via key pattern)
- Config payloads have a TTL of 5 minutes as a safety net (cache clears itself even if invalidation fails)
- SDK sends `?version={hash}` — if it matches `config:version`, server returns `304 Not Modified` without any database query

**Target:** >95% cache hit rate in steady state (most SDKs are polling with unchanged configs).

## Rationale

| Metric | Without Redis | With Redis |
|---|---|---|
| Config latency (p50) | 50–200ms (PostgreSQL query) | 2–5ms (Redis GET) |
| Config latency (p99) | 500ms+ | 10ms |
| PostgreSQL load | 5,000 queries/sec | ~250 queries/sec (5% miss rate) |
| Scalability ceiling | ~2,000 req/sec on RDS | >50,000 req/sec on ElastiCache |

Redis reduces PostgreSQL load by 95%+ and brings config latency to single-digit milliseconds. This is critical for SDK initialization performance.

## Consequences

**Positive:**
- Sub-10ms config serving latency
- PostgreSQL protected from SDK traffic
- `304 Not Modified` response path requires zero database queries
- Horizontal scalability: Redis cluster can scale to any request volume

**Negative:**
- Added infrastructure component (ElastiCache)
- Cache invalidation complexity — must invalidate on every config-affecting change
- Stale config possible for up to 5 minutes if invalidation fails (TTL safety net)
- Memory cost for caching per-client configs

**Mitigations:**
- ElastiCache is fully managed with multi-AZ failover
- 5-minute staleness is acceptable for A/B testing (experiments run for days)
- Per-client config caching is bounded by active user count (not total users)
- Redis failure fallback: config server queries PostgreSQL directly (degraded but functional)

## Alternatives Considered

1. **No caching — PostgreSQL only:** Simplest architecture. Rejected because PostgreSQL cannot sustain 5K concurrent queries/sec without significant over-provisioning.

2. **CDN caching (CloudFront):** Cache at the edge. Rejected because configs are per-user (client code), making CDN cache hit rate very low, and CDN cannot evaluate eligibility.

3. **Local file caching on config server:** Cache configs in memory on the Node.js process. Rejected because ECS tasks are ephemeral and scale horizontally — each new task starts with an empty cache. Redis provides shared cache across all instances.
