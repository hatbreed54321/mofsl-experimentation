# ADR-006: Exposure Callback Pattern — No Event Transport in SDK

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** SDK Architecture

---

## Context

When a user is assigned to an experiment variant, an "exposure event" must be recorded for statistical analysis. There are two approaches:

1. **SDK handles event transport:** SDK collects exposure events internally, batches them, and sends them to the platform's event API. (LaunchDarkly, Statsig approach)
2. **SDK fires a callback:** SDK invokes an `onExposure` callback that the host app implements. The host app decides how to transport the event. (Eppo approach)

We are a platform team delivering an SDK to the Riise engineering team. We do not have access to the Riise codebase. The Riise team has their own analytics pipeline and event infrastructure.

## Decision

**The SDK fires an `onExposure` callback. It does not contain any event transport, batching, or queueing logic.** The Riise team implements the callback and routes exposure events through their own analytics pipeline (or directly to our Event Ingestion API).

```dart
onExposure: (experiment, variation) {
  // Riise team implements this
  analytics.track("experiment_exposure", {
    "experiment_key": experiment.key,
    "variation": variation.key,
    "client_code": currentUser.clientCode,
  });
},
```

## Rationale

| Factor | SDK-Owned Transport | Callback Pattern |
|---|---|---|
| SDK complexity | High — HTTP client, retry, batching, queue, offline buffer | Low — fire and forget |
| SDK size | Larger | Minimal |
| Network permissions | SDK needs internet access for event API | No network code in SDK |
| Failure modes | SDK event queue overflow, API failures, retry storms | Callback failure is host app's problem |
| Host app control | Limited — SDK owns the transport | Full — host app routes events as it sees fit |
| Integration effort for Riise | Lower (just initialize SDK) | Slightly higher (must implement callback) |
| Analytics unification | Separate pipeline from Riise's analytics | Riise can unify with their existing analytics |

The callback pattern is the right choice because:

1. **We don't own the Riise codebase.** If our SDK's event transport has a bug (retry storm, memory leak, network spike), we can't debug or fix it in the Riise app. The callback pattern means the host app owns all network behavior.

2. **SDK reliability is paramount.** A trading app cannot tolerate an SDK that queues events in memory, retries failed HTTP calls, or consumes bandwidth. The thinner the SDK, the lower the risk to Riise.

3. **Riise already has analytics infrastructure.** Forcing them to use our transport would create a parallel pipeline. The callback lets them route through their existing analytics.

## Consequences

**Positive:**
- SDK is extremely thin and reliable — no network code, no queue, no retry logic
- Riise team has full control over event transport
- Riise can unify experiment events with their broader analytics
- Fewer failure modes in the SDK
- SDK package size is smaller

**Negative:**
- Riise team must implement the callback (trivial but non-zero work)
- Platform team has less control over event delivery reliability
- If Riise's callback implementation has bugs, exposure data quality suffers
- Platform team cannot guarantee exposure event delivery

**Mitigations:**
- SDK documentation includes reference implementations for the callback
- Platform provides an Event Ingestion API — Riise can call it directly from the callback
- Dashboard shows exposure event counts per experiment — data quality issues are visible immediately
- SDK fires callback only once per experiment per session (deduplication built into SDK)

## Alternatives Considered

1. **SDK-owned event transport with internal batching:** More control over delivery, but adds significant complexity, size, and risk to the SDK. Rejected because we prioritize SDK thinness and the fact that we don't own the host app.

2. **Hybrid — callback with fallback SDK transport:** SDK fires callback, but also has a built-in transport as fallback. Rejected because it doubles the complexity and creates ambiguity about which transport is being used.
