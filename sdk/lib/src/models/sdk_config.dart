import 'experiment.dart';
import 'feature_flag.dart';

/// The full configuration payload as returned by GET /api/v1/config.
///
/// Matches the response shape defined in CONFIG_SERVER_API.md Section 1.
/// All fields are immutable. Unknown top-level JSON fields are silently ignored.
class SdkConfig {
  final String version;
  final String generatedAt;
  final Map<String, Experiment> experiments;
  final Map<String, FeatureFlag> features;

  /// Server-supplied forced variations: experimentKey → variationKey.
  /// These override normal bucketing (e.g., for QA).
  final Map<String, String> forcedVariations;

  const SdkConfig({
    required this.version,
    required this.generatedAt,
    required this.experiments,
    required this.features,
    required this.forcedVariations,
  });

  factory SdkConfig.fromJson(Map<String, dynamic> json) {
    final rawExperiments = json['experiments'] as Map<String, dynamic>? ?? {};
    final rawFeatures = json['features'] as Map<String, dynamic>? ?? {};
    final rawForced = json['forcedVariations'] as Map<String, dynamic>? ?? {};

    return SdkConfig(
      version: json['version'] as String? ?? '',
      generatedAt: json['generatedAt'] as String? ?? '',
      experiments: rawExperiments.map(
        (k, v) => MapEntry(k, Experiment.fromJson(v as Map<String, dynamic>)),
      ),
      features: rawFeatures.map(
        (k, v) => MapEntry(k, FeatureFlag.fromJson(v as Map<String, dynamic>)),
      ),
      forcedVariations: rawForced.map(
        (k, v) => MapEntry(k, v as String),
      ),
    );
  }

  Map<String, dynamic> toJson() => {
        'version': version,
        'generatedAt': generatedAt,
        'experiments':
            experiments.map((k, v) => MapEntry(k, v.toJson())),
        'features': features.map((k, v) => MapEntry(k, v.toJson())),
        'forcedVariations': forcedVariations,
      };
}
