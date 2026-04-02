# Skill: Statistics Engine — Frequentist Methodology

> **Purpose:** This file teaches Claude Code the exact statistical methods used in the platform's Phase 1 stats engine. It covers the mathematical formulas, implementation notes, edge cases, and validation approach. The goal is to produce a stats engine that gives correct results — statistical bugs are invisible and can lead to wrong business decisions.

---

## Overview

The stats engine answers one question: **"Is the observed difference between control and treatment statistically significant?"**

Phase 1 implements:
1. Two-proportion z-test (binary metrics)
2. Welch's t-test (continuous metrics)
3. Confidence intervals
4. Relative lift with confidence interval
5. Sample size calculator
6. Minimum detectable effect (MDE) calculator
7. Winner declaration logic

All computations happen in TypeScript. ClickHouse provides the aggregated input data (counts, sums, sum-of-squares). The math is done in application code for testability.

---

## 1. Two-Proportion Z-Test (Binary Metrics)

Used when the metric is binary (converted/not converted), e.g., "Did the user place an order?"

### Inputs (from ClickHouse)

```
Control:     n_c = exposed users,  x_c = converting users
Treatment:   n_t = exposed users,  x_t = converting users
```

### Computation

```
Step 1: Conversion rates
  p_c = x_c / n_c    (control conversion rate)
  p_t = x_t / n_t    (treatment conversion rate)

Step 2: Pooled proportion (under null hypothesis H0: p_c = p_t)
  p_pool = (x_c + x_t) / (n_c + n_t)

Step 3: Standard error of the difference (under H0)
  se = sqrt(p_pool * (1 - p_pool) * (1/n_c + 1/n_t))

Step 4: Z-statistic
  z = (p_t - p_c) / se

Step 5: P-value (two-tailed)
  p_value = 2 * (1 - Φ(|z|))
  Where Φ is the standard normal cumulative distribution function
```

### Confidence Interval for the Difference

```
Step 1: Standard error of the difference (not pooled — for CI we use each group's own rate)
  se_diff = sqrt(p_c * (1 - p_c) / n_c + p_t * (1 - p_t) / n_t)

Step 2: 95% confidence interval
  lower = (p_t - p_c) - 1.96 * se_diff
  upper = (p_t - p_c) + 1.96 * se_diff
```

**Note:** The z-test uses the pooled proportion for SE (appropriate under H0), but the CI uses unpooled SE (more appropriate for estimating the range of the true difference).

### TypeScript Implementation

```typescript
interface BinaryMetricResult {
  controlRate: number;
  treatmentRate: number;
  absoluteDifference: number;
  relativeLift: number;
  confidenceInterval: { lower: number; upper: number };
  liftConfidenceInterval: { lower: number; upper: number };
  zStatistic: number;
  pValue: number;
  isSignificant: boolean;
  controlN: number;
  treatmentN: number;
}

function binaryMetricTest(
  nC: number, xC: number,  // control: total, conversions
  nT: number, xT: number,  // treatment: total, conversions
  alpha: number = 0.05
): BinaryMetricResult {
  const pC = xC / nC;
  const pT = xT / nT;
  
  const pPool = (xC + xT) / (nC + nT);
  const se = Math.sqrt(pPool * (1 - pPool) * (1/nC + 1/nT));
  
  const z = se === 0 ? 0 : (pT - pC) / se;
  const pValue = 2 * (1 - normalCDF(Math.abs(z)));
  
  const seDiff = Math.sqrt(pC * (1 - pC) / nC + pT * (1 - pT) / nT);
  const zAlpha = normalInverseCDF(1 - alpha / 2); // 1.96 for alpha=0.05
  
  const diff = pT - pC;
  const ci = {
    lower: diff - zAlpha * seDiff,
    upper: diff + zAlpha * seDiff,
  };
  
  const lift = pC === 0 ? 0 : diff / pC;
  const liftCI = pC === 0 ? { lower: 0, upper: 0 } : {
    lower: ci.lower / pC,
    upper: ci.upper / pC,
  };
  
  return {
    controlRate: pC,
    treatmentRate: pT,
    absoluteDifference: diff,
    relativeLift: lift,
    confidenceInterval: ci,
    liftConfidenceInterval: liftCI,
    zStatistic: z,
    pValue,
    isSignificant: pValue < alpha,
    controlN: nC,
    treatmentN: nT,
  };
}
```

---

## 2. Welch's T-Test (Continuous Metrics)

Used when the metric is continuous (order value, session duration, etc.).

