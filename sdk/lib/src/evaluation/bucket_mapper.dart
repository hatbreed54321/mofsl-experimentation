/// Maps a hash bucket to a variation index using traffic coverage and weights.
///
/// Returns the zero-based index into the experiment's `variations` list,
/// or `null` when the user falls outside the experiment's traffic coverage.
///
/// Algorithm (per CONFIG_SERVER_API.md Section 3):
///   1. If bucket >= coverage × 10000 → user excluded → return null.
///   2. Walk cumulative weights: cumulative += weight × 10000.
///      If bucket < cumulative → return this variation's index.
///   3. Fallback null (should never be reached if weights sum to 1.0).
///
/// Parameters:
/// - [bucket]   Integer in [0, 9999] produced by `murmurhash3(...) % 10000`.
/// - [coverage] Traffic fraction in [0.0, 1.0].
/// - [weights]  Ordered weight per variation; must sum to 1.0.
int? mapBucket(int bucket, double coverage, List<double> weights) {
  // Step 1 — coverage check.
  // Using floating-point comparison: bucket is int, coverage * 10000 is double.
  // e.g. coverage=0.5 → threshold=5000.0; bucket 4999 < 5000 → included.
  if (bucket >= coverage * 10000) return null;

  // Step 2 — variation assignment via cumulative weights.
  double cumulative = 0;
  for (int i = 0; i < weights.length; i++) {
    cumulative += weights[i] * 10000;
    if (bucket < cumulative) return i;
  }

  // Step 3 — should never reach here when weights sum to 1.0.
  return null;
}
