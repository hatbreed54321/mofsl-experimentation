import 'package:shared_preferences/shared_preferences.dart';
import 'package:test/test.dart';

import 'package:mofsl_experiment/src/config/config_cache.dart';
import 'package:mofsl_experiment/src/models/experiment.dart';
import 'package:mofsl_experiment/src/models/feature_flag.dart';
import 'package:mofsl_experiment/src/models/sdk_config.dart';
import 'package:mofsl_experiment/src/models/variation.dart';

void main() {
  group('ConfigCache', () {
    late ConfigCache cache;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      cache = ConfigCache(prefs);
    });

    // -------------------------------------------------------------------------
    // Helper
    // -------------------------------------------------------------------------

    SdkConfig makeConfig({String version = 'v1'}) {
      return SdkConfig(
        version: version,
        generatedAt: '2026-04-01T10:00:00.000Z',
        experiments: {
          'test_exp': const Experiment(
            key: 'test_exp',
            hashAttribute: 'clientCode',
            hashVersion: 1,
            seed: 'test_exp',
            status: 'running',
            variations: [
              Variation(key: 'control', value: false),
              Variation(key: 'treatment', value: true),
            ],
            weights: [0.5, 0.5],
            coverage: 1.0,
            conditionMet: true,
          ),
        },
        features: {
          'dark_mode': const FeatureFlag(
            key: 'dark_mode',
            type: 'boolean',
            value: true,
          ),
        },
        forcedVariations: {},
      );
    }

    // -------------------------------------------------------------------------
    // Cache miss
    // -------------------------------------------------------------------------

    test('load() returns null when cache is empty', () {
      expect(cache.load(), isNull);
    });

    test('etag returns null when no cache exists', () {
      expect(cache.etag, isNull);
    });

    test('timestamp returns null when no cache exists', () {
      expect(cache.timestamp, isNull);
    });

    // -------------------------------------------------------------------------
    // Round-trip
    // -------------------------------------------------------------------------

    test('save() + load() round-trip preserves full config', () async {
      final config = makeConfig(version: 'abc123');
      await cache.save(config, 'abc123');

      final loaded = cache.load();

      expect(loaded, isNotNull);
      expect(loaded!.version, 'abc123');
      expect(loaded.generatedAt, '2026-04-01T10:00:00.000Z');
      expect(loaded.experiments.length, 1);

      final exp = loaded.experiments['test_exp'];
      expect(exp, isNotNull);
      expect(exp!.status, 'running');
      expect(exp.variations.length, 2);
      expect(exp.variations[0].key, 'control');
      expect(exp.variations[1].key, 'treatment');
      expect(exp.weights, [0.5, 0.5]);
      expect(exp.coverage, 1.0);

      final flag = loaded.features['dark_mode'];
      expect(flag, isNotNull);
      expect(flag!.value, true);

      expect(loaded.forcedVariations, isEmpty);
    });

    test('save() stores the etag', () async {
      await cache.save(makeConfig(), 'etag-xyz');
      expect(cache.etag, 'etag-xyz');
    });

    test('save() stores a non-null timestamp', () async {
      await cache.save(makeConfig(), 'etag-xyz');
      expect(cache.timestamp, isNotNull);
      // Must be a valid ISO 8601 string parseable by DateTime.
      expect(() => DateTime.parse(cache.timestamp!), returnsNormally);
    });

    test('second save() overwrites previous config and etag', () async {
      await cache.save(makeConfig(version: 'v1'), 'etag-v1');
      await cache.save(makeConfig(version: 'v2'), 'etag-v2');

      expect(cache.load()?.version, 'v2');
      expect(cache.etag, 'etag-v2');
    });

    // -------------------------------------------------------------------------
    // Corrupted cache
    // -------------------------------------------------------------------------

    test('load() returns null for invalid JSON', () async {
      SharedPreferences.setMockInitialValues({
        'mofsl_exp_config': 'not-valid-json{{{',
      });
      final prefs = await SharedPreferences.getInstance();
      final corruptedCache = ConfigCache(prefs);

      expect(corruptedCache.load(), isNull);
    });

    test('load() returns null when stored JSON is not an object', () async {
      // A JSON array is valid JSON but not a Map — treated as corrupted.
      SharedPreferences.setMockInitialValues({
        'mofsl_exp_config': '[1, 2, 3]',
      });
      final prefs = await SharedPreferences.getInstance();
      final corruptedCache = ConfigCache(prefs);

      expect(corruptedCache.load(), isNull);
    });

    test('load() returns null for a JSON string value', () async {
      SharedPreferences.setMockInitialValues({
        'mofsl_exp_config': '"just a string"',
      });
      final prefs = await SharedPreferences.getInstance();
      final corruptedCache = ConfigCache(prefs);

      expect(corruptedCache.load(), isNull);
    });

    // -------------------------------------------------------------------------
    // Clear
    // -------------------------------------------------------------------------

    test('clear() removes config, etag, and timestamp', () async {
      await cache.save(makeConfig(), 'etag-1');
      expect(cache.load(), isNotNull);
      expect(cache.etag, isNotNull);
      expect(cache.timestamp, isNotNull);

      await cache.clear();

      expect(cache.load(), isNull);
      expect(cache.etag, isNull);
      expect(cache.timestamp, isNull);
    });

    test('clear() on empty cache is a no-op', () async {
      expect(() async => cache.clear(), returnsNormally);
    });
  });
}
