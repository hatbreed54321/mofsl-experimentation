# ADR-007: MurmurHash3 for Deterministic Variant Assignment

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** Assignment Algorithm

---

## Context

The SDK must assign each user to a variant for each experiment. This assignment must be:

1. **Deterministic:** Same user + same experiment always yields the same variant, across sessions, devices, and SDK reinitializations.
2. **Uniform:** Users are distributed evenly across the bucket space.
3. **Independent:** Changing one experiment's configuration does not affect another experiment's assignments.
4. **Fast:** Computable in microseconds on a mobile device.

## Decision

**We use MurmurHash3 (32-bit, x86 variant) to hash the concatenation of `experimentKey` and `clientCode`, producing a bucket in the range 0–9999.**

```
bucket = MurmurHash3(experimentKey + ":" + clientCode, seed=0) % 10000
```

The 10,000-bucket space provides 0.01% granularity for traffic allocation. Each experiment defines a traffic allocation (e.g., 50% of eligible users) and variation weights (e.g., 50/50 control/treatment). The bucket is mapped to a variation as follows:

```
Traffic allocation: 50% → buckets 0–4999 are in experiment, 5000–9999 excluded
Variation weights: 50/50 → buckets 0–2499 = control, 2500–4999 = treatment

For a user with bucket 3100:
  → 3100 < 5000 → in experiment
  → 3100 >= 2500 → treatment
```

## Rationale

**Why MurmurHash3:**
- Used by GrowthBook, Statsig, and Optimizely for the same purpose
- Excellent uniformity — near-perfect distribution across the output space
- Very fast — ~10ns per hash on modern hardware, negligible on mobile
- Pure math — no cryptographic overhead, no external dependencies
- Available in pure Dart (can be implemented in ~50 lines)

**Why 10,000 buckets:**
- 0.01% granularity matches GrowthBook's model
- Sufficient for any practical traffic allocation (1% minimum = 100 buckets)
- Small enough to store as a 16-bit integer
- Industry standard bucket count

**Why `experimentKey + ":" + clientCode`:**
- Concatenating with experiment key ensures independence between experiments
- A user gets bucket 3100 in experiment A but a completely different bucket in experiment B
- The colon separator prevents hash collisions from key/code boundary ambiguity (e.g., "abc" + "def" vs "ab" + "cdef")

**Why seed=0:**
- Consistent across all SDK instances and server-side verification
- No need for per-experiment seeds (the experiment key already ensures independence)

## Consequences

**Positive:**
- Perfectly deterministic — no database lookup needed at evaluation time
- SDK can compute assignment offline with no network
- Server can independently verify any assignment (same algorithm)
- Uniform distribution validated by extensive testing across platforms
- Zero runtime state — bucket is a pure function of inputs

**Negative:**
- Hash collision rate is non-zero (but negligible — ~0.01% for 10K buckets)
- Cannot "re-shuffle" users without changing the experiment key (by design)
- MurmurHash3 is not cryptographically secure (irrelevant — we're not using it for security)

**Mitigations:**
- Distribution uniformity will be validated with automated tests (chi-square test on synthetic data)
- If re-shuffling is ever needed, a new experiment with a new key is the correct approach

## Phase 2 Hook: Mutual Exclusion

For mutual exclusion (Phase 2), we add a namespace layer:

```
namespaceSlot = MurmurHash3(namespaceKey + ":" + clientCode, seed=0) % 10000
experimentBucket = MurmurHash3(experimentKey + ":" + clientCode, seed=0) % 10000
```

The namespace slot determines which experiment in an exclusion group the user is eligible for. This is an additive layer — the per-experiment bucketing algorithm does not change.

## Alternatives Considered

1. **SHA-256:** Cryptographically secure, excellent uniformity. Rejected because it's 10–100× slower than MurmurHash3 and crypto security is unnecessary for bucketing.

2. **Random assignment with database persistence:** Generate a random number, store the assignment in a database. Rejected because it requires a database lookup at every evaluation (violates local evaluation model) and breaks offline capability.

3. **CRC32:** Fast, widely available. Rejected because distribution uniformity is worse than MurmurHash3 — known to produce clustering artifacts.
