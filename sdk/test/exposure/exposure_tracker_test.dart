import 'package:test/test.dart';

import 'package:mofsl_experiment/src/exposure/exposure_tracker.dart';
import 'package:mofsl_experiment/src/models/experiment.dart';
import 'package:mofsl_experiment/src/models/variation.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

Experiment _makeExperiment(String key) => Experiment(
      key: key,
      hashAttribute: 'clientCode',
      hashVersion: 1,
      seed: key,
      status: 'running',
      variations: const [
        Variation(key: 'control', value: false),
        Variation(key: 'treatment', value: true),
      ],
      weights: const [0.5, 0.5],
      coverage: 1.0,
      conditionMet: true,
    );

const _varControl = Variation(key: 'control', value: false);
const _varTreatment = Variation(key: 'treatment', value: true);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late ExposureTracker tracker;

  setUp(() {
    tracker = ExposureTracker();
  });

  // -------------------------------------------------------------------------
  // First-call fires, second call does not
  // -------------------------------------------------------------------------

  group('Deduplication', () {
    test('first evaluation fires the callback and returns true', () {
      bool fired = false;
      final result = tracker.trackExposure(
        'exp_a',
        _makeExperiment('exp_a'),
        _varControl,
        (_, __) => fired = true,
      );

      expect(result, isTrue);
      expect(fired, isTrue);
    });

    test('second evaluation of the same experiment does not fire', () {
      int fireCount = 0;
      void callback(Experiment e, Variation v) => fireCount++;

      tracker.trackExposure('exp_a', _makeExperiment('exp_a'), _varControl, callback);
      final secondResult = tracker.trackExposure(
        'exp_a',
        _makeExperiment('exp_a'),
        _varTreatment,
        callback,
      );

      expect(secondResult, isFalse);
      expect(fireCount, 1, reason: 'callback must fire exactly once per experiment');
    });

    test('third and subsequent calls for same experiment do not fire', () {
      int fireCount = 0;
      void cb(Experiment e, Variation v) => fireCount++;

      for (int i = 0; i < 5; i++) {
        tracker.trackExposure('exp_a', _makeExperiment('exp_a'), _varControl, cb);
      }

      expect(fireCount, 1);
    });
  });

  // -------------------------------------------------------------------------
  // Different experiments fire independently
  // -------------------------------------------------------------------------

  group('Multiple experiments', () {
    test('different experiment keys fire independently', () {
      final fired = <String>[];

      tracker.trackExposure(
        'exp_a',
        _makeExperiment('exp_a'),
        _varControl,
        (exp, _) => fired.add(exp.key),
      );
      tracker.trackExposure(
        'exp_b',
        _makeExperiment('exp_b'),
        _varControl,
        (exp, _) => fired.add(exp.key),
      );

      expect(fired, containsAll(['exp_a', 'exp_b']));
      expect(fired.length, 2);
    });

    test('second call for exp_a does not fire; first call for exp_b does fire',
        () {
      int aCount = 0, bCount = 0;

      tracker.trackExposure(
          'exp_a', _makeExperiment('exp_a'), _varControl, (_, __) => aCount++);
      tracker.trackExposure(
          'exp_a', _makeExperiment('exp_a'), _varControl, (_, __) => aCount++);
      tracker.trackExposure(
          'exp_b', _makeExperiment('exp_b'), _varControl, (_, __) => bCount++);

      expect(aCount, 1);
      expect(bCount, 1);
    });
  });

  // -------------------------------------------------------------------------
  // Null callback
  // -------------------------------------------------------------------------

  group('Null callback', () {
    test('does not fire and returns false when callback is null', () {
      final result = tracker.trackExposure(
        'exp_a',
        _makeExperiment('exp_a'),
        _varControl,
        null,
      );
      expect(result, isFalse);
    });

    test('can fire for same experiment after null-callback call', () {
      // A null-callback call does not mark the experiment as "fired".
      tracker.trackExposure('exp_a', _makeExperiment('exp_a'), _varControl, null);

      bool fired = false;
      tracker.trackExposure(
        'exp_a',
        _makeExperiment('exp_a'),
        _varControl,
        (_, __) => fired = true,
      );
      expect(fired, isTrue);
    });
  });

  // -------------------------------------------------------------------------
  // Reset
  // -------------------------------------------------------------------------

  group('reset()', () {
    test('clears all fired experiments so subsequent calls fire again', () {
      int fireCount = 0;
      void cb(Experiment e, Variation v) => fireCount++;

      tracker.trackExposure('exp_a', _makeExperiment('exp_a'), _varControl, cb);
      tracker.trackExposure('exp_b', _makeExperiment('exp_b'), _varControl, cb);
      expect(fireCount, 2);

      tracker.reset();

      tracker.trackExposure('exp_a', _makeExperiment('exp_a'), _varControl, cb);
      tracker.trackExposure('exp_b', _makeExperiment('exp_b'), _varControl, cb);
      expect(fireCount, 4, reason: 'reset() must allow all experiments to fire again');
    });

    test('calling reset on an empty tracker does not throw', () async {
      // Correct pattern per Phase 7A lesson: await directly (do not use
      // returnsNormally with sync calls that return void).
      tracker.reset(); // should not throw
    });
  });

  // -------------------------------------------------------------------------
  // Callback receives correct arguments
  // -------------------------------------------------------------------------

  group('Callback arguments', () {
    test('callback receives the correct experiment and variation', () {
      Experiment? receivedExp;
      Variation? receivedVar;

      final exp = _makeExperiment('my_exp');
      tracker.trackExposure(
        'my_exp',
        exp,
        _varTreatment,
        (e, v) {
          receivedExp = e;
          receivedVar = v;
        },
      );

      expect(receivedExp?.key, 'my_exp');
      expect(receivedVar?.key, 'treatment');
    });
  });
}