### Inputs (from ClickHouse)

```
Control:     n_c, sum_c, sum_sq_c
Treatment:   n_t, sum_t, sum_sq_t

Derived:
  mean_c = sum_c / n_c
  mean_t = sum_t / n_t
  var_c  = sum_sq_c / n_c - mean_c²    (population variance)
  s²_c   = var_c * n_c / (n_c - 1)     (sample variance, Bessel's correction)
  s²_t   = same for treatment
```

### Computation

```
Step 1: T-statistic
  t = (mean_t - mean_c) / sqrt(s²_t/n_t + s²_c/n_c)

Step 2: Degrees of freedom (Welch-Satterthwaite equation)
  df = (s²_t/n_t + s²_c/n_c)²
     / ((s²_t/n_t)² / (n_t - 1) + (s²_c/n_c)² / (n_c - 1))

Step 3: P-value (two-tailed)
  p_value = 2 * (1 - T_cdf(|t|, df))
  Where T_cdf is the Student's t cumulative distribution function

Step 4: Confidence interval
  se_diff = sqrt(s²_t/n_t + s²_c/n_c)
  t_crit = T_inverse_cdf(1 - alpha/2, df)
  lower = (mean_t - mean_c) - t_crit * se_diff
  upper = (mean_t - mean_c) + t_crit * se_diff
```

### Why Welch's (Not Student's)

Student's t-test assumes equal variances in both groups. Welch's t-test does not. In A/B testing, we cannot guarantee equal variances (treatment may increase both mean and variance), so Welch's is always the correct choice.

---

## 3. Normal Distribution CDF

Required for the z-test p-value calculation.

### Abramowitz and Stegun Approximation (Formula 26.2.17)

```typescript
function normalCDF(x: number): number {
  // Handle symmetry
  if (x < 0) return 1 - normalCDF(-x);
  
  // Constants
  const a1 = 0.254829592;
  const a2 = -0.284496736;
  const a3 = 1.421413741;
  const a4 = -1.453152027;
  const a5 = 1.061405429;
  const p = 0.3275911;
  
  const t = 1 / (1 + p * x);
  const t2 = t * t;
  const t3 = t2 * t;
  const t4 = t3 * t;
  const t5 = t4 * t;
  
  const poly = a1 * t + a2 * t2 + a3 * t3 + a4 * t4 + a5 * t5;
  
  return 1 - poly * Math.exp(-0.5 * x * x);
}
```

**Accuracy:** |error| < 1.5 × 10⁻⁷. Sufficient for p-value computation.

### Inverse Normal CDF

Needed for critical values (e.g., z_0.025 = 1.96). Use the rational approximation by Peter Acklam:

```typescript
function normalInverseCDF(p: number): number {
  if (p <= 0) return -Infinity;
  if (p >= 1) return Infinity;
  if (p === 0.5) return 0;
  
  // Coefficients for rational approximation
  const a = [-3.969683028665376e+01, 2.209460984245205e+02,
             -2.759285104469687e+02, 1.383577518672690e+02,
             -3.066479806614716e+01, 2.506628277459239e+00];
  const b = [-5.447609879822406e+01, 1.615858368580409e+02,
             -1.556989798598866e+02, 6.680131188771972e+01,
             -1.328068155288572e+01];
  const c = [-7.784894002430293e-03, -3.223964580411365e-01,
             -2.400758277161838e+00, -2.549732539343734e+00,
              4.374664141464968e+00, 2.938163982698783e+00];
  const d = [7.784695709041462e-03, 3.224671290700398e-01,
             2.445134137142996e+00, 3.754408661907416e+00];
  
  const pLow = 0.02425;
  const pHigh = 1 - pLow;
  
  let q: number, r: number;
  
  if (p < pLow) {
    q = Math.sqrt(-2 * Math.log(p));
    return (((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) /
           ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1);
  } else if (p <= pHigh) {
    q = p - 0.5;
    r = q * q;
    return (((((a[0]*r+a[1])*r+a[2])*r+a[3])*r+a[4])*r+a[5])*q /
           (((((b[0]*r+b[1])*r+b[2])*r+b[3])*r+b[4])*r+1);
  } else {
    q = Math.sqrt(-2 * Math.log(1 - p));
    return -(((((c[0]*q+c[1])*q+c[2])*q+c[3])*q+c[4])*q+c[5]) /
            ((((d[0]*q+d[1])*q+d[2])*q+d[3])*q+1);
  }
}
```

---

## 4. Student's T-Distribution CDF

