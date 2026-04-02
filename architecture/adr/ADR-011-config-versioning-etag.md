# ADR-011: ETag-Based Config Versioning for SDK Polling

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** SDK ↔ Server Protocol

---

## Context

The SDK polls the config server on a regular interval (default 5 minutes) to check for updates. If the experiment configuration has not changed since the last fetch, the server should return a lightweight "no change" response instead of re-transmitting the full config payload.

With 40L+ users, even a 50 KB config payload × 5K requests/sec × every 5 minutes adds up to significant bandwidth and compute if served on every request.

## Decision

**We use HTTP ETag semantics for config versioning.** The server computes a version hash (SHA-256 of the serialized config state) and returns it in the `ETag` response header. The SDK caches this hash and sends it in the `If-None-Match` request header on subsequent polls.

**Flow:**
1. SDK sends `GET /config?clientCode=X` with `If-None-Match: "abc123"` (the previously received ETag)
2. Server computes or retrieves the current config version hash
3. If hash matches → return `304 Not Modified` (empty body, ~100 bytes)
4. If hash differs → return `200 OK` with full config payload and new `ETag` header

**Config version hash computation:**
- When any experiment, flag, variation, targeting rule, or eligibility list changes, the control plane recomputes the global config version hash
- Hash input: sorted, serialized JSON of all active experiments + flags + variations + targeting rules
- Hash is stored in Redis at `config:version` for O(1) lookup
- Per-client config hashes are computed at cache generation time (different clients may have different eligible experiments)

## Rationale

- **Bandwidth savings:** 95%+ of polling requests return `304` (no config changes between polls) — saves ~50 KB per request
- **Server CPU savings:** `304` path requires only a hash comparison, no config assembly or database query
- **Standard HTTP semantics:** Uses well-understood `ETag` / `If-None-Match` pattern — any HTTP library supports this
- **SDK simplicity:** SDK just stores one string (the ETag) and sends it with every request

## Consequences

**Positive:**
- Massive reduction in bandwidth and server compute for steady-state polling
- Standard HTTP — no custom protocol
- Redis lookup for version hash is ~1ms
- SDK implementation is trivial

**Negative:**
- Slightly more complex config server logic (hash computation, ETag handling)
- Hash must be recomputed on every config-affecting change
- Per-client ETags are more complex than a global ETag (different clients have different configs due to eligibility)

**Mitigations:**
- Per-client ETag is computed at config cache time and stored in Redis alongside the cached config
- Hash recomputation on config change is fast (SHA-256 of ~50 KB JSON < 1ms)

## Phase 2 Hook: SSE Streaming

When SSE streaming is added in Phase 2, the ETag-based polling remains as the fallback mechanism. SSE provides near-real-time push, but if the SSE connection drops, the SDK falls back to polling with ETags. The two mechanisms are complementary, not mutually exclusive.

## Alternatives Considered

1. **Timestamp-based versioning (`If-Modified-Since`):** Simpler but less precise — clock skew between servers can cause false cache hits or misses. Rejected for correctness.

2. **Incrementing version number:** Config version = monotonically increasing integer. Simpler than hash, but doesn't naturally detect "same content, different version" scenarios (e.g., a change is made and then reverted). Rejected for correctness.

3. **Always send full config:** No versioning, always return the full payload. Rejected for bandwidth and performance at scale.
