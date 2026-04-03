import 'package:test/test.dart';

import 'package:mofsl_experiment/src/evaluation/evaluator.dart';
import 'package:mofsl_experiment/src/models/experiment.dart';
import 'package:mofsl_experiment/src/models/feature_flag.dart';
import 'package:mofsl_experiment/src/models/sdk_config.dart';
import 'package:mofsl_experiment/src/models/variation.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a minimal [SdkConfig] with a single experiment.
///
/// [weights] defaults to [1.0] (100% to variation 0) so tests that don't
/// care about bucket assignments get a deterministic result regardless of
/// which clientCode is used.
SdkConfig _configWithExperiment({
  String expKey = 'test_exp',
  String status = 'running',
  List<Variation>? variations,
  List<double>? weights,
  double coverage = 1.0,
  String? seed,
  Map<String, String> forcedVariations = const {},
}) {
  final v = variations ??
      [
        const Variation(key: 'control', value: false),
        const Variation(key: 'treatment', value: true),
      ];
  final w = weights ?? List<double>.filled(v.length, 1.0 / v.length);

  return SdkConfig(
    version: 'v1',
    generatedAt: '2026-04-01T00:00:00.000Z',
    experiments: {
      expKey: Experiment(
        key: expKey,
        hashAttribute: 'clientCode',
        hashVersion: 1,
        seed: seed ?? expKey,
        status: status,
        variations: v,
        weights: w,
        coverage: coverage,
        conditionMet: true,
      ),
    },
    features: const {},
    forcedVariations: forcedVariations,
  );
}

/// [SdkConfig] with a feature flag and no experiments.
SdkConfig _configWithFlag({
  String flagKey = 'dark_mode',
  dynamic value = true,
  String type = 'boolean',
}) {
  return SdkConfig(
    version: 'v1',
    generatedAt: '2026-04-01T00:00:00.000Z',
    experiments: const {},
    features: {
      flagKey: FeatureFlag(key: flagKey, type: type, value: value),
    },
    forcedVariations: const {},
  );
}

