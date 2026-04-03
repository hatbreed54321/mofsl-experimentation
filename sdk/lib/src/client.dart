import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config/config_cache.dart';
import 'config/config_loader.dart';
import 'evaluation/evaluator.dart';
import 'exposure/exposure_tracker.dart';
import 'models/experiment.dart';
import 'models/sdk_config.dart';
import 'models/variation.dart';
import 'utils/logger.dart';

/// The main entry point for the MOFSL Experimentation SDK.
///
/// Usage:
/// ```dart
/// final sdk = await MofslExperiment.initialize(
///   configUrl: 'https://experiments.mofsl.com/api/v1/config',
///   apiKey: 'mk_live_...',
///   clientCode: 'AB1234',
///   onExposure: (experiment, variation) {
///     analytics.track('experiment_viewed', {
///       'experimentKey': experiment.key,
///       'variationKey': variation.key,
///     });
///   },
/// );
///
/// final showNewChart = sdk.getBool('new_chart_ui', defaultValue: false);
/// ```
///
/// Call [dispose] when the SDK is no longer needed (e.g., on app shutdown).
class MofslExperiment {
  // ---------------------------------------------------------------------------
  // Private fields
  // ---------------------------------------------------------------------------

  final String _clientCode;
  final Map<String, String>? _sdkForcedVariations;
  final void Function(Experiment, Variation)? _onExposure;
  final bool _debugMode;
  final Logger _logger;
  final Evaluator _evaluator;
  final ExposureTracker _exposureTracker;
  final ConfigLoader _loader;
  final http.Client _httpClient;

  SdkConfig? _config;
  Timer? _refreshTimer;

  // ---------------------------------------------------------------------------
  // Private constructor
  // ---------------------------------------------------------------------------

  MofslExperiment._({
    required String clientCode,
    required Map<String, String>? sdkForcedVariations,
    required void Function(Experiment, Variation)? onExposure,
    required bool debugMode,
    required Logger logger,
    required Evaluator evaluator,
    required ExposureTracker exposureTracker,
    required ConfigLoader loader,
    required http.Client httpClient,
  })  : _clientCode = clientCode,
        _sdkForcedVariations = sdkForcedVariations,
        _onExposure = onExposure,
        _debugMode = debugMode,
        _logger = logger,
        _evaluator = evaluator,
        _exposureTracker = exposureTracker,
        _loader = loader,
        _httpClient = httpClient;

  // ---------------------------------------------------------------------------
  // Public factory — initialize
  // ---------------------------------------------------------------------------

  /// Initialize the SDK. Call once at app startup.
  ///
  /// If a cached config exists the method returns quickly (non-blocking) and
  /// starts a background fetch to refresh the config. If no cache exists, the
  /// method waits for the first network fetch before returning.
  ///
  /// The returned instance is always valid — even if the network is unavailable
  /// all evaluation methods will return their [defaultValue]s.
  ///
  /// [httpClientOverride] is for testing only — pass a [FakeHttpClient] to
  /// avoid real network calls in unit / integration tests.
  static Future<MofslExperiment> initialize({
    required String configUrl,
    required String apiKey,
    required String clientCode,
    Map<String, dynamic>? attributes,
    void Function(Experiment experiment, Variation variation)? onExposure,
    Duration refreshInterval = const Duration(minutes: 5),
    bool debugMode = false,
    Map<String, String>? forcedVariations,
    // For testing only: pass a [FakeHttpClient] to avoid real network calls.
    http.Client? httpClientOverride,
  }) async {
    final logger = Logger(debugMode: debugMode);

    final prefs = await SharedPreferences.getInstance();
    final cache = ConfigCache(prefs);

    final httpClient = httpClientOverride ?? http.Client();

    final loader = ConfigLoader(
      configUrl: configUrl,
      apiKey: apiKey,
      clientCode: clientCode,
      attributes: attributes,
      httpClient: httpClient,
      cache: cache,
      logger: logger,
    );

    final instance = MofslExperiment._(
      clientCode: clientCode,
      sdkForcedVariations: forcedVariations,
      onExposure: onExposure,
      debugMode: debugMode,
      logger: logger,
      evaluator: const Evaluator(),
      exposureTracker: ExposureTracker(),
      loader: loader,
      httpClient: httpClient,
    );

    // Load cached config synchronously — makes the SDK instantly usable.
    final cached = cache.load();
    instance._config = cached;

    if (cached != null) {
      logger.debug('Loaded cached config (version: ${cached.version})');
      // Cache exists — refresh in background so initialize() is non-blocking.
      unawaited(instance._fetchConfig());
    } else {
      // No cache — must wait for the first fetch before returning.
      await instance._fetchConfig();
    }

    instance._startBackgroundRefresh(refreshInterval);
    return instance;
  }

  // ---------------------------------------------------------------------------
  // Public evaluation API
  // ---------------------------------------------------------------------------