Required for the Welch's t-test p-value. This is the hardest function to implement correctly.

### Option A: Use `jstat` npm package

```typescript
import { jStat } from 'jstat';
const pValue = 2 * (1 - jStat.studentt.cdf(Math.abs(t), df));
```

This is the recommended approach. `jstat` is well-tested and handles edge cases.

### Option B: Implement from scratch

Use the regularized incomplete beta function:

```
T_cdf(t, df) = 1 - 0.5 * I_x(df/2, 1/2)
Where x = df / (df + t²)
And I_x is the regularized incomplete beta function
```

The incomplete beta function requires either continued fraction expansion or series approximation. This is ~100 lines of careful numerical code. Only implement from scratch if avoiding the `jstat` dependency is critical.

---

## 5. Sample Size Calculator

### For Binary Metrics

```
Required sample size per variation:

n = (z_α/2 + z_β)² × (p_c × (1 - p_c) + p_t × (1 - p_t)) / (p_t - p_c)²

Where:
  z_α/2 = critical value for significance level (1.96 for α = 0.05)
  z_β   = critical value for power (0.84 for 80% power, 1.28 for 90%)
  p_c   = expected control conversion rate
  p_t   = expected treatment conversion rate = p_c × (1 + MDE)
  MDE   = minimum detectable effect as relative lift (e.g., 0.05 = 5% relative increase)
```

### For Continuous Metrics

```
n = 2 × (z_α/2 + z_β)² × σ² / δ²

Where:
  σ² = expected variance of the metric
  δ  = minimum detectable difference in absolute terms
```

### Implementation

```typescript
interface SampleSizeInput {
  metricType: 'binary' | 'continuous';
  
  // Binary
  baselineRate?: number;     // e.g., 0.05 (5% conversion rate)
  
  // Continuous
  baselineVariance?: number; // estimated variance
  
  // Common
  mde: number;               // minimum detectable effect (relative for binary, absolute for continuous)
  alpha?: number;             // significance level (default 0.05)
  power?: number;             // statistical power (default 0.80)
  variations?: number;        // number of variations including control (default 2)
}

interface SampleSizeResult {
  sampleSizePerVariation: number;
  totalSampleSize: number;
  estimatedDaysToRun: number | null; // null if daily traffic unknown
}

function calculateSampleSize(input: SampleSizeInput): SampleSizeResult {
  const alpha = input.alpha ?? 0.05;
  const power = input.power ?? 0.80;
  const variations = input.variations ?? 2;
  
  const zAlpha = normalInverseCDF(1 - alpha / 2);
  const zBeta = normalInverseCDF(power);
  
  let n: number;
  
  if (input.metricType === 'binary') {
    const pC = input.baselineRate!;
    const pT = pC * (1 + input.mde); // MDE is relative lift
    const delta = pT - pC;
    
    n = Math.pow(zAlpha + zBeta, 2) * (pC * (1 - pC) + pT * (1 - pT)) / Math.pow(delta, 2);
  } else {
    const variance = input.baselineVariance!;
    const delta = input.mde; // MDE is absolute difference
    
    n = 2 * Math.pow(zAlpha + zBeta, 2) * variance / Math.pow(delta, 2);
  }
  
  const perVariation = Math.ceil(n);
  
  return {
    sampleSizePerVariation: perVariation,
    totalSampleSize: perVariation * variations,
    estimatedDaysToRun: null,
  };
}
```

---

## 6. Winner Declaration Logic

