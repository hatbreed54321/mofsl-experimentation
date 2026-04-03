import '../models/sdk_config.dart';
import '../models/variation.dart';
import 'bucket_mapper.dart';
import 'hasher.dart';

/// Evaluates experiments and feature flags against an [SdkConfig] payload.
///
/// This class is stateless — it holds no mutable state and can be reused
/// across multiple evaluation calls.
///
/// Algorithm source: CONFIG_SERVER_API.md Section 3.
class Evaluator {
  const Evaluator();

  // ---------------------------------------------------------------------------
  // Experiment evaluation
  // ---------------------------------------------------------------------------

  /// Evaluate [experimentKey] for [clientCode] against [config].
  ///
  /// [forcedVariations] is the merged map of SDK-level and config-level forced
  /// variation overrides (experimentKey → variationKey). The caller is
  /// responsible for merging; SDK-level entries take precedence.
  ///
  /// Returns the assigned [Variation] or `null` when:
  /// - The experiment is not in config.
  /// - The experiment status is not `"running"`.
  /// - The user is excluded (bucket >= coverage).
  /// - A forced variation key is specified but not found in the variations list.
  ///
  /// **Exposure firing:** when the result came from a forced variation, the
  /// caller must NOT fire the `onExposure` callback. Check
  /// `forcedVariations.containsKey(experimentKey)` before firing.
  Variation? evaluateExperiment({
    required String experimentKey,
    required String clientCode,
    required SdkConfig config,
    Map<String, String> forcedVariations = const {},
  }) {
    // Step 1 — forced variation override (QA/debug).
    final forcedKey = forcedVariations[experimentKey];
    if (forcedKey != null) {
      final experiment = config.experiments[experimentKey];
      if (experiment == null) return null;
      for (final v in experiment.variations) {
        if (v.key == forcedKey) return v;
      }
      // Forced key not found in variations list — treat as no assignment.
      return null;
    }

    // Step 2 — experiment must exist in config.
    final experiment = config.experiments[experimentKey];
    if (experiment == null) return null;

    // Step 3 — experiment must be running.
    if (experiment.status != 'running') return null;

    // Step 4 — compute bucket using experiment.seed (may differ from key).
    final hashInput = '${experiment.seed}:$clientCode';
    final bucket = murmurhash3(hashInput) % 10000;

    // Step 5 & 6 — coverage check + weight mapping.
    final variationIndex =
        mapBucket(bucket, experiment.coverage, experiment.weights);
    if (variationIndex == null) return null;

    return experiment.variations[variationIndex];
  }

  // ---------------------------------------------------------------------------
  // Feature flag evaluation
  // ---------------------------------------------------------------------------

  /// Evaluate [flagKey] against [config].
  ///
  /// Returns the flag's raw `value` field (bool, String, int, or Map) when the
  /// flag exists in config, or `null` when not found.
  ///
  /// Flags do NOT fire exposure events — that is the caller's responsibility
  /// (i.e., never call the exposure tracker for flag results).
  dynamic evaluateFlag(String flagKey, SdkConfig config) {
    return config.features[flagKey]?.value;
  }

  /// Returns the bucket [0, 9999] that [clientCode] falls into for
  /// [experimentKey]. Used by the client for debug logging.
  ///
  /// Returns `null` when the experiment is not in config.
  int? computeBucket(
    String experimentKey,
    String clientCode,
    SdkConfig config,
  ) {
    final experiment = config.experiments[experimentKey];
    if (experiment == null) return null;
    return murmurhash3('${experiment.seed}:$clientCode') % 10000;
  }
}
