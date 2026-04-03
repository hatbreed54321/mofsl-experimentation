import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/sdk_config.dart';

/// Persists and retrieves [SdkConfig] and its ETag via [SharedPreferences].
///
/// SharedPreferences keys:
/// - `mofsl_exp_config`    → JSON-encoded [SdkConfig]
/// - `mofsl_exp_etag`      → config version string (used as ETag)
/// - `mofsl_exp_timestamp` → ISO 8601 timestamp of last successful fetch
///
/// Write operations are async; reads are synchronous after [SharedPreferences]
/// is instantiated (all platforms supported by shared_preferences 2.x).
class ConfigCache {
  static const String _configKey = 'mofsl_exp_config';
  static const String _etagKey = 'mofsl_exp_etag';
  static const String _timestampKey = 'mofsl_exp_timestamp';

  final SharedPreferences _prefs;

  ConfigCache(this._prefs);

  // ---------------------------------------------------------------------------
  // Write
  // ---------------------------------------------------------------------------

  /// Persist [config] and its [etag] to storage.
  Future<void> save(SdkConfig config, String etag) async {
    await _prefs.setString(_configKey, jsonEncode(config.toJson()));
    await _prefs.setString(_etagKey, etag);
    await _prefs.setString(
      _timestampKey,
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  // ---------------------------------------------------------------------------
  // Read
  // ---------------------------------------------------------------------------

  /// Load the cached config. Returns null when:
  /// - No cached data exists (cache miss).
  /// - The stored JSON is corrupted or cannot be parsed.
  ///
  /// Corrupted entries are cleared asynchronously (fire-and-forget) so the
  /// next [save] starts from a clean state.
  SdkConfig? load() {
    final jsonStr = _prefs.getString(_configKey);
    if (jsonStr == null) return null;
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! Map<String, dynamic>) {
        unawaited(clear());
        return null;
      }
      return SdkConfig.fromJson(decoded);
    } catch (_) {
      unawaited(clear());
      return null;
    }
  }

  /// The stored ETag / version string, or null if no cache exists.
  String? get etag => _prefs.getString(_etagKey);

  /// ISO 8601 timestamp of the last successful fetch, or null.
  String? get timestamp => _prefs.getString(_timestampKey);

  // ---------------------------------------------------------------------------
  // Clear
  // ---------------------------------------------------------------------------

  /// Remove all cached config data.
  Future<void> clear() async {
    await _prefs.remove(_configKey);
    await _prefs.remove(_etagKey);
    await _prefs.remove(_timestampKey);
  }
}