  /// Evaluate [key] as a boolean experiment or feature flag.
  ///
  /// Returns [defaultValue] when the key is not found, the user is excluded,
  /// the config is unavailable, or any error occurs. Never throws.
  bool getBool(String key, {required bool defaultValue}) {
    try {
      final value = _evaluate(key);
      return value is bool ? value : defaultValue;
    } catch (e, stack) {
      _logger.error('getBool failed for key=$key', e, stack);
      return defaultValue;
    }
  }

  /// Evaluate [key] as a string experiment or feature flag.
  ///
  /// Returns [defaultValue] on any error or absence. Never throws.
  String getString(String key, {required String defaultValue}) {
    try {
      final value = _evaluate(key);
      return value is String ? value : defaultValue;
    } catch (e, stack) {
      _logger.error('getString failed for key=$key', e, stack);
      return defaultValue;
    }
  }

  /// Evaluate [key] as an integer experiment or feature flag.
  ///
  /// Returns [defaultValue] on any error or absence. Never throws.
  int getInt(String key, {required int defaultValue}) {
    try {
      final value = _evaluate(key);
      return value is int ? value : defaultValue;
    } catch (e, stack) {
      _logger.error('getInt failed for key=$key', e, stack);
      return defaultValue;
    }
  }

  /// Evaluate [key] as a JSON experiment or feature flag.
  ///
  /// Returns [defaultValue] on any error or absence. Never throws.
  Map<String, dynamic> getJSON(
    String key, {
    required Map<String, dynamic> defaultValue,
  }) {
    try {
      final value = _evaluate(key);
      return value is Map<String, dynamic> ? value : defaultValue;
    } catch (e, stack) {
      _logger.error('getJSON failed for key=$key', e, stack);
      return defaultValue;
    }
  }

  // ---------------------------------------------------------------------------
  // Public lifecycle API
  // ---------------------------------------------------------------------------

  /// Force a manual config refresh. Waits until the refresh completes.
  Future<void> refresh() async {
    await _fetchConfig();
  }

  /// Destroy the client.
  ///
  /// - Cancels the background refresh timer (prevents memory leaks when the
  ///   host app navigates away and creates a new instance).
  /// - Clears the in-session exposure set.
  /// - Closes the underlying HTTP client.
  void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _exposureTracker.reset();
    _httpClient.close();
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Core evaluation: tries experiment first, then feature flag.
  ///
  /// Returns the raw value (bool/String/int/Map) or `null` when nothing is
  /// found. All exceptions are allowed to propagate — they are caught in the
  /// typed public methods.
  dynamic _evaluate(String key) {
    final config = _config;
    if (config == null) return null;

    final merged = _mergedForcedVariations(config);

    // Try experiment evaluation first.
    final variation = _evaluator.evaluateExperiment(
      experimentKey: key,
      clientCode: _clientCode,
      config: config,
      forcedVariations: merged,
    );

    if (variation != null) {
      final isForced = merged.containsKey(key);
      if (_debugMode) {
        final bucket = _evaluator.computeBucket(key, _clientCode, config);
        _logger.debug(
          'Experiment $key: bucket=$bucket, '
          'variation=${variation.key}, '
          'reason=${isForced ? "forced" : "assigned"}',
        );
      }
      // Fire exposure only for genuine assignments (not forced, not flags).
      if (!isForced) {
        final experiment = config.experiments[key];
        if (experiment != null) {
          final fired = _exposureTracker.trackExposure(
            key,
            experiment,
            variation,
            _onExposure,
          );
          if (fired && _debugMode) {
            _logger.debug('Exposure fired for experiment $key');
          }
        }
      }
      return variation.value;
    }

    // Try feature flag evaluation.
    final flagValue = _evaluator.evaluateFlag(key, config);
    if (flagValue != null) {
      // Cast to Object before interpolation to satisfy avoid_dynamic_calls.
      if (_debugMode) _logger.debug('Flag $key: value=${flagValue as Object}');
      return flagValue;
    }

    if (_debugMode) _logger.debug('$key: not found in experiments or flags');
    return null;
  }

  /// Merge config-level and SDK-level forced variations.
  /// SDK-level (passed to [initialize]) override config-level.
  Map<String, String> _mergedForcedVariations(SdkConfig config) {
    final sdk = _sdkForcedVariations;
    if (sdk == null || sdk.isEmpty) return config.forcedVariations;
    return {...config.forcedVariations, ...sdk};
  }

  /// Fetch the latest config and update [_config] on success.
  Future<void> _fetchConfig() async {
    try {
      final config = await _loader.fetch();
      if (config != null) {
        _config = config;
        if (_debugMode) {
          _logger.debug('Config refreshed (version: ${config.version})');
        }
      }
    } catch (e, stack) {
      // ConfigLoader already handles all error paths and returns cached/null.
      // This catch is a safety net only.
      _logger.error('Unexpected error during config fetch', e, stack);
    }
  }

  /// Start the background refresh timer. Fires every [interval].
  void _startBackgroundRefresh(Duration interval) {
    _refreshTimer = Timer.periodic(interval, (_) {
      unawaited(_fetchConfig());
    });
    if (_debugMode) {
      _logger.debug(
        'Background refresh started (interval: ${interval.inSeconds}s)',
      );
    }
  }
}
