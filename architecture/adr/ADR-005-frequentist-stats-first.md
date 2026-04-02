# ADR-005: Frequentist Statistics Engine for Phase 1

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** Statistics Engine

---

## Context

The platform must compute experiment results: is a variant statistically better than control? The two mainstream approaches are frequentist (p-values, confidence intervals) and Bayesian (posterior distributions, credible intervals). More advanced techniques include sequential testing (continuous monitoring without peeking penalties) and CUPED (variance reduction using pre-experiment covariates).

The platform team needs to ship a functional stats engine quickly. The PM audience is familiar with p-values from existing tools and industry conventions.

## Decision

**Phase 1 implements a frequentist statistics engine** with the following capabilities:

- **Two-sample Welch's t-test** for continuous metrics (revenue, session duration)
- **Two-proportion z-test** for binary metrics (conversion rate, click-through rate)
- **P-value** with configurable significance threshold (default α = 0.05)
- **95% confidence intervals** for each variant's metric
- **Relative lift** with confidence interval (% change from control)
- **Minimum Detectable Effect (MDE) calculator** for experiment planning
- **Sample size calculator** for required sample size given power, significance, and MDE
- **Winner declaration** when p < α AND minimum sample size reached

All computations run as SQL queries on ClickHouse, leveraging its built-in statistical functions (`avgState`, `varSamp`, `count`, etc.) and standard math operations for test statistics.

## Rationale

| Factor | Frequentist (Phase 1) | Bayesian | Sequential Testing |
|---|---|---|---|
| Implementation complexity | Low — standard formulas in SQL | High — requires MCMC or conjugate priors | Medium — requires alpha-spending functions |
| PM familiarity | High — p-values are industry standard | Low — posterior probabilities need education | Medium — conceptually simple but unfamiliar |
| Time to ship | 1–2 weeks | 4–6 weeks | 2–3 weeks |
| Validity with fixed sample | Fully valid | Fully valid | Designed for continuous monitoring |
| Peeking problem | Yes — results invalid if checked early | No peeking problem | No peeking problem |

The peeking problem is a known limitation: if PMs check results before the planned sample size is reached, the p-value is not reliable. For Phase 1, we mitigate this with clear UI warnings ("minimum sample size not reached — results are preliminary"). Phase 2 adds sequential testing to eliminate this issue.

## Consequences

**Positive:**
- Fast to implement (ClickHouse SQL, no external stats library needed)
- PMs understand p-values and confidence intervals
- Industry-standard methodology — easy to explain results to stakeholders
- Foundation for more advanced methods in Phase 2

**Negative:**
- Peeking problem — PMs may draw conclusions from preliminary results
- Fixed-horizon: experiment must run until planned sample size for valid results
- No variance reduction — requires larger sample sizes than CUPED-enhanced methods
- Binary win/lose — doesn't give probability of being better (Bayesian does)

**Mitigations:**
- Dashboard shows clear "minimum sample size not yet reached" warning
- Sample size calculator helps PMs plan experiment duration before starting
- Phase 2 adds sequential testing (eliminates peeking problem) and CUPED (reduces required sample size)

## Computation Details

All stats are computed via ClickHouse SQL queries. Example for a binary metric:

```sql
-- Per-variant aggregation
SELECT
  variation_key,
  count(DISTINCT client_code) AS n,
  countIf(converted = 1) / count(DISTINCT client_code) AS conversion_rate,
  -- Standard error for proportion
  sqrt(conversion_rate * (1 - conversion_rate) / n) AS se
FROM experiment_results_view
WHERE experiment_id = ?
GROUP BY variation_key
```

The test statistic and p-value are computed in the application layer from these aggregates to avoid complex SQL. This keeps the ClickHouse queries simple and pushes the statistics logic into a testable TypeScript module.

## Alternatives Considered

1. **Bayesian from day one:** More sophisticated, no peeking problem. Rejected because implementation time is 3–4× longer and PM team needs education on interpreting posterior probabilities.

2. **External stats library (Python scipy):** Would enable more complex tests. Rejected because it adds a Python service dependency to a Node.js stack; ClickHouse SQL + TypeScript is sufficient for Phase 1 tests.

3. **Sequential testing from day one:** Solves the peeking problem. Rejected for Phase 1 scope — requires alpha-spending function implementation and more complex results UI. Planned for Phase 2.
