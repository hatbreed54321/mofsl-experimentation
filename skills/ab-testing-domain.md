# Skill: A/B Testing Domain Knowledge

> **Purpose:** This file teaches Claude Code the core concepts of A/B testing, experiment lifecycle, bucketing logic, and statistical significance so it can make correct implementation decisions without asking questions.

---

## What Is A/B Testing?

A/B testing (also called split testing or controlled experimentation) compares two or more variants of a product experience to determine which performs better on a defined metric. Users are randomly assigned to variants, and their behavior is measured to determine if the difference is statistically significant.

Key principle: **correlation does not imply causation, but a properly designed randomized experiment does.** The randomization ensures that the only systematic difference between groups is the treatment being tested.

---

## Experiment Lifecycle

### States

```
Draft → Running → Paused → Running → Completed → Archived
```

**Draft:** Experiment is being configured. Variations, metrics, targeting, and traffic allocation are set. Experiment is not visible to the SDK. Can be deleted.

**Running:** Experiment is active. Users are being assigned to variants. Exposure and conversion events are being collected. Config is served to the SDK. Cannot be deleted.

**Paused:** Experiment is temporarily stopped. Users who were previously assigned retain their assignment (deterministic hashing ensures this). No new exposures are recorded. Can be resumed.

**Completed:** Experiment is permanently stopped. Results are final. No new exposures. Config is removed from SDK. Results remain accessible in dashboard.

**Archived:** Completed experiment moved out of the active list. Results still accessible but not shown in default views.

### Pre-Launch Checklist (enforced by backend)

Before an experiment can transition from Draft to Running:
1. At least 2 variations defined
2. Variation weights sum to exactly 1.0
3. At least 1 primary metric assigned
4. Coverage > 0 (some fraction of users must be included)

---

## Bucketing (Variant Assignment)

### The Problem

