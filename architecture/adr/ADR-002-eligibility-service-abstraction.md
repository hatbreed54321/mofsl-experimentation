# ADR-002: Eligibility Service Abstraction for Targeting

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** Targeting Architecture

---

## Context

The platform must determine which users are eligible for which experiments. In Phase 1, PMs upload CSV/Excel files of client codes. In Phase 2, eligibility will be resolved via data lake queries (e.g., "all users who traded F&O in the last 30 days"). These are fundamentally different data sources but serve the same purpose.

If we hard-code the CSV-based targeting into the config generation pipeline, swapping to data lake in Phase 2 will require rewriting the config server, SDK contract, and possibly the API.

## Decision

**We define an `EligibilityService` interface that abstracts the eligibility data source.** Phase 1 implements `FileUploadEligibilityService` (reads from PostgreSQL table populated by CSV upload). Phase 2 implements `DataLakeEligibilityService` (queries data lake, caches results). Both implement the same interface. The config generator depends only on the interface, never on the implementation.

```typescript
interface EligibilityService {
  isEligible(clientCode: string, experimentId: string): Promise<boolean>;
  getEligibleExperimentIds(clientCode: string): Promise<string[]>;
  bulkCheckEligibility(clientCode: string, experimentIds: string[]): Promise<Map<string, boolean>>;
}
```

## Rationale

- **Open/Closed Principle:** The config generation pipeline is closed for modification, open for extension via new implementations.
- **Zero contract changes:** The SDK, API, and config payload are identical regardless of eligibility source. Riise team is completely unaware of how eligibility is resolved.
- **Testability:** Interface can be mocked for unit testing config generation without any database dependency.
- **Gradual migration:** In Phase 2, we can run both implementations side-by-side (file-based for some experiments, data-lake for others) without changing any other component.

## Consequences

**Positive:**
- Phase 2 data lake integration is a drop-in replacement
- No SDK or API contract changes when switching eligibility source
- Clean separation of concerns — config generator doesn't know about CSV parsing or data lake queries
- Can support multiple eligibility sources simultaneously per experiment

**Negative:**
- Slight over-engineering for Phase 1 (we only have one implementation)
- Interface must be designed broad enough to accommodate unknown Phase 2 requirements

**Mitigations:**
- The interface is minimal (3 methods) — low overhead
- If Phase 2 requirements demand interface changes, we extend (add methods) rather than modify

## Alternatives Considered

1. **Direct PostgreSQL queries in config generator:** Simpler for Phase 1 but creates tight coupling. Rejected because it would require rewriting the config pipeline for Phase 2.

2. **Eligibility resolved in SDK:** SDK receives full eligibility list and checks locally. Rejected because sending 1M client codes to every SDK instance is not feasible, and it leaks targeting data to the client device.
