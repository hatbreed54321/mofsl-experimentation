# ADR-001: Local SDK Evaluation Over Server-Side Evaluation

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** SDK Architecture

---

## Context

The experimentation platform needs to assign users to experiment variants and return variation values to the Riise app. There are two fundamental approaches:

1. **Server-side evaluation:** SDK calls the server on every `getBool()` / `getString()` invocation, server computes assignment, returns result.
2. **Local evaluation:** SDK downloads the full experiment config once, caches it, and evaluates all assignments locally with no network call.

Riise is a trading app where latency directly impacts user experience and revenue. The app operates in conditions ranging from high-speed Wi-Fi to spotty 3G on Indian mobile networks. Any UI flicker or delay caused by experiment evaluation would be unacceptable in the order flow.

## Decision

**We adopt local SDK evaluation.** The SDK downloads the experiment configuration at initialization, caches it in SharedPreferences, and all subsequent `getBool()`, `getString()`, `getInt()`, `getJSON()` calls are synchronous, local, zero-latency lookups with no network dependency.

## Rationale

| Factor | Local Evaluation | Server-Side Evaluation |
|---|---|---|
| Evaluation latency | 0ms (in-memory lookup) | 50–500ms per call (network round-trip) |
| Offline resilience | Full — works from cache | None — fails without network |
| Server load | 1 fetch per session | N fetches per session (1 per evaluation) |
| UI flicker | None — synchronous | Possible — async resolution |
| Complexity | SDK is slightly thicker | SDK is thin but server is hot path |
| Config freshness | Slightly stale (TTL-based refresh) | Always current |

For a trading app with 40L+ users, the server load difference is massive. If each user evaluates 10 experiments per session, server-side evaluation would require 10× the request volume vs. a single config fetch.

The slight staleness trade-off (a user might see an old config for up to 5 minutes) is acceptable for A/B testing — experiments run for days or weeks, and a few minutes of staleness has no statistical impact.

## Consequences

**Positive:**
- Zero-latency evaluation — no impact on Riise app performance
- Offline-capable — experiments work even without network
- Massive reduction in server load (1 request vs. N per session)
- Riise team gets simple synchronous API — no async handling at call sites

**Negative:**
- Config changes take up to one polling interval (default 5 min) to propagate
- SDK is slightly more complex (must implement hashing, evaluation logic, caching)
- Kill switch is not instant — requires next config refresh to take effect
- SDK size increases slightly due to evaluation engine

**Mitigations:**
- Phase 2 SSE streaming will reduce propagation delay to near-real-time
- Kill switch latency is acceptable for Phase 1 (5 min max)
- SDK evaluation engine is well-understood (GrowthBook, Eppo, and LaunchDarkly all use this pattern)

## Alternatives Considered

1. **Server-side evaluation with client-side caching:** Evaluate on server first, cache result locally, re-evaluate on cache miss. Rejected because it still requires a network call for new experiments, and cache invalidation is complex.

2. **Hybrid:** Local evaluation for flags, server-side for experiments. Rejected because it creates two different evaluation paths and doubles complexity.

## References

- GrowthBook SDK architecture: local evaluation with polling refresh
- Eppo SDK: "initialize once, evaluate anywhere" pattern
- LaunchDarkly: local evaluation in client-side SDKs (streaming for updates)
