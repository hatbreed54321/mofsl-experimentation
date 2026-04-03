/// A single variation in an A/B experiment.
///
/// [value] can be bool, String, int, or Map<String, dynamic> depending on
/// the experiment type. Unknown JSON fields are silently ignored.
class Variation {
  final String key;
  final dynamic value;

  const Variation({
    required this.key,
    required this.value,
  });

  factory Variation.fromJson(Map<String, dynamic> json) {
    return Variation(
      key: json['key'] as String,
      value: json['value'],
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'value': value,
      };
}