We need to assign each user to a variant such that:
- The assignment is **deterministic** (same user always gets same variant)
- The assignment is **uniform** (users are evenly distributed)
- Assignments are **independent** across experiments (a user's variant in experiment A is unrelated to their variant in experiment B)
- The assignment is **stable** (stopping/starting the experiment doesn't reassign users)

### The Solution: Hash-Based Bucketing

```
bucket = MurmurHash3(experimentKey + ":" + clientCode, seed=0) % 10000
```

This produces a number from 0 to 9999 — the user's "bucket" for this experiment. The bucket is then mapped to a variant:

**Step 1: Traffic Coverage Check**
```
If bucket >= coverage × 10000 → user is EXCLUDED (not in experiment)
```
Example: 50% coverage means buckets 0–4999 are included, 5000–9999 are excluded.

**Step 2: Variation Weight Mapping**
```
cumulative = 0
For each variation (in order):
  cumulative += weight × 10000
  If bucket < cumulative → assign this variation
```

Example with 50/50 weights and 100% coverage:
- Bucket 0–4999 → control
- Bucket 5000–9999 → treatment

Example with 33/33/34 weights and 80% coverage:
- Bucket 0–2639 → control
- Bucket 2640–5279 → variant_a
- Bucket 5280–7999 → variant_b
- Bucket 8000–9999 → excluded

### Why 10,000 Buckets?

- Provides 0.01% granularity (can allocate traffic in 0.01% increments)
- Industry standard (GrowthBook, Optimizely use the same)
- Small enough for simple integer arithmetic
- Large enough for any practical traffic split

### Why MurmurHash3?

- Non-cryptographic hash with excellent uniformity
- Very fast (~10ns per hash)
- Used by GrowthBook, Statsig, Optimizely for the same purpose
- Pure math — implementable in any language without dependencies

### Determinism Guarantee

The hash output is a pure function of `experimentKey + ":" + clientCode`. No database, no random number generator, no state. This means:
- Same user always gets same variant (across sessions, devices, app restarts)
- Evaluation works offline (no network needed)
- Server can independently verify any SDK assignment
- Stopping and resuming an experiment doesn't re-shuffle users

### Independence Across Experiments

Because the experiment key is part of the hash input, a user gets a completely different bucket in each experiment. User "AB1234" might be in bucket 3100 for "new_chart_ui" but bucket 7850 for "order_flow_v2". This means variant assignments are independent across experiments (no systematic correlation).

---

## Feature Flags vs Experiments

Both use the same SDK evaluation model but serve different purposes:

| Aspect | Experiment | Feature Flag |
|---|---|---|
| Purpose | Measure impact of a change | Control rollout of a feature |
| Variations | 2+ variants with different values | Single value (on/off or specific value) |
| Metrics | Has primary + guardrail metrics | No metrics |
| Statistical analysis | Yes — t-test, p-value, CI | No |
| Exposure tracking | Yes — fires `onExposure` callback | No exposure tracking |
| Lifecycle | Draft → Running → Completed | Enabled / Disabled |
| Duration | Temporary (runs for days/weeks) | Can be permanent |

In the SDK, both are evaluated the same way:
- Experiments: user gets a variation based on hash bucketing
- Flags: user gets the flag's current value (no bucketing needed for simple flags)

---

## Exposure Events

An "exposure" records that a user was shown a specific variant. Exposures are critical for statistical analysis — without them, we don't know which users were in which group.

### When to Fire

- On the **first evaluation** of each experiment per SDK session
- NOT on subsequent evaluations of the same experiment in the same session
- NOT for feature flags
- NOT for excluded users (bucket >= coverage)
- NOT for forced variations (QA overrides)

### Why Deduplication Matters

If a user evaluates `getBool("new_chart_ui")` 50 times in a session, we should record exactly ONE exposure. Multiple exposures inflate the sample size and bias the analysis.

Deduplication layers:
1. **SDK-side:** Track a Set of fired experiment keys per session
2. **Server-side:** Idempotency key check in Redis (24h window)
3. **ClickHouse-side:** ReplacingMergeTree deduplicates on ORDER BY key during merges

---

## Conversion Events

A "conversion" records that a user performed a target action (placed an order, completed onboarding, clicked a button).

### Key Concept: Conversions Are NOT Tied to Experiments at Ingestion Time

The Riise app sends conversion events with a `metricKey` (e.g., "order_placed") and a `clientCode`. The event does NOT specify which experiment it belongs to. The stats engine attributes conversions to experiments at query time:

```
For each experiment:
  Find all users who were exposed (exposure_events)
  For each exposed user, find conversions with the target metric key
  Where conversion.timestamp >= exposure.timestamp
  And conversion.timestamp <= exposure.timestamp + 30 days
```

This design means:
- Riise doesn't need to know experiment details when sending conversion events
- One conversion event can be attributed to multiple experiments (a user might be in 3 experiments and place an order)
- Adding new experiments doesn't change the event ingestion code

---

## Metrics

### Binary Metrics
- Value is 0 or 1 (did the user convert or not)
- Measured as **conversion rate**: `converting_users / total_exposed_users`
- Example: "Did the user place at least one order?" → `order_placed`
- Statistical test: two-proportion z-test

### Continuous Metrics
- Value is a number (can be any positive value)
- Measured as **mean value per user**: `sum(values) / count(users)`
- Example: "What was the total order value?" → `order_value` (in rupees)
- Statistical test: Welch's t-test

### Primary Metric
- The ONE metric that determines if the experiment is a success
- Winner declaration is based on this metric
- Every experiment must have exactly one

### Guardrail Metrics
- Metrics that must NOT regress even if the primary metric improves
- Example: primary = order_placed (up is good), guardrail = app_crash_rate (up is bad)
- If the treatment improves the primary but worsens a guardrail, the result is flagged

---

## Statistical Significance

### The Core Question

"Is the observed difference between control and treatment real, or could it have happened by chance?"

### P-Value

The probability of seeing a difference this large (or larger) if there were actually no difference. Convention: if p < 0.05 (5%), we call the result "statistically significant."

- p = 0.03 → "3% chance this is random noise" → significant
- p = 0.15 → "15% chance this is random noise" → not significant

**Warning:** p < 0.05 does not mean the treatment is 95% likely to be better. It means that if the treatment had no effect, we'd see a result this extreme only 5% of the time.

### Confidence Interval

A range of plausible values for the true difference. A 95% CI means: if we repeated this experiment 100 times, 95 of those CIs would contain the true difference.

Example: "Treatment conversion rate is 2.3% higher than control, 95% CI [0.5%, 4.1%]"
- The interval doesn't contain 0 → statistically significant
- The interval is [0.5%, 4.1%] → the true effect is probably between 0.5% and 4.1%

### Minimum Sample Size

Before running an experiment, calculate how many users are needed to detect the expected effect size with reasonable power (usually 80%). Running an experiment with too few users leads to:
- False negatives: real effects go undetected
- Inflated effect sizes: detected effects appear larger than they are

### The Peeking Problem (Phase 1 Limitation)

If you check results repeatedly while an experiment is running, you're more likely to see a significant result by chance. This is because each check is an independent statistical test, and the more tests you run, the higher the probability of at least one false positive.

Phase 1 mitigation: show "minimum sample size not reached" warning in the dashboard.
Phase 2 solution: sequential testing (alpha-spending functions) that allows continuous monitoring.

---

## Forced Variations (QA Override)

For testing purposes, specific client codes can be forced into specific variations regardless of hash bucketing. This allows QA engineers to verify that each variation renders correctly.

Rules:
- Forced variations bypass the hash algorithm entirely
- Forced variations do NOT fire exposure events (they would pollute the data)
- Forced variations are included in the SDK config as a separate `forcedVariations` map
- They are set in the dashboard and stored in the `forced_variations` PostgreSQL table

---

## Mutual Exclusion (Phase 2 — Design Only)

When two experiments test changes in the same area (e.g., both modify the order flow), users should not be in both experiments simultaneously. Mutual exclusion ensures a user is in at most one experiment within an exclusion group.

Implementation concept (Phase 2):
```
namespaceSlot = MurmurHash3(namespaceKey + ":" + clientCode) % 10000
```
The namespace slot determines which experiment in the exclusion group the user is eligible for. The per-experiment bucketing then determines the variant within that experiment.

This is a layered approach: namespace bucketing → experiment eligibility → experiment bucketing. The Phase 1 architecture supports this because bucketing is already hash-based and deterministic — adding a namespace layer is additive.