```typescript
interface WinnerDeclaration {
  status: 'winner' | 'loser' | 'inconclusive' | 'insufficient_data' | 'guardrail_warning';
  winningVariation: string | null;
  reason: string;
}

function declareWinner(
  primaryResult: MetricResult,
  guardrailResults: MetricResult[],
  minSampleSize: number,
  minDaysRunning: number = 7,
  daysRunning: number,
  alpha: number = 0.05,
): WinnerDeclaration {
  // Check 1: Minimum sample size
  if (primaryResult.controlN < minSampleSize || primaryResult.treatmentN < minSampleSize) {
    return {
      status: 'insufficient_data',
      winningVariation: null,
      reason: `Need at least ${minSampleSize} users per variation. Control: ${primaryResult.controlN}, Treatment: ${primaryResult.treatmentN}`,
    };
  }
  
  // Check 2: Minimum duration
  if (daysRunning < minDaysRunning) {
    return {
      status: 'insufficient_data',
      winningVariation: null,
      reason: `Experiment has run for ${daysRunning} days. Minimum ${minDaysRunning} days required.`,
    };
  }
  
  // Check 3: Primary metric significance
  if (primaryResult.pValue >= alpha) {
    return {
      status: 'inconclusive',
      winningVariation: null,
      reason: `Primary metric is not statistically significant (p=${primaryResult.pValue.toFixed(4)}, α=${alpha})`,
    };
  }
  
  // Check 4: Guardrail metrics
  const guardrailRegressions = guardrailResults.filter(
    g => g.pValue < alpha && g.relativeLift < 0  // significant AND negative
  );
  
  if (guardrailRegressions.length > 0) {
    const names = guardrailRegressions.map(g => g.metricKey).join(', ');
    return {
      status: 'guardrail_warning',
      winningVariation: primaryResult.relativeLift > 0 ? 'treatment' : 'control',
      reason: `Primary metric is significant, but guardrail regression detected: ${names}`,
    };
  }
  
  // All checks pass — declare winner
  const winner = primaryResult.relativeLift > 0 ? 'treatment' : 'control';
  return {
    status: primaryResult.relativeLift > 0 ? 'winner' : 'loser',
    winningVariation: winner,
    reason: `Statistically significant (p=${primaryResult.pValue.toFixed(4)}). ${winner} is better by ${(Math.abs(primaryResult.relativeLift) * 100).toFixed(2)}%.`,
  };
}
```

---

## 7. Edge Cases and Numerical Stability

| Edge Case | Handling |
|---|---|
| Division by zero (n=0) | Return "insufficient data" — never divide by zero |
| Very small sample (n < 30) | Still compute, but flag as "preliminary results — sample too small" |
| Conversion rate = 0 or 1 | SE formula works (produces 0 SE) but CI is meaningless. Flag in UI. |
| Equal conversion rates | z = 0, p = 1.0. Correct and expected. |
| Very large z or t statistic | CDF returns values very close to 0 or 1. Use `Math.max(pValue, 1e-16)` to avoid exact 0. |
| Negative variance (numerical error) | Clamp to 0. Log warning. |
| n_c ≠ n_t (unbalanced groups) | Welch's t-test and z-test both handle this correctly. No special handling needed. |
| Continuous metric with zero variance | Both groups have identical values. SE = 0, t is undefined. Return "insufficient variance." |

---

## 8. Test Validation Strategy

### Test Against Known Values

Use scipy as a reference implementation. Pre-compute results in Python and hardcode them as test fixtures:

```python
# Python reference script (run once, use results in TypeScript tests)
from scipy import stats
import numpy as np

# Binary metric test
n_c, x_c = 10000, 500   # 5% conversion
n_t, x_t = 10000, 550   # 5.5% conversion
z, p = stats.proportions_ztest([x_t, x_c], [n_t, n_c])
print(f"z={z}, p={p}")
# Use these values as expected outputs in TypeScript tests
```

### Required Test Cases

For each test function, include at least:

1. **Typical case:** Moderate sample sizes, meaningful difference
2. **No difference:** Both groups identical → p ≈ 1.0
3. **Huge difference:** Very large effect → p ≈ 0
4. **Small sample:** n = 50 per group
5. **Large sample:** n = 100,000 per group
6. **Unbalanced groups:** n_c = 10,000, n_t = 5,000
7. **Edge: zero conversions in treatment** (binary)
8. **Edge: 100% conversion in both** (binary)
9. **Edge: zero variance** (continuous)

### Precision Requirements

All statistical values should match scipy to at least 4 decimal places:
```typescript
expect(result.pValue).toBeCloseTo(0.0312, 4);
expect(result.zStatistic).toBeCloseTo(2.154, 3);
```

---

## 9. ClickHouse Query → Stats Engine Data Flow

```
Dashboard clicks "View Results"
  → Backend: GET /api/v1/experiments/:id/results?metricId=xxx
    → StatsEngine.computeResults(experimentId, metricId)
      → ClickHouse query: get per-variation aggregates from mv_daily_conversions
        → Returns: { variation_key, n, x } (binary) or { variation_key, n, sum, sum_sq } (continuous)
      → ClickHouse query: get exposure counts from mv_daily_exposures
        → Returns: { variation_key, unique_users }
      → TypeScript: compute z-test or t-test
      → TypeScript: compute CI, lift, p-value
      → TypeScript: run winner declaration logic
      → Return structured ExperimentResults object
    → Return JSON to dashboard
  → Dashboard renders results UI
```

The stats engine is deterministic — given the same ClickHouse data, it always returns the same results. This makes it fully testable with known inputs.
