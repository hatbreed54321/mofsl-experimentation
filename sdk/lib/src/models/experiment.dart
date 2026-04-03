import 'variation.dart';

/// An experiment configuration as served by the config server.
///
/// All fields are immutable. Unknown JSON fields are silently ignored for
/// forward compatibility.
class Experiment {
  final String key;
  final String hashAttribute;
  final int hashVersion;
  final String seed;
  final String status;
  final List<Variation> variations;
  final List<double> weights;
  final double coverage;
  final bool conditionMet;

  const Experiment({
    required this.key,
    required this.hashAttribute,
    required this.hashVersion,
    required this.seed,
    required this.status,
    required this.variations,
    required this.weights,
    required this.coverage,
    required this.conditionMet,
  });

  factory Experiment.fromJson(Map<String, dynamic> json) {
    return Experiment(
      key: json['key'] as String,
      hashAttribute: json['hashAttribute'] as String? ?? 'clientCode',
      hashVersion: json['hashVersion'] as int? ?? 1,
      // Seed defaults to the experiment key when not specified.
      seed: json['seed'] as String? ?? json['key'] as String,
      status: json['status'] as String,
      variations: (json['variations'] as List<dynamic>)
          .map((v) => Variation.fromJson(v as Map<String, dynamic>))
          .toList(),
      weights: (json['weights'] as List<dynamic>)
          .map((w) => (w as num).toDouble())
          .toList(),
      coverage: (json['coverage'] as num?)?.toDouble() ?? 1.0,
      conditionMet: json['conditionMet'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'hashAttribute': hashAttribute,
        'hashVersion': hashVersion,
        'seed': seed,
        'status': status,
        'variations': variations.map((v) => v.toJson()).toList(),
        'weights': weights,
        'coverage': coverage,
        'conditionMet': conditionMet,
      };
}