const _evaluator = Evaluator();

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  // -------------------------------------------------------------------------
  // Forced variation
  // -------------------------------------------------------------------------

  group('Forced variation', () {
    test('returns forced variation when SDK-level override exists', () {
      final config = _configWithExperiment();
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'any_user',
        config: config,
        forcedVariations: {'test_exp': 'treatment'},
      );
      expect(result?.key, 'treatment');
    });

    test('returns forced variation when config-level forced variation exists',
        () {
      final config = _configWithExperiment(
        forcedVariations: {'test_exp': 'control'},
      );
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'any_user',
        config: config,
      );
      expect(result?.key, 'control');
    });

    test('SDK-level forced variation overrides config-level', () {
      // Config says "control", SDK says "treatment" — SDK wins.
      final config = _configWithExperiment(
        forcedVariations: {'test_exp': 'control'},
      );
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'any_user',
        config: config,
        forcedVariations: {'test_exp': 'treatment'},
      );
      expect(result?.key, 'treatment');
    });

    test('returns null when forced variation key does not exist in variations',
        () {
      final config = _configWithExperiment();
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'any_user',
        config: config,
        forcedVariations: {'test_exp': 'nonexistent_variation'},
      );
      expect(result, isNull);
    });

    test('forced variation for unknown experiment returns null', () {
      final config = _configWithExperiment();
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'unknown_exp',
        clientCode: 'any_user',
        config: config,
        forcedVariations: {'unknown_exp': 'control'},
      );
      expect(result, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Missing experiment
  // -------------------------------------------------------------------------

  group('Missing experiment', () {
    test('returns null when experiment is not in config', () {
      final config = _configWithExperiment(expKey: 'exp_a');
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'exp_b', // not in config
        clientCode: 'AB1234',
        config: config,
      );
      expect(result, isNull);
    });

    test('returns null for empty config', () {
      final config = SdkConfig(
        version: 'v1',
        generatedAt: '2026-04-01T00:00:00.000Z',
        experiments: const {},
        features: const {},
        forcedVariations: const {},
      );
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'any_exp',
        clientCode: 'AB1234',
        config: config,
      );
      expect(result, isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Experiment status
  // -------------------------------------------------------------------------

  group('Experiment status', () {
    test('returns null for paused experiment', () {
      final config = _configWithExperiment(status: 'paused');
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'AB1234',
        config: config,
      );
      expect(result, isNull);
    });

    test('returns null for completed experiment', () {
      final config = _configWithExperiment(status: 'completed');
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'AB1234',
        config: config,
      );
      expect(result, isNull);
    });

    test('returns variation for running experiment', () {
      // weights=[1.0] means ALL users get variation 0 regardless of hash.
      final config = _configWithExperiment(
        weights: [1.0],
        variations: [const Variation(key: 'control', value: false)],
        status: 'running',
      );
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'AB1234',
        config: config,
      );
      expect(result, isNotNull);
    });
  });

  // -------------------------------------------------------------------------
  // Coverage (user exclusion)
  // -------------------------------------------------------------------------

  group('Coverage / exclusion', () {
    test('returns null when coverage is 0%', () {
      final config = _configWithExperiment(coverage: 0.0, weights: [1.0]);
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'AB1234',
        config: config,
      );
      expect(result, isNull,
          reason: '0% coverage means no users are included');
    });

    test('returns variation when coverage is 100%', () {
      final config = _configWithExperiment(
        coverage: 1.0,
        weights: [1.0],
        variations: [const Variation(key: 'control', value: false)],
      );
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'AB1234',
        config: config,
      );
      expect(result, isNotNull,
          reason: '100% coverage means all users are included');
    });
  });

  // -------------------------------------------------------------------------
  // Variation assignment with deterministic weight layouts
  // -------------------------------------------------------------------------

  group('Variation assignment', () {
    test('weight [1.0] — all users get variation 0', () {
      final config = _configWithExperiment(
        weights: [1.0],
        variations: [const Variation(key: 'control', value: false)],
      );
      // Any clientCode must return variation 0 since the first (and only)
      // variation has 100% weight.
      for (final code in ['AB1234', 'XY5678', 'ZZ0001']) {
        final result = _evaluator.evaluateExperiment(
          experimentKey: 'test_exp',
          clientCode: code,
          config: config,
        );
        expect(result?.key, 'control',
            reason: 'clientCode=$code should get control with weight [1.0]');
      }
    });

    test('weight [0.0, 1.0] — all users get variation 1', () {
      final config = _configWithExperiment(
        weights: [0.0, 1.0],
        variations: [
          const Variation(key: 'control', value: false),
          const Variation(key: 'treatment', value: true),
        ],
      );
      for (final code in ['AB1234', 'XY5678', 'ZZ0001']) {
        final result = _evaluator.evaluateExperiment(
          experimentKey: 'test_exp',
          clientCode: code,
          config: config,
        );
        expect(result?.key, 'treatment',
            reason: 'clientCode=$code should get treatment with weight [0,1]');
      }
    });

    test('experiment value is passed through correctly', () {
      final config = _configWithExperiment(
        weights: [1.0],
        variations: [const Variation(key: 'control', value: 'my-value')],
      );
      final result = _evaluator.evaluateExperiment(
        experimentKey: 'test_exp',
        clientCode: 'AB1234',
        config: config,
      );
      expect(result?.value, 'my-value');
    });

    test('experiment uses seed field (not key) for hashing', () {
      // Two configs share the same experiment key ("test_exp") but use
      // different seeds. If the evaluator were incorrectly hashing the key
      // instead of the seed, computeBucket would return identical values.
      // The seeds produce different hash inputs:
      //   configA: "seed_a:AB1234"   configB: "seed_b:AB1234"
      final configA = _configWithExperiment(
        expKey: 'test_exp',
        seed: 'seed_a',
        coverage: 1.0,
      );
      final configB = _configWithExperiment(
        expKey: 'test_exp',
        seed: 'seed_b',
        coverage: 1.0,
      );

      final bucketA = _evaluator.computeBucket('test_exp', 'AB1234', configA);
      final bucketB = _evaluator.computeBucket('test_exp', 'AB1234', configB);

      // Buckets must differ — proof that seed (not key) is the hash input.
      // P(false failure) = 1/10000.
      expect(bucketA, isNot(equals(bucketB)),
          reason: 'Changing only the seed must change the bucket');
    });
  });

  // -------------------------------------------------------------------------
  // Feature flag evaluation
  // -------------------------------------------------------------------------

  group('Feature flag evaluation', () {
    test('returns flag value when flag exists in config', () {
      final config = _configWithFlag(value: true);
      expect(_evaluator.evaluateFlag('dark_mode', config), true);
    });

    test('returns null when flag does not exist in config', () {
      final config = _configWithFlag(flagKey: 'dark_mode');
      expect(_evaluator.evaluateFlag('nonexistent_flag', config), isNull);
    });

    test('returns string flag value', () {
      final config = _configWithFlag(
        flagKey: 'onboarding_copy',
        type: 'string',
        value: 'Welcome to Riise',
      );
      expect(_evaluator.evaluateFlag('onboarding_copy', config), 'Welcome to Riise');
    });

    test('returns integer flag value', () {
      final config = _configWithFlag(
        flagKey: 'max_watchlist_size',
        type: 'integer',
        value: 50,
      );
      expect(_evaluator.evaluateFlag('max_watchlist_size', config), 50);
    });
  });

  // -------------------------------------------------------------------------
  // computeBucket
  // -------------------------------------------------------------------------

  group('computeBucket', () {
    test('returns bucket in [0, 9999]', () {
      final config = _configWithExperiment();
      final bucket = _evaluator.computeBucket('test_exp', 'AB1234', config);
      expect(bucket, isNotNull);
      expect(bucket, greaterThanOrEqualTo(0));
      expect(bucket, lessThan(10000));
    });

    test('returns null for unknown experiment', () {
      final config = _configWithExperiment(expKey: 'exp_a');
      final bucket = _evaluator.computeBucket('exp_b', 'AB1234', config);
      expect(bucket, isNull);
    });

    test('bucket is deterministic for the same inputs', () {
      final config = _configWithExperiment();
      final b1 = _evaluator.computeBucket('test_exp', 'AB1234', config);
      final b2 = _evaluator.computeBucket('test_exp', 'AB1234', config);
      expect(b1, b2);
    });

    test('different clientCodes produce different buckets (most of the time)',
        () {
      final config = _configWithExperiment();
      final b1 = _evaluator.computeBucket('test_exp', 'AB1234', config);
      final b2 = _evaluator.computeBucket('test_exp', 'XY5678', config);
      // Not a strict requirement (rare collisions are possible) but two very
      // different codes should not collide.
      expect(b1, isNot(equals(b2)));
    });
  });
}
