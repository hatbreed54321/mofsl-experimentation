import '../models/experiment.dart';
import '../models/variation.dart';

/// Tracks which experiments have already fired an exposure in this session.
///
/// Exposure deduplication rules (per CONFIG_SERVER_API.md Section 3):
/// - Fire `onExposure` on the **first** evaluation of each experiment per session.
/// - Do NOT fire on subsequent evaluations of the same experiment.
/// - Do NOT fire for feature flags (caller responsibility — never call this for flags).
/// - Do NOT fire for excluded users (caller responsibility — only call when a
///   variation is assigned).
/// - Do NOT fire for forced variations (caller responsibility — check before calling).
/// - Do NOT fire when [onExposure] is null.
///
/// Session = time between `MofslExperiment.initialize()` and `dispose()`.
/// Resetting via [reset] restores initial state (e.g., on dispose).
class ExposureTracker {
  final Set<String> _firedExposures = {};

  /// Attempt to fire [onExposure] for [experimentKey].
  ///
  /// Fires the callback and returns `true` when:
  /// - [experimentKey] has NOT been fired in this session, AND
  /// - [onExposure] is not null.
  ///
  /// Returns `false` without firing when:
  /// - [experimentKey] was already fired (deduplication).
  /// - [onExposure] is null.
  bool trackExposure(
    String experimentKey,
    Experiment experiment,
    Variation variation,
    void Function(Experiment, Variation)? onExposure,
  ) {
    if (onExposure == null || _firedExposures.contains(experimentKey)) {
      return false;
    }
    _firedExposures.add(experimentKey);
    onExposure(experiment, variation);
    return true;
  }

  /// Clear all tracked exposures. Called by [MofslExperiment.dispose].
  void reset() {
    _firedExposures.clear();
  }
}
