/// A feature flag configuration entry from the config server.
///
/// [type] is one of: "boolean", "string", "integer", "json".
/// [value] is the current flag value. Unknown JSON fields are silently ignored.
class FeatureFlag {
  final String key;
  final String type;
  final dynamic value;

  const FeatureFlag({
    required this.key,
    required this.type,
    required this.value,
  });

  factory FeatureFlag.fromJson(Map<String, dynamic> json) {
    return FeatureFlag(
      key: json['key'] as String,
      type: json['type'] as String? ?? 'boolean',
      value: json['value'],
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'type': type,
        'value': value,
      };
}
